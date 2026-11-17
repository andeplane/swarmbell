# Swarmbell iPhone companion — 16 November 2026

The Mac owns one existing `AgentMonitor` and history store. Optional sharing publishes that monitor's actual snapshots after each refresh. Connected phones receive week/month analytics from the same history store, refreshed at most every 30 seconds. No second CLI collector is started.

The iPhone has Agents, Statistics and Connection tabs. It shows needs-you sessions first, search, source coverage, session details and week/month activity and hour/weekday charts. It is read-only: conversation interaction remains in its original Mac harness. No source execution, approval forwarding, cloud relay, background phone delivery or internet-away-from-home route is implemented.

## Pairing and transport

The Mac's sharing switch is off initially. Enabling it creates or loads a device-local 256-bit random pairing secret in Keychain. The private QR code includes the version, Mac service UUID and secret. The phone imports it only through explicit QR/paste pairing and stores it in its device-only Keychain. Do not put the code in logs or screenshots. Reset pairing stops connections and replaces the secret; disabling sharing stops the listener without erasing the saved pairing.

Bonjour advertises `_agentbeacon._tcp` with the exact UUID service name. Both ends use authenticated TLS 1.2 PSK with AES-128-GCM; no certificate-check bypass is installed. This is the TLS-PSK mode supported by Apple's older Network APIs, as documented in [Apple TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework). It uses a shared pairing key rather than per-phone identities; reset invalidates all phones. This cipher does not provide ephemeral-key forward secrecy.

The server pushes four-byte-length-prefixed versioned JSON envelopes, bounded at 8 MiB. At most four connections and one newest pending frame per connection are retained. Handshakes time out; client application data is rejected. The client validates lengths/versions, authenticates the exact paired service and reconnects with bounded backoff. No incoming command endpoint exists.

## Validation and installation

- 46 existing core tests and four new pairing/framing tests pass (`work/companion-tests.log`).
- Isolated loopback TLS smoke authenticated matching keys and rejected a wrong key with `bad MAC`; no real agent data was used.
- Mac, simulator and signed physical iPhone builds pass. The Mac bundle passes strict codesign verification. Source formatting and diff checks pass.
- Mac 0.3.0 is installed at `~/Applications/Swarmbell.app`. Its sharing switch was enabled through the actual native UI, the listener reported ready, and the private pairing sheet is visible. Existing Cursor hook paths remain at the installed helper.
- Signed iPhone app `dev.andeplane.Swarmbell` was installed successfully on the test iPhone. Automatic launch was blocked by the phone being locked. Development profile expiration is 30 September 2027; this is not an App Store release.
- Final bundle inspection caught Xcode omitting the Bonjour service array from generated build settings. An explicit `Info.plist` now supplies the array, and the corrected signed bundle was rebuilt and inspected successfully. After the user reconnected the phone, corrected version 0.3.1/build 5 installed and launched successfully. Bundle inspection verified the Bonjour service array and AppIcon. The earlier incomplete build was replaced.
- Simulator code compiles, but native visual review was unavailable because Computer Use did not resolve Simulator. This is not claimed as a rendered-layout pass.
- The user scanned the QR code. After the corrected update, the Mac native Settings displayed one authenticated connected phone and the user explicitly confirmed “Live agents are showing.” This establishes physical live agent delivery. Phone statistics, camera-denial recovery and all reconnection scenarios are not yet separately accepted.

The app must remain foregrounded on the phone for live delivery. The first connection can briefly show snapshots before analytics arrives on the following refresh. Missing observations remain gaps in the shared reports.

## Pairing feedback correction — 0.3.1

The original phone build omitted its Bonjour declaration, and browser waiting states had no actionable status. The corrected build includes the explicit declaration, handles browser waiting/failure, and gives recovery guidance after 15 seconds without discovery. Connection state is true only after authenticated TLS readiness and becomes false immediately on disconnect. A saved code is labeled as saved, rather than connected; first live delivery takes the phone to Agents.

Version 0.3.1 uses a bright blue beacon icon generated with the built-in ImageGen tool. The exact prompt and asset provenance are in `docs/icon-prompt.txt`; the earlier dark icon generator was removed. Existing 46 core and four companion tests pass in `work/pairing-fix-tests.log`. These pure tests do not independently cover every permission/physical-network state.
