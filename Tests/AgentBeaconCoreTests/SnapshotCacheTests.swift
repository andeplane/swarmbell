import Darwin
import Foundation
import Testing

@testable import AgentBeaconCore

private func cacheTestDirectory() -> URL {
  // Foundation preserves the OS's /var alias even after resolvingSymlinksInPath.
  let actual = realpath(FileManager.default.temporaryDirectory.path, nil)!
  defer { free(actual) }
  return URL(fileURLWithPath: String(cString: actual), isDirectory: true)
    .appendingPathComponent("BeaconSnapshotCacheTests-\(UUID().uuidString)", isDirectory: true)
}

private func cacheSnapshot(_ date: Date) -> MonitorSnapshot {
  .init(
    generatedAt: date,
    counts: .init(active: 1, needsYou: 1, working: 0, uncertain: 1, incomplete: true),
    providers: [
      .init(
        harness: .claudeCode, health: .partial, message: "Incomplete fixture coverage",
        checkedAt: date, observesAttention: true, scope: "fixture sessions"),
      .init(
        harness: .codex, health: .unavailable, message: "fixture outage",
        checkedAt: date, observesAttention: false),
    ],
    agents: [
      .init(
        harness: .claudeCode, sessionID: "fixture-wait", title: "Fixture awaiting input",
        state: .needsYou, reason: "question", lastSeen: date,
        changedAt: date.addingTimeInterval(-10)),
      .init(
        harness: .codex, sessionID: "fixture-missing", title: "Fixture missing source",
        state: .working, lastSeen: date.addingTimeInterval(-20), freshness: .missing),
    ],
    refreshTiming: .init(
      startedAt: date, durationMilliseconds: 3.75,
      providers: [.init(harness: .claudeCode, durationMilliseconds: 1.25)]),
    historyError: "fixture measurement storage unavailable")
}

private func cacheSortedJSON<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(value)
}

@Test func snapshotCacheRejectsNonfiniteNestedObservationWithoutReplacingEvidence() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  let writer = try SnapshotCacheWriter(directory: directory)
  try writer.publish(snapshot: cacheSnapshot(instant), at: instant)
  let original = try Data(contentsOf: directory.appendingPathComponent("current.json"))
  var invalid = cacheSnapshot(instant)
  invalid.agents[0].lastSeen = Date(timeIntervalSince1970: .nan)
  #expect(throws: SnapshotCacheError.self) {
    try writer.publish(snapshot: invalid, at: instant)
  }
  #expect(try Data(contentsOf: directory.appendingPathComponent("current.json")) == original)
}

private func changeCachedJSON(
  _ directory: URL, name: String = "current.json", _ change: (inout [String: Any]) -> Void
) throws {
  let file = directory.appendingPathComponent(name)
  var object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
  change(&object)
  try JSONSerialization.data(withJSONObject: object).write(to: file)
}

@Test func snapshotCachePreservesEvidenceAndSubsecondTimestamps() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let instant = Date(timeIntervalSinceReferenceDate: 800_000_000.1234567)
  let snapshot = cacheSnapshot(instant)
  let writer = try SnapshotCacheWriter(directory: directory)
  let published = try writer.publish(snapshot: snapshot, at: instant.addingTimeInterval(0.125))
  let result = try SnapshotCacheReader.read(
    directory: directory, now: instant.addingTimeInterval(1))
  #expect(result.availability == .current)
  #expect(result.ageSeconds == 1)
  #expect(result.envelope.sequence == 1)
  #expect(result.envelope.collectorId == writer.collectorId)
  #expect(result.envelope.observedAt == instant)
  #expect(result.envelope.publishedAt == published.publishedAt)
  #expect(try cacheSortedJSON(result.envelope.snapshot) == cacheSortedJSON(snapshot))
  let encoded = String(decoding: try result.jsonData(), as: UTF8.self)
  #expect(encoded.range(of: #"\.\d{9}Z"#, options: .regularExpression) != nil)
  for name in ["identity.json", "current.json", "writer.lock"] {
    let attributes = try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent(name).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }
  #expect(
    (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber)?.intValue == 0o700)
}

