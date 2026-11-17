# Read the existing collector's current snapshot

This backend boundary exports the native app's existing `AgentMonitor` result after each completed refresh. Readers do not poll providers, start the app, open history or access pairing credentials. It is independent of iPhone sharing.

## Source-build command

```sh
swift build -j 2 --product agent-beacon
.build/debug/agent-beacon --read-current
```

The cache defaults to `~/Library/Application Support/AgentBeacon/snapshot-cache/`. `--read-current --cache-directory /absolute/private/cache` selects another existing cache for a reader. Other collection/setup flags cannot be combined with `--read-current`. Unknown flags and invalid combinations fail before collector setup.

The addition was initially source-only at commit `1a0ab97`. The later user-requested menu/usage update installed Mac 0.3.2, whose existing collector now publishes this cache; a live read returned current observations. The frozen 0.3.1 staging artifact remains separate. A missing cache is still an error, not permission to launch a collector. No external consumer ingestion has been validated.

## JSON contract, version 1

Successful reads write one JSON object to stdout and exit 0:

```json
{
  "availability": "current",
  "ageSeconds": 1.25,
  "envelope": {
    "schemaVersion": 1,
    "collectorId": "11111111-1111-4111-8111-111111111111",
    "runId": "22222222-2222-4222-8222-222222222222",
    "sequence": 42,
    "observedAt": "2026-11-16T09:00:00.000000000Z",
    "publishedAt": "2026-11-16T09:00:00.250000000Z",
    "expectedRefreshIntervalSeconds": 5,
    "snapshot": {}
  }
}
```

The example's empty `snapshot` stands for the existing complete `MonitorSnapshot` with its own schemaVersion 1. It includes counts, providers, agents, refresh timings and optional history error. The reader retains coverage, per-provider health/scope/attention capability, per-agent freshness and source timestamps. A stale outer result never converts its nested counts to zero or rewrites stale agents to current.

- `collectorId` is a persistent UUID stored in `identity.json`, independent of pairing identity/secret. It survives ordinary app restarts and pairing resets. Missing/corrupt identity alongside existing cache data fails explicitly; it is not silently regenerated.
- `runId` identifies one writer lifetime. `sequence` increases within that run. Consumers deduplicate `(collectorId, runId, sequence)` and tolerate gaps; failed publication attempts can consume a sequence.
- `observedAt` equals `snapshot.generatedAt`, the original refresh-start timestamp. `publishedAt` describes publication, not a new observation. UTC ISO8601 dates use nine fractional digits.
- Age is computed from `observedAt`. Availability becomes `stale` when age exceeds `max(15, 3 × expectedRefreshIntervalSeconds)`; the production interval is 5 seconds. Publishing old evidence cannot freshen it. Future clock skew beyond 30 seconds is rejected.
- A `current` cache does not mean complete source coverage. Preserve `counts.incomplete`, `providers[].health`, `observesAttention`, and `agents[].freshness` independently.
- No task ID, approval authority or global device identity is invented. The collector UUID scopes existing `(host, harness, sessionID)` keys; it does not solve deduplication of the same remote session observed by multiple Macs.

Missing, unsafe, malformed, oversized, inconsistent or unsupported cache data produces stderr and exit 1, with no successful JSON output. Stale valid data exits 0 with `availability: "stale"`; consumers must inspect it.

## Filesystem and ownership

Only the native app backend publishes. A lifetime nonblocking advisory `flock` on `writer.lock` rejects another cooperating writer. The cache directory is owned by the current user and mode 0700; identity, current snapshot and lock files are private regular files with mode 0600 and one link. A reader may finish using a private inode already opened before atomic replacement unlinked it; multiple hard links are rejected. Symlinks, unsafe existing permissions and wrong ownership are rejected rather than repaired. Reads never create files or obtain a write lease.

`current.json` is bounded to 8 MiB; identity is bounded to 1 KiB. Publication writes a private same-directory temporary file, fsyncs it, atomically renames it, and fsyncs the directory. Normal failures remove the temporary file; an abrupt process crash can leave a private orphan temporary file. The bound is per published payload, not an aggregate disk quota. Readers open existing descriptors and never see a partially replaced publication. Cooperative ownership and same-user filesystem permissions are not protection from malicious code already running as that user.

The latest cache contains current titles, project paths and navigation metadata. It is separate from measurement history and provides no history-export operation. Losing the collector process leaves the last observation on disk; its age continues increasing. Readers must not infer a running collector merely from the file's existence.

## Validation

- `swift test -j 2`: 59 core tests (including 13 focused cache tests) and four companion tests pass. Evidence: `work/snapshot-cache-all-tests.log`.
- The cache tests cover stable collector identity across runs, new run/sequence behavior, unchanged provider/agent evidence and subsecond timestamps, stale/clock-skew cases, identity and lease tampering, concurrent atomic reads, duplicate writers, bounds, unsafe modes, symlinks, hard links, FIFOs and publication failure sequence gaps.
- `python3 Tests/cli_read_current.py .build/debug/agent-beacon` passes against synthetic private caches. It checks current/stale/missing/invalid cases, unchanged cache bytes/mtimes, no created history or writer files, rejected setup combinations and no provider execution through PATH traps. It accesses no real collector, user cache, credentials or history.
- Native app source builds, strict Swift formatting lint and diff checks pass. The running installed app was not stopped, launched, updated or queried for live ingestion acceptance.
