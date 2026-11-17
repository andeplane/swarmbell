import Foundation
import Testing

@testable import SwarmbellCore

private func historyDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func historyURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "swarmbell-history-" + UUID().uuidString
  )
  .appendingPathComponent("history.sqlite")
}
private func historySnapshot(_ date: Date, state: AgentState = .working, available: Bool = true)
  -> MonitorSnapshot
{
  let row = AgentRecord(
    harness: .claudeCode, sessionID: "fixture", title: "PRIVATE_TITLE_NOT_HISTORY",
    state: state, reason: state == .needsYou ? "Approval" : nil, lastSeen: date,
    freshness: available ? .current : .stale)
  return .init(
    generatedAt: date,
    counts: .init(
      active: available && state.isActive ? 1 : 0,
      needsYou: available && state == .needsYou ? 1 : 0,
      working: available && state == .working ? 1 : 0,
      uncertain: available ? 0 : 1, incomplete: true),
    providers: [
      .init(
        harness: .claudeCode,
        health: available ? .healthy : .unavailable, message: "fixture", checkedAt: date,
        observesAttention: available)
    ], agents: [row])
}
private func recordHistory(
  _ store: HistoryStore, _ date: Date, state: AgentState = .working,
  available: Bool = true, latency: Double = 25
) async throws {
  try await store.record(
    historySnapshot(date, state: state, available: available),
    timing: .init(
      startedAt: date,
      durationMilliseconds: latency,
      providers: [.init(harness: .claudeCode, durationMilliseconds: latency / 2)]))
}

@Test func historyPersistsEveryUniqueRefreshAndTracksWaitingTime() async throws {
  let url = historyURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = try HistoryStore(url: url)
  let base = historyDate("2026-11-15T12:00:00Z")
  try await recordHistory(store, base, latency: 10)
  try await recordHistory(store, base.addingTimeInterval(5), state: .needsYou, latency: 20)
  try await recordHistory(store, base.addingTimeInterval(10), state: .needsYou, latency: 30)
  try await recordHistory(store, base.addingTimeInterval(15), latency: 40)
  try await recordHistory(store, base.addingTimeInterval(15), latency: 99)
  let reopened = try HistoryStore(url: url)
  let report = try await reopened.report(from: base, to: base.addingTimeInterval(60))
  #expect(report.sampleCount == 4)
  #expect(report.summary.observedSeconds == 15)
  #expect(report.summary.workingAgentSeconds == 5)
  #expect(report.summary.waitingAgentSeconds == 10)
  #expect(report.summary.meanObservedWaitSeconds == 10)
  #expect(report.summary.attentionEpisodes == 1)
  #expect(report.refreshLatency.meanMilliseconds == 25)
  #expect(report.refreshLatency.p95Milliseconds == 40)
  #expect(report.summary.sourceAvailabilityFraction == 15.0 / (60 * 3))
  #expect(report.summary.completeCoverageFraction == 0)
  #expect(report.attentionReasons.first?.waitingAgentSeconds == 10)
  let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
  #expect(!text.contains("PRIVATE_TITLE_NOT_HISTORY"))
}

@Test func historyNeverCreditsSleepGapsOrUnavailableSourcesAsActivity() async throws {
  let url = historyURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = try HistoryStore(url: url)
  let base = historyDate("2026-11-15T12:00:00Z")
  try await recordHistory(store, base)
  try await recordHistory(store, base.addingTimeInterval(120))
  try await recordHistory(store, base.addingTimeInterval(125), available: false)
  try await recordHistory(store, base.addingTimeInterval(130))
  let report = try await store.report(from: base, to: base.addingTimeInterval(180))
  #expect(report.sampleCount == 4)
  #expect(report.summary.observedSeconds == 0)
  #expect(report.summary.workingAgentSeconds == 0)
  #expect(report.timeSeries.allSatisfy { $0.active == nil })
  #expect(report.summary.meanObservedWaitSeconds == nil)
  #expect(report.summary.completedEpisodes == 0)
}

@Test func historySplitsHourlyDurationsAndAggregatesRepeatedDSTHour() async throws {
  let url = historyURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = try HistoryStore(url: url)
  let base = historyDate("2026-10-25T00:59:55Z")
  try await recordHistory(store, base)
  try await recordHistory(store, base.addingTimeInterval(5))
  try await recordHistory(store, base.addingTimeInterval(10))
  let utc = try await store.report(
    from: base.addingTimeInterval(-55), to: base.addingTimeInterval(65),
    timeZone: TimeZone(secondsFromGMT: 0)!)
  #expect(utc.hourly[0].workingAgentSeconds == 5)
  #expect(utc.hourly[1].workingAgentSeconds == 5)
  let oslo = try await store.report(
    from: base.addingTimeInterval(-55), to: base.addingTimeInterval(65),
    timeZone: TimeZone(identifier: "Europe/Oslo")!)
  #expect(oslo.hourly[2].workingAgentSeconds == 10)
  #expect(oslo.weekdays[6].workingAgentSeconds == 10)
  #expect(oslo.weekdayHours.first { $0.weekday == 7 && $0.hour == 2 }?.workingAgentSeconds == 10)
}

@Test func historyConcurrentStoreInstancesDoNotDoubleCountIntervals() async throws {
  let url = historyURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let first = try HistoryStore(url: url)
  let second = try HistoryStore(url: url)
  let base = historyDate("2026-11-15T12:00:00Z")
  try await recordHistory(first, base)
  try await recordHistory(second, base.addingTimeInterval(5))
  try await recordHistory(first, base.addingTimeInterval(10))
  let report = try await first.report(
    from: base, to: base.addingTimeInterval(60), harness: .claudeCode)
  #expect(report.summary.workingAgentSeconds == 10)
  #expect(report.summary.observedSeconds == 10)
  #expect(report.harnesses.count == 1)
}