@Test func snapshotCacheIdentitySurvivesRunsWithoutRefreshingOldPublication() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  var writer: SnapshotCacheWriter? = try SnapshotCacheWriter(directory: directory)
  let first = try #require(writer).publish(snapshot: cacheSnapshot(instant), at: instant)
  let second = try #require(writer).publish(
    snapshot: cacheSnapshot(instant.addingTimeInterval(5)), at: instant.addingTimeInterval(5))
  #expect(second.sequence == 2)
  let bytes = try Data(contentsOf: directory.appendingPathComponent("current.json"))
  writer = nil
  let next = try SnapshotCacheWriter(directory: directory)
  #expect(next.collectorId == first.collectorId)
  #expect(next.runId != first.runId)
  #expect(try Data(contentsOf: directory.appendingPathComponent("current.json")) == bytes)
  let stale = try SnapshotCacheReader.read(
    directory: directory, now: instant.addingTimeInterval(60))
  #expect(stale.availability == .stale)
  #expect(stale.ageSeconds == 55)
  #expect(stale.envelope.runId == first.runId)
  let restarted = try next.publish(
    snapshot: cacheSnapshot(instant.addingTimeInterval(60)), at: instant.addingTimeInterval(60))
  #expect(restarted.sequence == 1)
}

@Test func snapshotCacheRefusesDuplicateWriterAndReaderNeverAcquiresLease() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let writer = try SnapshotCacheWriter(directory: directory)
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  try writer.publish(snapshot: cacheSnapshot(instant), at: instant)
  #expect(throws: SnapshotCacheError.self) { try SnapshotCacheWriter(directory: directory) }
  _ = try SnapshotCacheReader.read(directory: directory, now: instant)
  // A reader does not interfere with the still-active writer.
  #expect(try writer.publish(snapshot: cacheSnapshot(instant), at: instant).sequence == 2)
}

@Test func snapshotCacheAbsentReadCreatesNothing() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  #expect(throws: SnapshotCacheError.self) { try SnapshotCacheReader.read(directory: directory) }
  #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func snapshotCacheRejectsUnsafeDirectoriesAndSymbolicLinks() throws {
  let directory = cacheTestDirectory()
  let link = directory.appendingPathExtension("link")
  defer {
    try? FileManager.default.removeItem(at: link)
    try? FileManager.default.removeItem(at: directory)
  }
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
  #expect(throws: SnapshotCacheError.self) { try SnapshotCacheWriter(directory: directory) }
  #expect(
    (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber)?.intValue == 0o755)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
  #expect(throws: SnapshotCacheError.self) { try SnapshotCacheWriter(directory: link) }
  #expect(throws: SnapshotCacheError.self) { try SnapshotCacheReader.read(directory: link) }
  #expect(throws: SnapshotCacheError.self) {
    try SnapshotCacheWriter(directory: link.appendingPathComponent("child"))
  }
}

@Test func snapshotCacheRejectsUnsafePublicationAndNeverFollowsFileLinks() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  var writer: SnapshotCacheWriter? = try SnapshotCacheWriter(directory: directory)
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  try #require(writer).publish(snapshot: cacheSnapshot(instant), at: instant)
  writer = nil
  let current = directory.appendingPathComponent("current.json")
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: current.path)
  #expect(throws: SnapshotCacheError.self) {
    try SnapshotCacheReader.read(directory: directory, now: instant)
  }
  #expect(throws: SnapshotCacheError.self) { try SnapshotCacheWriter(directory: directory) }
  try FileManager.default.removeItem(at: current)
  try FileManager.default.createSymbolicLink(
    at: current, withDestinationURL: directory.appendingPathComponent("identity.json"))
  #expect(throws: SnapshotCacheError.self) { try SnapshotCacheWriter(directory: directory) }
  #expect(throws: SnapshotCacheError.self) {
    try SnapshotCacheReader.read(directory: directory, now: instant)
  }
}

@Test func snapshotCacheDoesNotRegenerateMissingOrCorruptIdentity() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  var writer: SnapshotCacheWriter? = try SnapshotCacheWriter(directory: directory)
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  try #require(writer).publish(snapshot: cacheSnapshot(instant), at: instant)
  writer = nil
  let identity = directory.appendingPathComponent("identity.json")
  try Data("corrupt".utf8).write(to: identity)
  #expect(throws: SnapshotCacheError.self) { try SnapshotCacheWriter(directory: directory) }
  #expect(try String(contentsOf: identity, encoding: .utf8) == "corrupt")
  try FileManager.default.removeItem(at: identity)
  #expect(throws: SnapshotCacheError.self) { try SnapshotCacheWriter(directory: directory) }
  #expect(throws: SnapshotCacheError.self) {
    try SnapshotCacheReader.read(directory: directory, now: instant)
  }
  #expect(!FileManager.default.fileExists(atPath: identity.path))
}

