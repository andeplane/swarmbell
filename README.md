# Swarmbell

A native macOS menu bar app for seeing which coding agents are working and which need you across Codex, Claude Code, and Cursor. Local history powers a statistics dashboard; no hosted backend or model/API call is used by the monitor.

Formerly Agent Beacon. The app, Swift modules and command-line tools are now Swarmbell. Existing bundle identifiers, local storage, Keychain entries and transport identifiers remain compatible with earlier installations.

## Download the test build

[Download Swarmbell for macOS](https://github.com/andeplane/swarmbell/releases/latest/download/Swarmbell-macOS-universal.zip) — macOS 13+, Apple silicon and Intel. Free during testing. The build is Developer ID signed and notarized by Apple; [read the installation and upgrade instructions](docs/install.md).

Try the browser demo at [swarmbell.ai](https://swarmbell.ai). It uses labelled example data, never a visitor's local agents.

## Build and run

Requires macOS 13+ and a Swift 6 toolchain. Dependencies are system frameworks and SQLite.

```sh
git clone https://github.com/andeplane/swarmbell.git
cd swarmbell
./scripts/build-app.sh
open "dist/Swarmbell.app"
```

Look for the antenna icon and two counts in the menu bar. The first is confirmed active work plus sessions waiting on you; the second is needs-you. Counts are shown without a plus suffix. The tooltip and Limited coverage section explain source uncertainty separately. Click it for the session list, Statistics, Settings, and Quit.

Control–Option–Space opens a searchable quick switcher. Arrow keys move, Return activates the selected row, and Escape closes. The shortcut can be changed or disabled in Settings. Statistics is also accessible from the switcher. Command-W or the dashboard's Close button closes Statistics while collection continues. Command-Q quits the app, including collection. Hold Command and drag the menu bar item to reposition it.

The downloadable test build is Developer ID signed and notarized by Apple. See [installation instructions](docs/install.md). It has no permanent Dock icon and does not install a login item automatically.

## iPhone companion

The 0.5 source includes an iPhone app with the live agent list, needs-you grouping, source details and full read-only statistics. Custom dates, harness filters and comparisons query the Mac’s persisted history; older Macs retain week/month reports. The Mac remains the only collector. The iPhone is a read-only companion on the same local network; it does not run coding agents or answer approvals.

In the Mac's Settings, enable **Share with paired iPhone** and choose **Pair iPhone…**. On the phone, open **Connection → Scan QR code** and scan the private code. Allow Local Network access and camera access when requested. Pairing is stored in each device's Keychain. Closing the Mac app or putting the phone app in the background ends the connection; stale counts are not displayed as live. Reset pairing on the Mac to invalidate earlier phones.

Home Screen and Lock Screen widgets show last-known active and needs-you counts with observation age. A read-only Apple Watch app and watch-face complications receive those aggregates through the phone. Apple controls background refresh timing; these surfaces do not claim continuous live updates.

A locally installed Mac bundle may be placed at `~/Applications/Swarmbell.app`. The iPhone project and physical-device build steps are in [apps/ios](apps/ios/README.md). See [the companion protocol and validation](docs/iphone-companion.md).

## Current source coverage

| Source | Implementation | Limits |
|---|---|---|
| Claude Code | Supported `claude agents --json --all` polling | Live working, blocked, idle and background states verified. Claude Desktop conversations resolve through verified live process ownership and local metadata; terminal-pane activation remains unavailable. |
| Codex desktop | Passive observation of existing desktop thread streams | Working states verified live. Pending asynchronous user questions are projected from bounded question/reply identifiers, including accepted-answer clearing. Private protocol pinned to installed package26.1103.60933; discovers64 recent candidate IDs plus live announcements. Only an existing owner can supply runtime state. Independent CLI/cloud hosts may be outside scope. |
| Codex shared daemon | Read-only app-server proxy fallback | No daemon is started or resumed. Its default socket is currently absent on this Mac. |
| Cursor | Passive lifecycle observer helper, safe hook setup in Settings | Running/completion events only for emitting sessions. Native approvals/questions and existing local-chat activation remain unverified. No event means unavailable, not a successful zero. |

Codex rows use the desktop's observed `codex://threads/...` route. Verified Claude Desktop rows use its existing-conversation route; live acceptance selected the correct conversation. Both are versioned private integrations. Sessions without an exact route explicitly copy the session ID and keep the menu open with feedback. No row starts a second writer by resuming a busy conversation or launches an empty Terminal.

## History and statistics

Codex rows also show source-reported cumulative token totals when available, with exact input/output/cache counts in accessible help text. Cached and reasoning subsets are not added a second time. Unknown usage is shown as `— tokens`; actual dollar spend is unavailable. Memory-plugin observer sessions are excluded by their known private working directory, while real coding sessions remain visible. See [usage and internal-session semantics](docs/usage.md).

Every completed refresh records overall and per-provider collection latency, counts, source health and compact state-transition metadata in `~/Library/Application Support/AgentBeacon/history.sqlite`. The monitor polls every five seconds while the Mac can run; sleep, outages and stopped collection remain gaps. Prompts, transcripts, tool arguments/results, titles and navigation commands are not stored in measurement history.

Statistics includes:

- Last24hours,7days,30days or a custom range, with optional harness filtering and previous-period comparison.
- Active/working/needs-you time series, average and peak concurrency, working and waiting agent-time.
- Hour-of-day and weekday histograms, plus a weekday×hour heatmap in Europe/Oslo.
- Observed attention episodes, resolved waits, reasons and latency percentiles.
- Source coverage and refresh diagnostics, with errors shown if persistence fails.

Agent-time adds simultaneous agents together. It is not human effort, productivity, cost, or precise response time. Only adjacent observations at most15seconds apart receive duration credit. Unknown sessions cannot erase another known session's valid measurements. Waits already open when first observed, interrupted by a gap, or still open are censored from exact resolved-wait comparisons. Charts use bounded minute-based aggregates; selected-range edges are clipped to actual intervals.

History format3 excludes the affected early prototype duration/episode estimates; original raw samples and older tables remain for inspection. No demonstration history is inserted. Read [statistics semantics](docs/statistics.md) and [validation](docs/validation.md).

## Cursor setup

Settings provides Install and Remove for the Cursor lifecycle observer. Installation merges only Swarmbell's six lifecycle commands, preserves other plugin hooks and unknown fields, and keeps an exact private backup. Removal deletes only owned entries, preserving later edits from other tools. Malformed settings and symlinks are rejected.

The bundled helper can also be used directly:

```sh
"dist/Swarmbell.app/Contents/MacOS/swarmbell" --install-cursor-observer
"dist/Swarmbell.app/Contents/MacOS/swarmbell" --remove-cursor-observer
```

Helper paths are absolute. If moving the app bundle, reinstall the observer from the new location. Hook events are private atomic metadata files under `~/Library/Application Support/AgentBeacon/cursor-events/`; transcript/prompt content is discarded. The initial setup in this workspace preserved existing Orca and claude-mem hooks and verified its backup.

## Command-line tools

`swarmbell --read-current` reads the existing app collector's private snapshot cache without launching another collector. The 0.4.0 source continues to publish this cache, including optional source-reported usage. Missing data fails explicitly and old observations are labeled stale. See [the versioned read contract](docs/current-snapshot.md).

```sh
swift run -j 2 swarmbell --watch
swift run -j 2 swarmbell --stats --days 7
swift run -j 2 swarmbell --stats --days 30 --harness claudeCode
```

Default prints one JSON snapshot; `--watch --samples 3` stops after three. Every real refresh is timed and recorded unless `--no-history` is requested. `--history PATH` chooses an isolated database. `--no-codex-desktop` limits Codex to the documented shared-daemon adapter. Explicit CLI/socket paths and timezones are supported; see `--help`.

## Development

```sh
swift test -j 2
swift format format -i -r Package.swift Sources Tests
swift format lint --strict -r Package.swift Sources Tests
```

`SwarmbellCore` is an in-process Swift library. The CLI is a diagnostic/collection harness; the native app uses the same monitor and store. See [the implementation plan](docs/implementation-plan.md), [integration evidence](docs/integrations.md), and [design direction](DESIGN.md).
