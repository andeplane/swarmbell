#!/bin/bash
set -euo pipefail
glance_source_dir="$(cd "$(dirname "$0")" && pwd)"
glance_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/swarmbell-glance.XXXXXX")"
trap 'rm -rf "$glance_test_dir"' EXIT
cat > "$glance_test_dir/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}
func rejects(_ body: () throws -> Void, _ message: String) {
    do { try body(); fatalError(message) } catch {}
}

let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
func snapshot(
    date: Date = now, received: Date = now, active: Int = 4, working: Int = 3,
    needsYou: Int = 1, connection: GlanceSnapshot.Connection = .connected
) -> GlanceSnapshot {
    GlanceSnapshot(observedAt: date, receivedAt: received, active: active, working: working,
                   needsYou: needsYou, incomplete: false, connection: connection)
}
let valid = snapshot()
let encoded = try valid.encodedData()
let decoded = try GlanceSnapshot.decode(encoded)
expect(decoded == valid, "Valid schema must round-trip without changing counts")
expect(decoded.isCurrent(at: now), "Fresh connected counts must be current")
expect(!decoded.isCurrent(at: now.addingTimeInterval(21)), "Old observations must become stale")
expect(!snapshot(received: now.addingTimeInterval(-21)).isCurrent(at: now), "Old receipt must be stale")
expect(!snapshot(connection: .disconnected).isCurrent(at: now), "Disconnected counts must never be current")
try snapshot(active: 0, working: 0, needsYou: 0).validate(at: now)
rejects({ try snapshot(active: -1).validate(at: now) }, "Negative counts must fail")
rejects({ try snapshot(active: 1_000_001, working: 1_000_000).validate(at: now) }, "Excessive counts must fail")
rejects({ try snapshot(active: 4, working: 4, needsYou: 1).validate(at: now) }, "Inconsistent counts must fail")
rejects({ try snapshot(date: now.addingTimeInterval(31)).validate(at: now) }, "Future observation must fail")
rejects({ try snapshot(received: now.addingTimeInterval(31)).validate(at: now) }, "Future receipt must fail")
rejects({ _ = try GlanceSnapshot.decode(Data(repeating: 32, count: 4_097)) }, "Oversized payload must fail")
rejects({ _ = try GlanceSnapshot.decode(Data("{}".utf8)) }, "Incomplete schema must fail")
var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
object["version"] = 2
rejects({ _ = try GlanceSnapshot.decode(JSONSerialization.data(withJSONObject: object)) }, "Unknown version must fail")
object["version"] = 1
object["connection"] = "made-up"
rejects({ _ = try GlanceSnapshot.decode(JSONSerialization.data(withJSONObject: object)) }, "Unknown connection must fail")

let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: cacheDirectory) }
let store = GlanceStore(directory: cacheDirectory)
expect(store.load() == nil, "Missing cache must be unavailable, not a zero snapshot")
expect(try store.save(valid), "First observation must be saved")
expect(store.load() == valid, "Cache must round-trip")
rejects({ try store.save(snapshot(active: -1)) }, "Invalid observation must not replace last good")
expect(store.load() == valid, "Invalid save must preserve last good")
expect(try !store.save(snapshot(date: now.addingTimeInterval(-1))), "Older observation must be ignored")
expect(store.load() == valid, "Older observation must preserve last good")
expect(try !store.save(valid), "Duplicate observation must be ignored")
let disconnected = snapshot(received: now.addingTimeInterval(1), connection: .disconnected)
expect(try store.save(disconnected), "Connection change at the same observation must be saved")
expect(store.load()?.connection == .disconnected, "Connection change must persist")
try store.clear()
expect(store.load() == nil, "Reset must clear counts, not replace them with zeros")
try store.clear()
print("Glance schema/cache checks passed: bounds, freshness, decoding, last-good, ordering and reset.")
SWIFT
swiftc -swift-version 6 "$glance_source_dir/GlanceSnapshot.swift" "$glance_source_dir/GlanceStore.swift" "$glance_test_dir/main.swift" -o "$glance_test_dir/validate-glance"
"$glance_test_dir/validate-glance"
