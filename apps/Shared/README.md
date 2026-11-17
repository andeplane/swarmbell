# Aggregate surfaces

`GlanceSnapshot` is the entire widget and Watch payload: schema version, observation
and phone receipt times, active/working/needs-you counts, coverage flag and connection
state. It deliberately contains no thread titles, prompts, paths, credentials or
pairing material. `active` equals `working + needsYou`.

Use `encodedData()` / `GlanceSnapshot.decode(_:)` for ISO8601 JSON. These methods
validate counts (0...1,000,000), schema version, finite nonnegative dates and maximum
30-second future skew. Payloads larger than 4 KiB are rejected. Unknown enum values
or missing fields fail decoding. `isCurrent(at:)` additionally requires connected
status and both timestamps no more than 20 seconds old.

`GlanceStore.shared.load()` returns an optional snapshot; `save(_:) throws -> Bool`
atomically saves only valid, non-older data; `clear()` removes it. The optional
directory initializer supports isolated tests. The App Group is
`group.dev.andeplane.swarmbell`, with a private `Library/SwarmbellGlance/counts-v1.json`
file. File protection is complete-until-first-user-authentication so counts can be
read on a locked screen after the first unlock. The phone's pairing keychain remains
separate and uses its existing stronger protection.

WatchConnectivity sends encoded `Data` under `swarmbell.glance.v1`; empty `Data()` is
an explicit unpair/reset tombstone. The iPhone sends the latest application context
and, when reachable, a message. The Watch can request the existing aggregate with
`["requestGlance": true]`; this cannot perform an agent action. Phone and Watch App
Groups are local stores on separate devices, not a cross-device filesystem.

Widgets read only this cache and always label values as **Last known** with the
observation age. They never claim to be live: WidgetKit controls update budgets and
may delay the requested 15-minute timeline refresh. Meaningful app-side changes
request timeline reloads. No extension polls the Mac or keeps a five-second timer.
Unknown/unpaired counts use a dash; a successfully observed empty set displays zero.
System privacy redaction is enabled for counts. Widget URLs open the read-only
`swarmbell://agents` destination.

Run `bash apps/Shared/validate-glance-cache.sh` for isolated schema/cache checks.