@Test func historyChartResolutionIsBoundedAndCoverageHasNoFabricatedPoints() async throws {
  let url = historyURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = try HistoryStore(url: url)
  let base = historyDate("2026-11-15T12:00:00Z")
  let report = try await store.report(from: base.addingTimeInterval(-30 * 86400), to: base)
  #expect(report.timeSeries.count <= 721)
  #expect(report.sampleCount == 0)
  #expect(report.timeSeries.allSatisfy { $0.active == nil })
  #expect(
    report.hourly.count == 24 && report.weekdays.count == 7 && report.weekdayHours.count == 168)
}

@Test func historyFirstObservedWaitingEpisodeIsCensored() async throws {
  let url = historyURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = try HistoryStore(url: url)
  let base = historyDate("2026-11-15T12:00:00Z")
  try await recordHistory(store, base, state: .needsYou)
  try await recordHistory(store, base.addingTimeInterval(5), state: .needsYou)
  try await recordHistory(store, base.addingTimeInterval(10))
  let report = try await store.report(from: base, to: base.addingTimeInterval(60))
  #expect(report.summary.attentionEpisodes == 1)
  #expect(report.summary.waitingAgentSeconds == 10)
  #expect(report.summary.meanObservedWaitSeconds == nil)
  #expect(report.summary.completedEpisodes == 1)
}

@Test func historyRangeEdgesCreditActualObservedTimeWithinMinute() async throws {
  let url = historyURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = try HistoryStore(url: url)
  let base = historyDate("2026-11-15T12:00:20Z")
  try await recordHistory(store, base, state: .needsYou)
  try await recordHistory(store, base.addingTimeInterval(5), state: .needsYou)
  try await recordHistory(store, base.addingTimeInterval(10), state: .needsYou)
  let report = try await store.report(
    from: base, to: base.addingTimeInterval(10), harness: .claudeCode)
  #expect(report.summary.observedSeconds == 10)
  #expect(report.summary.waitingAgentSeconds == 10)
  #expect(report.harnesses.first?.availableSeconds == 10)
  #expect(report.attentionReasons.first?.waitingAgentSeconds == 10)
  #expect(report.summary.sourceAvailabilityFraction == 1)
}

@Test func historyStableWaitIsOneEpisodeDespiteUnrelatedUnknownSession() async throws {
  let url = historyURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = try HistoryStore(url: url)
  let base = historyDate("2026-11-15T12:00:00Z")
  for index in 0..<10 {
    let date = base.addingTimeInterval(Double(index) * 5)
    var snapshot = historySnapshot(date, state: .needsYou)
    snapshot.agents.append(
      .init(
        harness: .claudeCode, sessionID: "unrelated", title: "Missing task",
        state: .working, lastSeen: base, freshness: .missing))
    snapshot.counts.uncertain = 1
    try await store.record(snapshot, timing: .init(startedAt: date, durationMilliseconds: 10))
  }
  let report = try await store.report(from: base, to: base.addingTimeInterval(60))
  #expect(report.sampleCount == 10)
  #expect(report.summary.attentionEpisodes == 1)
  #expect(report.summary.waitingAgentSeconds == 45)
  #expect(report.summary.observedSeconds == 45)
  #expect(report.summary.completeCoverageFraction == 0)
  #expect(report.harnesses.first { $0.harness == .claudeCode }?.healthySeconds == 0)
  #expect(report.summary.meanObservedWaitSeconds == nil)
}

@Test func historyKeepsLegacyRowsButExcludesInvalidPrototypeDerivedEstimates() async throws {
  let url = historyURL()
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let database = try HistoryDatabase(url: url)
  let base = historyDate("2026-11-15T12:00:00Z")
  try database.execute(
    "CREATE TABLE attention_episodes(id TEXT PRIMARY KEY,observed_wait_seconds REAL)")
  try database.execute("INSERT INTO attention_episodes VALUES('legacy-invalid',99999)")
  try database.execute("CREATE TABLE monitor_minutes(minute REAL PRIMARY KEY,waiting_seconds REAL)")
  try database.execute(
    "INSERT INTO monitor_minutes VALUES(?,99999)", [.number(base.timeIntervalSince1970 - 60)])
  try database.execute(
    "INSERT INTO refresh_samples VALUES('legacy',?,?,100,1,0,1,0,1)",
    [
      .number(base.timeIntervalSince1970 - 60), .number(base.timeIntervalSince1970 - 60),
    ])
  let store = try HistoryStore(url: url)
  for index in 0..<10 {
    try await recordHistory(store, base.addingTimeInterval(Double(index) * 5), state: .needsYou)
  }
  let report = try await store.report(
    from: base.addingTimeInterval(-60), to: base.addingTimeInterval(60))
  #expect(report.sampleCount == 11)
  #expect(report.refreshLatency.sampleCount == 11)
  #expect(report.summary.attentionEpisodes == 1)
  #expect(report.summary.waitingAgentSeconds == 45)
  #expect(report.insights.contains { $0.contains("Earlier prototype") })
  var legacyCount = 0
  try database.rows("SELECT id FROM attention_episodes") { _ in legacyCount += 1 }
  #expect(legacyCount == 1)
}
