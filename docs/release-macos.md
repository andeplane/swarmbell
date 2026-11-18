# Release Swarmbell for macOS

Push a version tag such as `v0.5.2` on a commit already on `main`. Match the tag to
`CFBundleShortVersionString` in `scripts/build-app.sh` and increment
`CFBundleVersion`. To publish an existing tag, dispatch **Release macOS app**
from the `main` branch with that tag. Select **Build, sign, notarize, and verify
without publishing** to test credentials against any existing release tag.

The workflow builds the app and its bundled CLI for Apple silicon and Intel,
signs them with Developer ID, submits the ZIP for notarization, and staples
Apple's ticket. It checks the extracted ZIP before publishing the release and
its SHA-256 checksum. The website uses GitHub's latest-release download URL, so
shipping a newer Mac version updates the download without a separate site
deployment. An existing public release is left as published.

## GitHub Actions configuration

Use the `macos-release` environment. Configure these environment secrets.

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12` | Base64-encoded, password-protected PKCS#12 containing the Developer ID Application certificate and its private key |
| `DEVELOPER_ID_P12_PASSWORD` | Password for the PKCS#12 |
| `APPLE_NOTARY_KEY` | Contents of an App Store Connect team API key (`.p8`) with the Developer role |

Set the environment variables `DEVELOPER_ID_SHA1` to the certificate's SHA-1
fingerprint and `APPLE_NOTARY_KEY_ID` and `APPLE_NOTARY_ISSUER` to the App Store
Connect key ID and issuer ID. Limit the environment to `main` and version tags.

For a failed notarization, check the Actions run for the Apple submission ID
and diagnostic log. To retry an unpublished release, rerun the workflow for the
same tag. GitHub draft releases remain private until both verified assets have
uploaded.
