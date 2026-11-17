# Validation — 15 November 2026

Repository: `~/projects/personal/swarmbell`.

## Menu and source usage fixes — 0.3.2

The Mac 0.3.2/build 6 is installed and running. Native inspection verified plain active counts, matching Working rows, source-reported Codex token values and exclusion of claude-mem observer sessions. The popover uses the status item's screen and corrects its bounds after dynamic sizing. Existing pairing material loaded and sharing remained ready. All 71 Swift tests, six standalone placement checks, strict formatting, app build and deep signature verification passed. Tokens include cached input and are not billed cost. iPhone code's count formatting is updated in source only; no phone install or redesign occurred. See [usage semantics](usage.md).

## Source-only cached snapshot boundary — 16 November 2026

The native collector backend now publishes a bounded private atomic cache, with independent persistent collector identity, per-run sequence and unchanged source coverage/freshness. The CLI's exclusive `--read-current` branch reads it without collector/history/pairing setup. All 59 core tests and four companion tests pass, including 13 cache tests; the real CLI also passed isolated synthetic-cache checks without provider execution or file mutation. App source build, formatting and diff checks pass. The installed app was not restarted/updated, no device work occurred and no external ingestion was tested. See [the exact read contract](current-snapshot.md).

## iPhone work — 16 November 2026

Version 0.3.0 adds a paired read-only iPhone companion and optional encrypted Mac snapshot sharing. The existing 46 core tests plus four companion tests pass. Matching-key TLS authentication and wrong-key rejection passed isolated smoke checks. Mac and signed iOS builds pass; the installed Mac listener is ready with its pairing sheet displayed. The corrected iPhone 0.3.1/build 5 installed and launched after reconnect. The Mac showed one authenticated phone and the user confirmed live agents are visible. Phone statistics and exhaustive reconnect/permission recovery remain separately unverified. See [the full companion evidence](iphone-companion.md).

## Current code and package

- `swift test -j 2`: **46 tests passed**, including source failures, Codex desktop revisions/leases, Claude Desktop navigation/ownership, hook installation, persistence, simultaneous writers, time weighting, DST, exact range edges and statistics version isolation. Log: `work/review-tests.log`.
- Strict Swift formatting lint and `git diff --check`: passed.
- App bundle build and `codesign --verify --deep --strict`: passed. Version 0.2.1 is installed at `dist/Agent Beacon.app`. Build log: `work/review-app-build.log`.
- Cursor event files remain private (`0600` in a `0700` directory) and can be collected/read while the Mac is locked. A lock-dependent file-protection option discovered in the locked-session test was removed.

## Live evidence

- Native quick switcher launched and displayed real Claude and Codex sessions, installed harness icons, attention-first grouping, search and source coverage.
- The revised native dashboard displayed real collected history with readable full-width harness/period controls and an explicit Close action. Closing with that button worked. Opening the menu through its shared status-item callback displayed the popover without reopening Statistics.
- Clicking the previously failing Claude session opened its correct existing Claude Desktop conversation. The actual title and `local_` session route matched the resolver's target. No Terminal was launched and no pending agent approval was accepted.
- Codex desktop passive observation produced live working states. It is explicitly version-bound and partial. No session was resumed, started, claimed or approved to collect status.
- Six Cursor lifecycle commands were installed through the bundled helper. Original Orca/claude-mem entries and unknown fields were compared before/after and remained identical. The exact original backup was verified at `~/Library/Application Support/AgentBeacon/cursor-hook-backups/hooks-<UUID>.json`. Private receipt: `work/cursor-install-receipt.json`.
- Initial Claude polling generated three snapshots exactly five seconds apart. Later native collection ran continuously between development restarts; sleep/stopped intervals are not filled with activity.

## Corrected statistics acceptance

Live QA found an unrelated stale session invalidated an entire harness, fragmenting one continuous wait into hundreds of prototype episodes. This was corrected and regression-tested: ten observations with an unrelated stale record produce one episode and 45 seconds waiting, while complete coverage stays false.

Version 3 retains all raw measurements and older derived tables, but reports only trusted version 3 durations/episodes. The last-frame baseline is independently versioned. A live three-sample run of the corrected collector against the real local database measured approximately 10.14 observed seconds, 10.14 waiting agent-seconds, and **one** attention episode; old bogus fragments were excluded. 460 original raw measurements remained available at that check. Evidence: `work/corrected-live-samples.jsonl` and `work/corrected-statistics.json`. The revised dashboard also displayed plausible trusted durations/episode totals after collection resumed. These are observed test results, not permanent current counts.

## Final native review

After the user unlocked the Mac, the installed 0.2.1 build launched successfully. Native screenshots verified the menu shows the needs-you row and all four working rows together, with readable two-line titles and the footer visible. The dashboard shows complete harness selections, readable histogram/heatmap controls, custom date fields and filtered Claude Code statistics. Filters were restored to All harnesses / Last 7 days. Both the explicit Close button and Command-W close Statistics. Monitoring was left running with Statistics closed and the agent menu visible.

Remaining acceptance limits:

- Drag-based compact-window resizing did not change the window through Computer Use; 900×650 visual acceptance remains unverified. The adaptive layout is implemented and the default 1080×820 layout is visually verified.
- Shortcut registration reports no error, but injected global-key checks did not establish switcher activation. The original Control–Option–Space setting was restored. Manual physical-key acceptance remains open; do not claim it passed.
- Clicking a Codex row requested its existing-thread route, but Computer Use explicitly blocks access to `com.openai.codex` for safety reasons. No alternate automation was used to bypass that restriction, so exact destination selection remains unverified.

Cursor native approval/question coverage, exact Cursor conversation activation and unknown terminal-pane activation remain product limits. No login item, daemon restart, app-server setting, agent permission or execution policy was changed. The app is signed ad hoc, not notarized for public distribution.