@Test func snapshotCacheValidatesVersionsIdentitySizeAndObservationAge() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let writer = try SnapshotCacheWriter(directory: directory)
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  try writer.publish(snapshot: cacheSnapshot(instant), at: instant.addingTimeInterval(60))
  // Fresh publication must not make a sixty-second-old observation current.
  let stale = try SnapshotCacheReader.read(
    directory: directory, now: instant.addingTimeInterval(60))
  #expect(stale.availability == .stale)
  #expect(stale.envelope.snapshot.counts.active == 1)
  #expect(throws: SnapshotCacheError.self) {
    try SnapshotCacheReader.read(directory: directory, now: instant.addingTimeInterval(-31))
  }
  try changeCachedJSON(directory) { $0["schemaVersion"] = 2 }
  #expect(throws: SnapshotCacheError.self) {
    try SnapshotCacheReader.read(directory: directory, now: instant.addingTimeInterval(60))
  }
  try writer.publish(snapshot: cacheSnapshot(instant), at: instant)
  try changeCachedJSON(directory) { $0["collectorId"] = UUID().uuidString }
  #expect(throws: SnapshotCacheError.self) {
    try SnapshotCacheReader.read(directory: directory, now: instant)
  }
  try Data(repeating: 0x20, count: SnapshotCacheWriter.maximumPayloadBytes + 1).write(
    to: directory.appendingPathComponent("current.json"))
  #expect(throws: SnapshotCacheError.self) {
    try SnapshotCacheReader.read(directory: directory, now: instant)
  }
}

@Test func snapshotCacheAtomicPublicationSupportsConcurrentReaders() async throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let writer = try SnapshotCacheWriter(directory: directory)
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  try writer.publish(snapshot: cacheSnapshot(instant), at: instant)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      for index in 1...30 {
        let date = instant.addingTimeInterval(Double(index) / 100)
        try writer.publish(snapshot: cacheSnapshot(date), at: date)
      }
    }
    for _ in 0..<3 {
      group.addTask {
        for _ in 0..<30 {
          let read = try SnapshotCacheReader.read(
            directory: directory, now: instant.addingTimeInterval(1))
          #expect(read.envelope.sequence > 0)
          #expect(read.envelope.snapshot.counts.incomplete)
          #expect(read.envelope.snapshot.agents.count == 2)
        }
      }
    }
    try await group.waitForAll()
  }
  #expect(
    try SnapshotCacheReader.read(directory: directory, now: instant.addingTimeInterval(1)).envelope
      .sequence == 31)
}

@Test func snapshotCacheFailedPublicationConsumesSequenceWithoutReusingIt() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let writer = try SnapshotCacheWriter(directory: directory)
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  try writer.publish(snapshot: cacheSnapshot(instant), at: instant)
  let current = directory.appendingPathComponent("current.json")
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: current.path)
  #expect(throws: SnapshotCacheError.self) {
    try writer.publish(snapshot: cacheSnapshot(instant), at: instant)
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
  #expect(try writer.publish(snapshot: cacheSnapshot(instant), at: instant).sequence == 3)
}

@Test func snapshotCacheWriterRefusesReplacedLeaseAndIdentity() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let writer = try SnapshotCacheWriter(directory: directory)
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  try writer.publish(snapshot: cacheSnapshot(instant), at: instant)
  try changeCachedJSON(directory, name: "identity.json") { $0["collectorId"] = UUID().uuidString }
  #expect(throws: SnapshotCacheError.self) {
    try writer.publish(snapshot: cacheSnapshot(instant), at: instant)
  }
  try changeCachedJSON(directory, name: "identity.json") {
    $0["collectorId"] = writer.collectorId.uuidString
  }
  let lease = directory.appendingPathComponent("writer.lock")
  try FileManager.default.removeItem(at: lease)
  try Data().write(to: lease)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lease.path)
  #expect(throws: SnapshotCacheError.self) {
    try writer.publish(snapshot: cacheSnapshot(instant), at: instant)
  }
}

@Test func snapshotCacheReaderNeedsNoLeaseAndRejectsHardLinksAndPipes() throws {
  let directory = cacheTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  var writer: SnapshotCacheWriter? = try SnapshotCacheWriter(directory: directory)
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  try #require(writer).publish(snapshot: cacheSnapshot(instant), at: instant)
  writer = nil
  let lease = directory.appendingPathComponent("writer.lock")
  try FileManager.default.removeItem(at: lease)
  _ = try SnapshotCacheReader.read(directory: directory, now: instant)
  #expect(!FileManager.default.fileExists(atPath: lease.path))
  let current = directory.appendingPathComponent("current.json")
  let linked = directory.appendingPathComponent("hard-link.json")
  #expect(link(current.path, linked.path) == 0)
  #expect(throws: SnapshotCacheError.self) {
    try SnapshotCacheReader.read(directory: directory, now: instant)
  }
  try FileManager.default.removeItem(at: linked)
  try FileManager.default.removeItem(at: current)
  #expect(mkfifo(current.path, 0o600) == 0)
  #expect(throws: SnapshotCacheError.self) {
    try SnapshotCacheReader.read(directory: directory, now: instant)
  }
}
