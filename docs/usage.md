# Session usage and internal workers — 0.3.2

Codex's existing passive desktop stream exposes `latestTokenUsageInfo.total`. Its generated `ThreadTokenUsageUpdatedNotification` contract defines input, cached input, output, reasoning output and total tokens; cache-write input is optional. The shipped event handler copies `thread/tokenUsage/updated` into that conversation field. Swarmbell retains only those numeric counters and observation time, including subsequent nested patches and removals.

The displayed value is the source-reported cumulative session total. It is not time-based estimation, unique text length or a dollar charge. Cache reads are an input subset and reasoning is an output subset; they are not added again to the total. Negative, fractional, Boolean, overflowing, absent, incomplete, invalidated or expired usage is unavailable rather than zero. A configured model is not per-turn execution telemetry, so it is not used to price cumulative mixed-model usage.

`AgentRecord.usage` is optional additive metadata with a `scope`, source, observation timestamp and numeric counters. Existing snapshots without it continue to decode; consumers that do not use it can ignore it. The shared cache and paired stream carry the optional field. Measurement history's existing duration/count calculations are unchanged; this change does not introduce historical token/cost charts.

Claude and Cursor token/cost totals are not populated in this version. Claude's [statusline context counters](https://code.claude.com/docs/en/statusline) describe context usage, and its cost value is a client-side estimate. A future transcript reader would need bounded metadata-only parsing, message-ID deduplication, version checks and completeness semantics. Cursor's [lifecycle hooks](https://cursor.com/docs/hooks) do not provide cumulative usage; [SDK usage APIs](https://cursor.com/docs/sdk/typescript#usage-and-billing) do not establish access to arbitrary existing IDE sessions. Swarmbell does not acquire new provider credentials or query billing APIs for this feature.

## Internal memory workers

claude-mem can spawn internal Claude observer subprocesses from its Bun `worker-service.cjs`. These use private working directories under `~/.claude-mem/observer-sessions/<session>`, independently of the coding harness selected by the user. Read-only session metadata and process ownership distinguish these observers from ordinary coding sessions.

Swarmbell now excludes the current user's known observer root and its numeric session directories (including descendants). This is based on workspace provenance, never merely a session title, a generic Claude label or the selected model. Same-named ordinary project sessions remain visible. This filters status/list/cache/companion records; it does not stop, disable or modify the memory worker, other clients, Cursor hooks or Claude settings. Custom memory data roots are not inferred from arbitrary folder names. Historical samples are retained unchanged.

Native lists also omit child agents excluded from the default headline count, so Working rows agree with headline counts. Raw snapshots retain real child records marked `isSubagent` for consumers that need them.

## Validation

71 Swift tests pass (67 core, four companion), including four new token projection tests and four memory-worker regressions. Six standalone geometry cases check right/left/bottom bounds, oversized popovers, negative multi-display coordinates and idempotence. Strict formatting, diff checks, app build and deep code-sign verification pass.

The Mac 0.3.2/build 6 was installed and launched with the previous bundle retained as a backup. Native UI inspection showed four active/four working rows with live source-reported token values, no plus suffix and no memory observer. Token values changed with subsequent source updates. The popover screenshot displayed all rows/footer, and placement is constrained against the status item's screen after initial and dynamic sizing. Multi-monitor physical acceptance remains broader than the six pure geometry tests.

Existing pairing credentials loaded and the listener reported ready after the update; no pairing reset or history migration was performed. No iPhone update or UI redesign was installed. The existing-collector snapshot cache is now published by this Mac build; no external consumer ingestion was tested.
