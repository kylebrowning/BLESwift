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

mkdir -p dist
zip_path="dist/bleswift-provider-$version-macos.zip"
rm -f "$zip_path"
ditto -c -k "$binary" "$zip_path"

if [ "$skip_notarize" -eq 0 ]; then
  submission="$(xcrun notarytool submit "$zip_path" --keychain-profile "$notary_profile" --wait)"
  echo "$submission"
  if ! echo "$submission" | grep -q "status: Accepted"; then
    echo "error: notarization did not return the status Accepted." >&2
    exit 1
  fi
else
  echo "Notarization skipped."
fi

sha256="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
echo "sha256: $sha256"

sed -e "s/__VERSION__/$version/g" -e "s/__SHA256__/$sha256/g" \
  "$script_directory/bleswift-provider.rb.template" > dist/bleswift-provider.rb

cat <<NEXT

Next steps. The script does not do these steps.
  1. Upload the zip file to the release:
       gh release upload $version $zip_path
  2. Copy dist/bleswift-provider.rb to Formula/ in kylebrowning/homebrew-tap.
  3. Commit and push the tap.
NEXT
