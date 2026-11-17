# Swarmbell implementation plan

## Primary goal

The user can see how many coding agents are active and need attention across Codex, Claude Code, and Cursor from the macOS menu bar, then open the exact conversation in one action. A global shortcut opens a searchable panel with agents needing attention first.

## Implementation status

The native app, menu bar, shortcut panel, local measurement store and statistics dashboard are implemented. Live Claude and versioned private Codex desktop observation work. Exact Claude Desktop navigation is now verified in the native UI. Cursor's lifecycle hooks are safely installed with existing hooks preserved; native Cursor attention and exact Cursor conversation activation remain coverage limits. The dashboard includes day/week/month/custom ranges, harness filters, time series, hour/weekday histograms, a heatmap, observed waits and source/latency diagnostics. Live review verified corrected statistics, readable header controls, explicit window closure and menu-only presentation. The latest popover-height correction is built and visually verified after unlock; Command-W, custom date controls and harness filtering also passed. Compact-window, physical global-shortcut and Codex destination checks remain explicitly unverified. See validation.md for the acceptance record.

## Phase 0 — Establish real integration contracts

**How this serves the primary goal:** The counts and links must describe existing sessions in the apps the user uses, rather than sessions launched by a separate agent runtime.

Status: discovery completed; gaps below remain open. Read [integration evidence](integrations.md) before implementing an adapter. Allowed interfaces: Claude's JSON session command; Codex's existing-daemon app-server read methods; Cursor's lifecycle hook envelope. Current native-chat navigation is not yet established across all three.

Verification: check installed CLI help against the documented options; collect minimal live field names; generate Codex schema locally; inspect current Cursor hook event names without replacing configuration. Keep source coverage alongside every observation.

Guard: a new app-server process, a file timestamp, a running OS process, or an old transcript does not establish that a particular existing thread is actively working.

## Phase 1 — Build the internal monitoring core

**How this serves the primary goal:** Both menu bar and shortcut panel need one consistent answer about activity and attention.

Status: initial implementation complete in `SwarmbellCore`; CLI test harness included. Native Swift, no external packages, no hosted service. Use `Models.swift` and `AgentMonitor` as the shared contract. Poll sources concurrently on a five-second start-to-start cadence, bound child-process time and output, and publish atomic snapshots. Keep host/harness/session identity, source health, freshness, reason, workspace, title, and navigation capability.

Count working plus needs-you as active. Show ordinary idle and completed sessions separately. Default headline counts exclude child agents; retain them for a later disclosure or setting. This default is proposed, not a confirmed user preference. Unknown/missing/stale records never become fabricated needs-you or finished records.

Verification: tests cover attention ordering, identity collisions, count semantics, schema drift, source outages/recovery, missing sessions, process timeouts, noisy output, and Cursor generation ordering. Live Claude samples validate a five-second refresh.

Guard: failed discovery is not zero sessions. When any source is partial, the future UI must show counts as incomplete.

## Phase 2 — Close discovery and attention gaps

**How this serves the primary goal:** A cross-app counter is only useful when it covers the user's actual running sessions and catches their requests for help.

Implement these as separate provider capabilities, using the exact contracts in `integrations.md`:

1. **Claude:** keep the verified JSON adapter, measure polling cost, and add compatible older-version behavior only if required by a supported installed version. Capture terminal/app identity without reading conversation text. Distinguish terminal, IDE, and desktop-hosted sessions.
2. **Codex:** establish whether the desktop app can expose or share its live server with a read-only observer. Verify running, approval, question, idle, and stop states on real desktop and CLI sessions. Retain unavailable/partial coverage until that proof exists. Use status notifications only when a passive subscription is supported without resuming sessions.
3. **Cursor:** package the existing lifecycle helper at a stable app-bundle path. Implement idempotent merge/removal of its own hooks, preserving Orca/claude-mem commands. Add incremental event consumption, retention, and startup discovery. Establish a supported or explicitly versioned observation path for native approval and question states; if necessary, assess a narrow opt-in Accessibility observer against real dialogs. A process-wide CPU reading or quiet transcript is insufficient.

