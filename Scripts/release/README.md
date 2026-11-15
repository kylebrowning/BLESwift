# Release scripts

These files build the `bleswift-provider` release binary for Homebrew.

| File | Purpose |
| --- | --- |
| `release-provider.sh` | Builds, signs, and notarizes the binary. Writes the zip file and the formula. |
| `bleswift-provider.entitlements` | Gives the binary the Bluetooth entitlement. |
| `Info.plist` | Gives the binary a bundle identifier and the Bluetooth usage text. |
| `bleswift-provider.rb.template` | The Homebrew formula. The script fills in the version and the checksum. |

## One-time setup

1. Create a "Developer ID Application" certificate in your Apple Developer account.
2. Install the certificate and its private key in your login keychain. If the keychain has
   more than one "Developer ID Application" identity, set `BLESWIFT_SIGNING_IDENTITY` to the
   full name of the identity.
3. Store the notarization credentials in the keychain:

```sh
xcrun notarytool store-credentials bleswift-notary --apple-id <apple-id> --team-id <team-id>
```

The command asks for an app-specific password.

## Release steps

1. Tag the release commit with the version. The tag must point at HEAD.
2. Make sure the working tree is clean.
3. Run the script:

```sh
Scripts/release/release-provider.sh 3.2.0
```

4. Push the tag: `git push origin 3.2.0`.
5. If the GitHub release does not exist, create it: `gh release create 3.2.0 --verify-tag --notes-file <notes>`.
6. Upload the zip file: `gh release upload 3.2.0 dist/bleswift-provider-3.2.0-macos.zip`.
7. Copy `dist/bleswift-provider.rb` to `Formula/` in `kylebrowning/homebrew-tap`.
8. Commit and push the tap.

To test the build without notarization, add `--skip-notarize`. The script then writes
`dist/bleswift-provider-<version>-macos-unnotarized.zip` and no formula. Do not upload this file.

You cannot staple a ticket to a bare command-line binary. Gatekeeper checks the notarization
online. A Homebrew download has no quarantine flag, so Gatekeeper does not check it at install.

The script never uploads a file and never pushes to a repository.

## Toolchain

The universal build needs Xcode. The Command Line Tools cannot link the x86_64 slice.
If `DEVELOPER_DIR` is not set and the Command Line Tools are selected, the script uses
`/Applications/Xcode.app/Contents/Developer`. If Xcode is not at that path, the script stops.
In that case, run `sudo xcode-select -s <path-to-Xcode>/Contents/Developer`, or set `DEVELOPER_DIR`.

## Environment variables

- `BLESWIFT_SIGNING_IDENTITY` is the name of the signing identity. The default is
  "Developer ID Application".
- `BLESWIFT_NOTARY_PROFILE` is the name of the notarytool profile. The default is
  `bleswift-notary`.
