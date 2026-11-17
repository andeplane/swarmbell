# Swarmbell for iPhone

Native iOS 17+ read-only companion for the existing Swarmbell Mac collector.
It receives live snapshots and seven-/thirty-day reports through the paired,
TLS-PSK encrypted local connection. It does not run another collector or submit
agent approvals/actions. No sample agent data is included.

Open Swarmbell Settings on the Mac, enable iPhone sharing, then scan the
pairing QR code from the phone's Connection tab. A complete pairing link may
also be pasted. The link is a secret granting read access; the phone stores it
in its device-only, unlocked Keychain. Keep the Mac app running and allow Local
Network access on iPhone. The companion reconnects when it returns to the
foreground; stale data is marked and live counts are withheld after 15 seconds
without an update. No background delivery or Internet relay is claimed.

Generate and build from this directory:

```sh
xcodegen generate
xcodebuild -project Swarmbell.xcodeproj -scheme Swarmbell \
  -destination 'generic/platform=iOS' -derivedDataPath ../../work/ios-device \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates build
```

The bundle identifier remains `dev.andeplane.AgentBeacon` so updates preserve
existing app data and permissions. The Keychain service and Bonjour identifiers
also remain unchanged; both Swarmbell and legacy Agent Beacon pairing links are
accepted. The Mac emits the legacy link scheme for older installed companions.
Pass your own Apple Development team with `DEVELOPMENT_TEAM=YOUR_TEAM_ID`; the checked-in project
leaves the team unset. Never borrow another product's profile.
Installation and physical pairing must be verified separately from a successful
simulator build. The app uses native Dynamic Type, semantic colors, system
navigation, SF Symbols, and Swift Charts. The Mac remains responsible for exact
conversation activation; phone session details provide the original session ID.
