# Install the Swarmbell test build

The public test build is free. It requires macOS 13 or newer.
The universal download supports Apple silicon and Intel Macs. Get it from
[swarmbell.ai](https://swarmbell.ai) or the [GitHub release](https://github.com/andeplane/swarmbell/releases).

1. Unzip the download and move `Swarmbell.app` to Applications.
2. Open Swarmbell from Applications. The app lives in the menu bar.
3. Click the bell to view agents. Control–Option–Space opens the quick switcher.
   Cursor lifecycle observation is enabled separately in Swarmbell Settings.

The build is Developer ID signed and notarized by Apple. The GitHub release
includes a SHA-256 checksum for the ZIP. You can also build from source.

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
