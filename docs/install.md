# Install the Swarmbell test build

The first public build is free while we test it. It requires macOS 13 or newer.
Download the architecture shown beside the link on [swarmbell.ai](https://swarmbell.ai),
or choose an asset from the [GitHub release](https://github.com/andeplane/swarmbell/releases).

1. Unzip the download and move `Swarmbell.app` to Applications.
2. Open it. Swarmbell lives in the menu bar; there is no permanent Dock icon.
3. If macOS blocks this unnotarized test build, review the source and release
   checksums before deciding whether you trust it. After attempting to open it,
   System Settings → Privacy & Security may offer **Open Anyway**. Use that
   per-app exception only if you trust the download. Keep Gatekeeper enabled.
4. Click the bell to view agents. Control–Option–Space opens the quick switcher.
   Cursor lifecycle observation is enabled separately in Swarmbell Settings.

The build is signed ad hoc; it is not Developer ID signed or notarized. A public
download is not evidence of Apple review. Building from source is also supported.

## Updating an existing Agent Beacon installation

Quit the older app before starting Swarmbell so only one collector runs.
Swarmbell deliberately preserves existing storage, bundle identifiers, Keychain
services and local-network transport identifiers. Your measurement history and
pairing material remain in their existing locations. The renamed command-line
helper is `swarmbell`; reinstall its Cursor observer from Settings after moving
the app so hooks point to the new absolute path. The local upgrade may retain a compatibility alias at the older app/helper path for existing read-only consumers. Do not run both app copies.

## Feedback and the test period

Report problems in [GitHub issues](https://github.com/andeplane/swarmbell/issues).
Avoid posting private agent titles, paths, pairing QR codes, credentials or full
transcripts. A possible US$2.99 price will be evaluated after the test period;
there is no purchase, subscription or payment collection in this build.
