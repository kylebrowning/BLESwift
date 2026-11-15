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
2. Install the certificate in your login keychain.
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

4. Wait for the notarization to finish. To test the build without notarization, add `--skip-notarize`.
5. Upload the zip file: `gh release upload 3.2.0 dist/bleswift-provider-3.2.0-macos.zip`.
6. Copy `dist/bleswift-provider.rb` to `Formula/` in `kylebrowning/homebrew-tap`.
7. Commit and push the tap.

The script never uploads a file and never pushes to a repository.

## Environment variables

- `BLESWIFT_SIGNING_IDENTITY` is the name of the signing identity. The default is
  "Developer ID Application".
- `BLESWIFT_NOTARY_PROFILE` is the name of the notarytool profile. The default is
  `bleswift-notary`.
