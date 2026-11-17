# Swarmbell for iPhone

Native iOS 17+ read-only companion for the existing Swarmbell Mac collector.
It receives live snapshots and read-only history reports through the paired,
TLS-PSK encrypted local connection. Updated Macs support custom ranges up to
366 days, harness filters and comparisons; older Macs retain seven-/thirty-day reports. It does not run another collector or submit
agent approvals/actions. No sample agent data is included.

Open Swarmbell Settings on the Mac, enable iPhone sharing, then scan the
pairing QR code from the phone's Connection tab. A complete pairing link may
also be pasted. The link is a secret granting read access; the phone stores it
in its device-only, unlocked Keychain. Keep the Mac app running and allow Local
Network access on iPhone. The companion reconnects when it returns to the
foreground; stale data is marked and live counts are withheld after 15 seconds
without an update. Widgets show last-known counts and their observation age. iOS schedules widget
refreshes; there is no continuous background Mac connection or Internet relay.

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


## Widgets and Apple Watch

The project also builds `SwarmbellWidgets`, `SwarmbellWatch` and
`SwarmbellWatchWidgets`. They share only validated aggregate counts through
`group.dev.andeplane.swarmbell`; pairing secrets remain in the phone Keychain.
Register all four bundle IDs and the App Group on your own development team,
then generate development profiles with App Groups enabled. Do not reuse
another product's App Group or provisioning profile.

Home Screen widgets support small and medium layouts. Lock Screen widgets and
Watch complications support circular, rectangular and inline layouts. After
installing, open the iPhone app to connect to your Mac, then add Swarmbell using
the system widget gallery or the watch-face complication picker. Apps cannot
silently add widgets or choose your watch face.

The Watch receives counts through WatchConnectivity from the phone. Context
updates coalesce while devices are apart; delivery and complication refreshes
follow Apple's budgets. Both widgets and complications explicitly show last-known
counts; missing data shows dashes, never a fabricated zero. Forgetting a Mac
clears the phone cache and queues a clearing update for the Watch. All companion
surfaces are read-only.

See [shared schema and refresh behavior](../Shared/README.md).


For an existing manual provisioning setup, the generated targets also accept
`SWARMBELL_PHONE_PROFILE`, `SWARMBELL_WIDGET_PROFILE`, `SWARMBELL_WATCH_PROFILE`
and `SWARMBELL_COMPLICATION_PROFILE`. Pass your own profile names or UUIDs along
with `CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=YOUR_TEAM_ID`. These values are
local build inputs; provisioning profiles and device identifiers are not shipped
in the repository.