Verification: exercise already-running sessions as well as newly started ones; multiple workspaces/windows; permission and question waits; interrupted work; hook failures; app/CLI upgrades; sleep/wake; app crash/restart. Check existing hooks still behave as before.

Guard: no guessed Cursor attention state; no copying arbitrary private databases or scraping every transcript every five seconds. Optional cloud and remote-host agents must have their own clearly defined coverage.

## Phase 3 — Open the exact original conversation

**How this serves the primary goal:** Clicking an attention row should take the user directly to the decision, without searching inside the harness.

Introduce a tested navigation adapter per harness. Preserve native thread ID, originating host, workspace, app/window or terminal identity, and verified activation capability. Prefer documented links/commands when they genuinely target the original conversation. For terminal Claude sessions, focus the existing terminal/tmux pane when possible; background attach is a separate supported action. Never run a second writer by automatically resuming a busy session.

Use the existing `Navigation` value as capability data; the UI must distinguish exact activation, terminal attach/resume fallback, workspace fallback, and copy-ID. Unsupported fallbacks remain visibly labeled and do not satisfy exact-thread acceptance.

Verification: open two distinct conversations in each app, including identical project names; click each and prove the intended thread is selected. Repeat with multiple windows, a closed window, remote host, and a stopped task. Record supported application versions and rollback behavior for any private integration.

Guard: opening the right app, starting a new prompt, or opening a workspace is not proof of opening the right thread.

## Phase 4 — Build the menu bar and shortcut panel

**How this serves the primary goal:** The verified state and navigation become available in a glance or a single shortcut.

Implement an AppKit menu bar shell with SwiftUI row/list content and a shared view model driven by `AgentMonitor`. Use [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem) and [NSPanel](https://developer.apple.com/documentation/appkit/nspanel), following the proposed direction in `DESIGN.md` and the concept board.

Menu bar: glyph, active count, needs-you count, accessible labels, and a visible partial/offline treatment. Popover: needs-you first, then working, with harness icons, project, title, reason and age. Shortcut panel: search across all three harnesses, keyboard selection, Return to activate, Escape to dismiss and restore focus. Proposed configurable default: Control–Option–Space; check conflicts instead of silently taking Spotlight's shortcut. Show relevant source issues in the list.

Verification: real light/dark UI screenshots, keyboard-only use, VoiceOver, reduced motion, increased contrast, 0/1/many sessions, long titles, missing apps, offline source, display/Spaces/full-screen behavior, sleep/wake, selection stability during refresh, and search while statuses change.

Guard: generated concept logos/counts are illustrative; the native app uses installed application icons and measured core counts. The user has explicitly requested and authorized the UI implementation.

## Phase 5 — Package and verify everyday use

**How this serves the primary goal:** The utility should remain reliable while the user works, without requiring a terminal or constant maintenance.

Create a signed app bundle with the hook helper, stable settings and local logs, optional launch-at-login, and explicit diagnostic source coverage. Measure idle CPU, polling latency, disk work, and memory with many sessions. Define a measurable budget from real traces before release. Add event retention, dependency/version checks, schema compatibility fixtures and a bounded observation run. No App Store distribution assumption is needed for the first personal build.

Verification: an acceptance matrix across all three real apps proves running → approval/input → running → stopped/completed; exact-thread activation works; setup/uninstall preserves other hooks; no monitoring process remains after quit; source outages cannot present a false all-clear; five-second updates recover after wake. Repeat required tests, format, and lint after final edits. No live session should be altered just to collect status.

Guard: unit tests and mocked transports do not establish cross-harness live acceptance. Keep unresolved coverage/navigation blockers visible until verified. If opening a PR later, include the required screenshots and follow it until merge or closure.

## Current next actions

- Keep Codex desktop observation version-bound and partial; broaden discovery before claiming exhaustive coverage.
- Verify Cursor native attention and exact-chat navigation; retain partial coverage meanwhile.
- Safe Cursor hook setup and uninstall are implemented and tested; incremental spool maintenance remains follow-up work.
- Complete the remaining compact-window, physical global-shortcut and Codex destination acceptance checks described in validation.md.

Remote/cloud agents, agent execution controls, sending replies, and automatic approval are outside the first local monitoring release.
