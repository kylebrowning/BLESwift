#!/usr/bin/env bash
#
# Build, sign, and notarize the bleswift-provider release binary.
#
# The script builds a universal binary (arm64 and x86_64). It embeds an Info.plist so that macOS
# shows the Bluetooth usage text. It signs the binary with the Bluetooth entitlement and the
# hardened runtime. It packs the binary in a zip file and it can notarize the zip file. It
# writes a Homebrew formula for the zip file.
#
# The script never uploads a file and never pushes to a repository. It prints the next steps.
#
# Usage: Scripts/release/release-provider.sh [--skip-notarize] <version>
#
# The tag <version> must exist and must point at HEAD. The working tree must be clean.
#
# Environment variables:
#   BLESWIFT_SIGNING_IDENTITY  Name of the signing identity.
#                              Default: "Developer ID Application"
#   BLESWIFT_NOTARY_PROFILE    Name of the notarytool keychain profile.
#                              Default: "bleswift-notary"
#
# Output:
#   dist/bleswift-provider-<version>-macos.zip
#   dist/bleswift-provider.rb

set -euo pipefail

usage() {
  echo "Usage: Scripts/release/release-provider.sh [--skip-notarize] <version>" >&2
}

skip_notarize=0
version=""
for argument in "$@"; do
  case "$argument" in
    --skip-notarize) skip_notarize=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $argument" >&2; usage; exit 64 ;;
    *)
      if [ -n "$version" ]; then
        echo "error: pass only one version." >&2
        usage
        exit 64
      fi
      version="$argument"
      ;;
  esac
done

if [ -z "$version" ]; then
  usage
  exit 64
fi

# The version goes into sed expressions, file names, and the release URL. Accept only a
# semantic version.
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "error: $version is not a semantic version, for example 3.2.0." >&2
  exit 64
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
cd "$repository_root"

if [ -n "$(git status --porcelain)" ]; then
  echo "error: the working tree is not clean. Commit or stash your changes." >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "refs/tags/$version" >/dev/null; then
  echo "error: the tag $version does not exist. Create the tag first." >&2
  exit 1
fi

if [ "$(git rev-parse "$version^{commit}")" != "$(git rev-parse HEAD)" ]; then
  echo "error: the tag $version does not point at HEAD. Check out the tag first." >&2
  exit 1
fi

identity="${BLESWIFT_SIGNING_IDENTITY:-Developer ID Application}"
notary_profile="${BLESWIFT_NOTARY_PROFILE:-bleswift-notary}"
entitlements="$script_directory/bleswift-provider.entitlements"

# The Command Line Tools cannot link the x86_64 slice, so the universal build needs Xcode.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p)" == *CommandLineTools ]]; then
  xcode_developer_directory="/Applications/Xcode.app/Contents/Developer"
  if [ -d "$xcode_developer_directory" ]; then
    export DEVELOPER_DIR="$xcode_developer_directory"
    echo "Using Xcode from $DEVELOPER_DIR for the universal build."
  else
    echo "error: the universal build needs Xcode, but the Command Line Tools are selected." >&2
    echo "Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
  fi
fi

# Remove the output of an earlier run, so that dist/ holds only the files of this run.
rm -rf dist

work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT

# Render the Info.plist with the version.
rendered_plist="$work_directory/Info.plist"
sed "s/__VERSION__/$version/g" "$script_directory/Info.plist" > "$rendered_plist"

# Build a universal binary with the Info.plist in the __TEXT,__info_plist section.
build_arguments=(
  -c release --product bleswift-provider
  --scratch-path .build-release
  --arch arm64 --arch x86_64
)
swift build "${build_arguments[@]}" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$rendered_plist"
binary="$(swift build "${build_arguments[@]}" --show-bin-path)/bleswift-provider"

codesign --force --options runtime --timestamp \
  --entitlements "$entitlements" --sign "$identity" "$binary"
codesign --verify --strict --verbose=2 "$binary"

# Check the binary before it is packed. A wrong flag can give a single-architecture build, and
# signing can drop the entitlement.
architectures="$(lipo -archs "$binary")"
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
  echo "error: the binary is not universal. Architectures: $architectures" >&2
  exit 1
fi
if ! codesign -d --entitlements - "$binary" 2>/dev/null | grep -q "com.apple.security.device.bluetooth"; then
  echo "error: the signed binary does not have the Bluetooth entitlement." >&2
  exit 1
fi
if ! otool -s __TEXT __info_plist "$binary" | grep -q "__info_plist"; then
  echo "error: the binary does not have an embedded Info.plist." >&2
  exit 1
fi

mkdir -p dist
if [ "$skip_notarize" -eq 0 ]; then
  zip_path="dist/bleswift-provider-$version-macos.zip"
else
  # Give a test build a different name, so that nobody uploads it as a release by mistake.
  zip_path="dist/bleswift-provider-$version-macos-unnotarized.zip"
fi
# Do not put resource forks or extended attributes in the zip file. Without these options,
# ditto adds an AppleDouble "._bleswift-provider" entry.
ditto -c -k --norsrc --noextattr --noqtn "$binary" "$zip_path"

if [ "$skip_notarize" -eq 0 ]; then
  # Keep the output in a file, so that a failure still shows the submission ID. Use the ID
  # with "xcrun notarytool log <id>" to read the reason.
  notary_output="$work_directory/notarytool.txt"
  if ! xcrun notarytool submit "$zip_path" --keychain-profile "$notary_profile" --wait \
      | tee "$notary_output"; then
    echo "error: notarytool failed. Read the output above for the submission ID." >&2
    exit 1
  fi
  if ! grep -q "status: Accepted" "$notary_output"; then
    echo "error: notarization did not return the status Accepted." >&2
    exit 1
  fi
else
  echo "Notarization skipped. The script writes no formula for a test build."
  echo "Output: $zip_path"
  exit 0
fi

sha256="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
echo "sha256: $sha256"

sed -e "s/__VERSION__/$version/g" -e "s/__SHA256__/$sha256/g" \
  "$script_directory/bleswift-provider.rb.template" > dist/bleswift-provider.rb

cat <<NEXT

Next steps. The script does not do these steps.
  1. Push the tag, and create the GitHub release if it does not exist:
       git push origin $version
       gh release create $version --verify-tag --notes-file <notes>
  2. Upload the zip file to the release:
       gh release upload $version $zip_path
  3. Copy dist/bleswift-provider.rb to Formula/ in kylebrowning/homebrew-tap.
  4. Commit and push the tap.
NEXT
