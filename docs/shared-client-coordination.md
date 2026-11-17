# Shared clients and decision service: architecture notes

Architecture notes for optional shared clients. This assessment reads the current source only. It does not implement a service or authorize remote execution.

## Reuse one collector

Keep Swarmbell as the Mac's passive status collector and native shell. Add an optional authenticated feed from that collector to the shared service; do not add another process polling Claude, Codex and Cursor independently. Keep source commands and approval ownership with their existing harnesses.

| Existing boundary | Exact source/API | Reuse |
|---|---|---|
| Provider contract | [`Sources/SwarmbellCore/Models.swift`](../Sources/SwarmbellCore/Models.swift): `AgentProvider: Sendable`, `var harness: Harness`, `func poll(at: Date) async -> ProviderSnapshot` | Existing source adapters remain the status authority on the owning Mac. |
| Normalized observation | Same file: `AgentRecord`, `ProviderStatus`, `Counts`, `MonitorSnapshot: Codable, Sendable` | Use as the starting point for a separately versioned status-feed schema. `ProviderSnapshot` itself is `Sendable`, not `Codable`. |
| Collection and publication | [`Sources/SwarmbellCore/Monitor.swift`](../Sources/SwarmbellCore/Monitor.swift): `AgentMonitor.refresh(at:) async -> MonitorSnapshot` | One refresh concurrently polls providers, measures them, records optional history and publishes one coherent snapshot. Preserve freshness, source scope and `counts.incomplete`. |
| Local measurements | [`Sources/SwarmbellCore/HistoryStore.swift`](../Sources/SwarmbellCore/HistoryStore.swift): `HistoryStore.record(_:timing:) throws`; [`AnalyticsReport.swift`](../Sources/SwarmbellCore/AnalyticsReport.swift): `report(from:to:timeZone:harness:) throws -> AnalyticsReport` | Reuse local statistics; this database is not a decision journal. `HistoryFrame` stores compact identity/state/reason/quality, not prompts, transcripts, titles or navigation commands. |
| Native Mac shell | [`Sources/SwarmbellApp/AppMain.swift`](../Sources/SwarmbellApp/AppMain.swift), especially `togglePopover()` and `showDashboard()` | Retain menu bar, shortcut panel and explicit dashboard actions. A decision inbox can consume another model without owning collection. |
| Navigation | [`Sources/SwarmbellApp/Navigation.swift`](../Sources/SwarmbellApp/Navigation.swift): `openApplication(_:model:) -> Bool` and allowlisted `desktopURL(for:)` | Existing Mac conversation activation belongs on the owner device. Mobile/web clients need an authenticated handoff to that device, not a claim that Mac URI schemes work everywhere. |

## Separate attention from decisions

`AgentState.needsYou` plus `reason: String?` is an observation. It is neither an actionable approval object nor permission to answer a source request. Codex desktop coverage is versioned/private and partial; Cursor currently lacks complete native attention detection. An inbox may display those observations, but must not invent decision buttons from them.

The proposed MCP decision authority needs its own durable records: stable decision/source/session IDs, the source's underlying request ID, revision, explicit opaque option IDs, current state and expiry. A submitted choice needs authenticated identity, current source authorization, revision/precondition checks, idempotency and a recorded result. The owning source performs the action and confirms resolution; a stale or already-resolved request must not be replayed. Keep this authority and audit lifecycle separate from Swarmbell's observer/history. Agree ownership with other clients before implementing a second decision engine; their sources were not inspected for this note.

## Shared schema and platform limits

`AgentRecord.id` currently joins `host`, harness and session ID; default host is `"local"`. That is not a globally unique device identity. A shared feed needs a stable device/collector ID and an unambiguous source-session key. Preserve collection time, arrival time, monotonic sequence/revision, unknown states, source scope and schema version; choose one explicit UTC date encoding for the transport. The current `MonitorSnapshot.schemaVersion` defaults to `1` and closed enum decoding needs deliberate compatibility rules before becoming a public contract.

The Foundation models are candidates for a small shared Swift package used by macOS, iOS and watchOS. The current package targets macOS 13 and `SwarmbellCore` also contains Darwin process/socket inspection, subprocesses, local hook files and SQLite ownership; it cannot simply be imported unchanged as a mobile collector. Other clients should consume the same versioned transport schema and decision state, with no requirement to run Mac collectors or local executable/argument navigation metadata.

Confidence is high for the cited current boundaries. MCP transport, authentication, a durable decision API, shared-client ownership, additional mobile targets and remote handoff remain planning work. No GUI, live configuration, session, service or existing source file was changed for this note.
