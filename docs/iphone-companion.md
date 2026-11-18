# Swarmbell iPhone companion — 17 November 2026

The Mac owns one existing `AgentMonitor` and history store. Optional sharing publishes that monitor's actual snapshots after each refresh. Connected phones receive week/month analytics from the same history store, refreshed at most every 30 seconds. No second CLI collector is started.

The iPhone has Agents, Statistics and Connection tabs. It shows needs-you sessions first, search, source coverage and session details. Statistics include custom ranges, harness filters, previous-period comparisons, activity, hour/weekday histograms, weekday/hour heatmap, wait episodes, source coverage, latency diagnostics and measured insights. It is read-only: conversation interaction remains in its original Mac harness. No source execution, approval forwarding, cloud relay, continuous background Mac connection or internet-away-from-home route is implemented. Counts-only widgets and Watch surfaces retain clearly dated last-known observations.

## Pairing and transport

The Mac's sharing switch is off initially. Enabling it creates or loads a device-local 256-bit random pairing secret in Keychain. The private QR code includes the version, Mac service UUID and secret. The phone imports it only through explicit QR/paste pairing and stores it in its device-only Keychain. Do not put the code in logs or screenshots. Reset pairing stops connections and replaces the secret; disabling sharing stops the listener without erasing the saved pairing.

Bonjour advertises `_agentbeacon._tcp` with the exact UUID service name. Both ends use authenticated TLS 1.2 PSK with AES-128-GCM; no certificate-check bypass is installed. This is the TLS-PSK mode supported by Apple's older Network APIs, as documented in [Apple TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework). It uses a shared pairing key rather than per-phone identities; reset invalidates all phones. This cipher does not provide ephemeral-key forward secrecy.

The server pushes four-byte-length-prefixed versioned JSON envelopes, bounded at 8 MiB. At most four connections and one newest pending snapshot plus one response per connection are retained. Handshakes time out. Updated clients send only allowlisted aggregate-history queries after the Mac advertises `analyticsQueriesV1`; older push-only clients remain compatible. Queries validate UUID correlation, finite ordered ranges up to 366 days, timezone and harness. Query payloads are limited to 16 KiB, replies to 8 MiB, one request per connection and two concurrent reports globally. Errors are sanitized and cancellation stops pending work. The client validates lengths/versions, authenticates the exact paired service and reconnects with bounded backoff. No incoming agent command endpoint exists. Existing `HistoryStore.report` serves queries without starting another collector.

## Validation and installation

- 46 existing core tests and four new pairing/framing tests pass (`work/companion-tests.log`).
- Isolated loopback TLS smoke authenticated matching keys and rejected a wrong key with `bad MAC`; no real agent data was used.
- Mac, simulator and signed physical iPhone builds pass. The Mac bundle passes strict codesign verification. Source formatting and diff checks pass.
- Mac 0.3.0 is installed at `~/Applications/Swarmbell.app`. Its sharing switch was enabled through the actual native UI, the listener reported ready, and the private pairing sheet is visible. Existing Cursor hook paths remain at the installed helper.
- Signed iPhone app `dev.andeplane.AgentBeacon` was installed successfully on the test iPhone. Automatic launch was blocked by the phone being locked. Development profile expiration is 30 September 2027; this is not an App Store release.
- Final bundle inspection caught Xcode omitting the Bonjour service array from generated build settings. An explicit `Info.plist` now supplies the array, and the corrected signed bundle was rebuilt and inspected successfully. After the user reconnected the phone, corrected version 0.3.1/build 5 installed and launched successfully. Bundle inspection verified the Bonjour service array and AppIcon. The earlier incomplete build was replaced.
- Simulator code compiles, but native visual review was unavailable because Computer Use did not resolve Simulator. This is not claimed as a rendered-layout pass.
- The user scanned the QR code. After the corrected update, the Mac native Settings displayed one authenticated connected phone and the user explicitly confirmed “Live agents are showing.” This establishes physical live agent delivery. Phone statistics, camera-denial recovery and all reconnection scenarios are not yet separately accepted.

The app must remain foregrounded on the phone for live delivery. The first connection can briefly show snapshots before analytics arrives on the following refresh. Missing observations remain gaps in the shared reports.

## Pairing feedback correction — 0.3.1

The original phone build omitted its Bonjour declaration, and browser waiting states had no actionable status. The corrected build includes the explicit declaration, handles browser waiting/failure, and gives recovery guidance after 15 seconds without discovery. Connection state is true only after authenticated TLS readiness and becomes false immediately on disconnect. A saved code is labeled as saved, rather than connected; first live delivery takes the phone to Agents.

Version 0.3.1 uses a bright blue beacon icon generated with the built-in ImageGen tool. The exact prompt and asset provenance are in `docs/icon-prompt.txt`; the earlier dark icon generator was removed. Existing 46 core and four companion tests pass in `work/pairing-fix-tests.log`. These pure tests do not independently cover every permission/physical-network state.


## Widgets and Watch — 0.5 source

The iPhone app and widget share `group.dev.andeplane.swarmbell`; the Watch and its
widget use a separate local container with the same group identifier. Only schema
version, counts, coverage, observation/receipt timestamps and connection state enter
the cache and WatchConnectivity. No conversations or pairing credentials are copied.
Count files are atomic and readable after first unlock for Lock Screen access; the
pairing Keychain remains unlocked-only and device-only.

Widget timelines request a 15-minute refresh; actual delivery is controlled by the
system. App-side reloads happen on count/coverage/connection changes or after 15
minutes, rather than every collector tick. Unknown data is a dash and cached data
is labelled last known. WatchConnectivity coalesces the latest aggregate, sends an
immediate message when reachable, and accepts only a read-only cached-count request.
Unpairing clears local counts and sends an explicit Watch clearing update.

Source/build tests and physical device acceptance are recorded separately. See
[companion setup](../apps/ios/README.md) and [aggregate schema](../apps/Shared/README.md).


## Saved pairing authorization after a Mac update

Launch restoration reads the existing Keychain item without opening an
interaction dialog. If macOS needs permission for the updated app signature,
Settings shows **Authorize sharing…**. That explicit retry may ask macOS to
present its normal Keychain authorization prompt on a background worker, so
collection and the menu bar stay responsive. Approve the system prompt yourself.
Authorization failures do not replace the saved key or require a new QR pairing.
Local development updates use the same installed signing identity when available.
