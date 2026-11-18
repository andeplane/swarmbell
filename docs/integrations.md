# Integration evidence — 15 November 2026

## Claude Code

[Official agent-view documentation](https://code.claude.com/docs/en/agent-view#list-sessions-as-json), sections **List sessions as JSON** and **Read session state from a script**, explicitly describes `claude agents --json --all` for external status bars. The installed `claude agents --help` confirms the JSON flag and interactive/background coverage.

Use job `state` first and process `status` second. Preserve `waitingFor` so approvals, questions, and sandbox waits remain distinguishable. `state=working,status=idle` can mean autonomous work between steps; `status=idle` alone is ordinary idle. The implementation decodes a typed allowlist rather than exposing transcripts.

Live polling returned interactive sessions with `sessionId`, `cwd`, `name`, `pid`, `status`, `waitingFor`, and `startedAt`. A blocked live session was observed. Three monitor samples were generated five seconds apart; confirmed active counts changed 1 → 2 → 1 during that check. These are observations at the time of testing, not persistent current counts.

The official [CLI reference](https://code.claude.com/docs/en/cli-reference) and agent-view page describe `claude attach <id>` and `claude --resume <sessionId>`. Neither focuses an existing terminal pane. The app does not automatically resume another writer into a busy conversation.

### Installed Claude Desktop navigation

Claude Desktop 5.11492.5 handles `claude://code/continue?session=local_<UUID>` by looking up an existing local conversation and navigating to its route, without submitting or resuming a turn. This is a versioned private integration. Live process ancestry proved the reported CLI sessions belonged to Claude Desktop. The resolver checks that ancestry and maps the CLI UUID through bounded allowlisted metadata under `~/Library/Application Support/Claude/claude-code-sessions/<account>/<organization>/local_*.json`. It requires one unarchived match with a valid filename/session ID; uncertain origins remain copy-ID only.

Native UI acceptance clicked the previously failing Claude row and selected the expected Desktop conversation, with its actual title and matching `local_` ID visible in Claude's route. No pending approval was accepted. Metadata titles improve the session list but are not persisted in measurement history. Temporary unreadable files are retried after unlock. Unknown terminal origins never launch a generic Terminal window.

## Codex

[Official App Server documentation](https://learn.chatgpt.com/docs/app-server), sections **Initialization**, **Read a stored thread**, **Track thread status changes**, and **List loaded threads**, documents the read-only discovery protocol. Use initialization, list loaded IDs, and read their runtime summaries; never resume threads to observe them.

The installed CLI confirms `codex app-server proxy --sock <path>`. Generated protocol schema, obtained with `codex app-server generate-json-schema --out work/codex-schema`, defines `ThreadStatus` and `ThreadActiveFlag` in `v2/ThreadReadResponse.json`. Allowed flags are `waitingOnApproval` and `waitingOnUserInput`. An active thread without flags is working. Unrecognized flags are uncertain.

The default `~/.codex/app-server-control/app-server-control.sock` symlink is dangling on this Mac. Both proxy and daemon-version probes failed with a missing-socket error. The app's separate IPC socket is not treated as a documented app-server transport. Starting a new independent server would not prove visibility of desktop activity and is deliberately not done.

The documented fallback covers the connected daemon's loaded threads, not every independently hosted process.

### Installed desktop observer

The implementation now also observes `/Applications/ChatGPT.app/Contents/Resources/app.asar`, package `openai-codex-electron` version `26.1103.60933`, through its private local IPC router at `~/.codex/ipc/ipc.sock`. Frames are length-prefixed JSON. Initialization and `thread-stream-following-changed` subscribe to streams already owned/cached by the app; snapshots and revision-checked patches carry `threadRuntimeStatus`. No turn, resume, ownership claim or approval is sent. The adapter projects only status/navigation metadata and discards transcript content.

A live Swift probe observed five working desktop sessions and idle sessions; real approval/input mapping is fixture-verified because no live Codex approval was pending. Discovery is limited to 64 recent candidate IDs plus live announcements, at most 256 projections and 128 MiB per frame. It always reports partial coverage. Owner loss invalidates state; quiet active streams renew after45seconds and become unknown after60seconds without evidence. This is a versioned private integration, not a stable public API.

Shipped code explicitly constructs `codex://threads/<UUID>` with an optional `hostId`. The app uses that observed route for Codex rows. Actual exact-thread selection remains a UI acceptance check. Unsupported sessions offer a clearly labeled copy-ID action and visible feedback.

## Cursor

[Official hooks documentation](https://cursor.com/docs/hooks), sections **Configuration**, **Common schema**, **stop**, **sessionStart**, and **sessionEnd**, documents lifecycle events with conversation and generation IDs. The implementation observes only lifecycle hooks; it does not return tool-permission decisions.

`beforeSubmitPrompt` starts work. `stop.status` distinguishes completion, cancellation, and error. `afterAgentResponse` can precede more work, so it is not treated as completion. A late stop for a previous generation cannot overwrite a newer turn. Missing events eventually make activity uncertain. No documented hook found establishes every native permission/question wait; attempts to run tools must not be mistaken for confirmed approval waits.

The existing user hooks configuration contains Orca and claude-mem integrations. Swarmbell's installer has now merged six passive lifecycle commands, preserved the existing entries and unknown fields, and verified an exact original backup under `~/Library/Application Support/AgentBeacon/cursor-hook-backups/`. Settings and the CLI support ownership-only removal. Setup is idempotent, checks for concurrent edits, preserves permissions, rejects malformed settings/symlinks, and never replaces other plugins' commands.

[Cursor deeplinks](https://cursor.com/docs/reference/deeplinks) do not establish reopening an existing local chat. [CLI parameters](https://cursor.com/docs/cli/reference/parameters) document a resume option, but desktop/CLI ID compatibility has not been established. The prototype does not claim desktop-chat activation.

## macOS shell

[NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem) provides the menu bar item. [NSPanel](https://developer.apple.com/documentation/appkit/nspanel) provides the proposed floating window. UI implementation must verify global shortcut registration, Spaces/full-screen behavior, and focus restoration on the actual supported macOS versions.

## Evidence boundaries

Fixture tests demonstrate parsing, transitions, transport behavior, history weighting and failures. Live Claude and Codex desktop polling demonstrate actual local integration. Cursor hook smoke tests use synthetic sessions in an isolated spool; the global lifecycle configuration is installed with preservation/backup checks. A native app bundle is signed ad hoc and has run with real sessions and a dashboard. Exhaustive cross-harness coverage, all original-thread routes, notarized distribution and everyday performance remain unverified. No login item, daemon, approval setting, or app-server setting was changed.


## Codex asynchronous input — Swarmbell 0.4.0

The installed desktop version 26.1103.60933 can show “Needs input” while its
normal runtime flags and requests array are empty. Its sidebar derives
unanswered asynchronous questions from agent-message question items in the
latest in-progress turn, subtracting accepted user or steering-message reply
identifiers. Runtime flags alone miss this case.

Swarmbell mirrors that derivation for both legacy turn arrays and canonical
turn-history ordering. It retains only bounded turn/item identities, question
counts, statuses and accepted reply identifiers. Question wording, answers,
prompts, transcripts and tool bodies are not retained by the projection. It
handles nested changes, removal, accepted replies, turn completion, invalidation
and resynchronization. Original harnesses retain all response/approval ownership.

A passive live observation reproduced an unanswered question with empty runtime
flags and requests; the corresponding sanitized metadata fixture now maps to
needs-you. The original live question had resolved by the final check, so this
is not a claim that a still-pending real request was acted on or answered.
The adapter remains private, version-bound and partial.
