import Foundation
import Testing

@testable import AgentBeaconCore

private struct MeasuredProvider: AgentProvider {
  let harness: Harness
  let healthy: Bool
  func poll(at date: Date) async -> ProviderSnapshot {
    try? await Task.sleep(for: .milliseconds(15))
    if !healthy { return .unavailable(harness, at: date, message: "fixture outage") }
    return .init(
      status: .init(
        harness: harness, health: .healthy, message: "fixture",
        checkedAt: date, observesAttention: true),
      agents: [
        .init(
          harness: harness, sessionID: "measured", title: "fixture", state: .working, lastSeen: date
        )
      ])
  }
}

@Test func eachActualRefreshMeasuresEverySourceAndPersistsFailuresAsData() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let history = try HistoryStore(url: directory.appendingPathComponent("measurements.sqlite"))
  let monitor = AgentMonitor(
    providers: [
      MeasuredProvider(harness: .claudeCode, healthy: true),
      MeasuredProvider(harness: .codex, healthy: false),
    ], history: history)
  let instant = Date(timeIntervalSince1970: 1_800_000_000)
  let first = await monitor.refresh(at: instant)
  let second = await monitor.refresh(at: instant.addingTimeInterval(5))
  let timing = try #require(second.refreshTiming)
  #expect(timing.startedAt == instant.addingTimeInterval(5))
  #expect(timing.providers.count == 2)
  #expect(timing.durationMilliseconds >= 10)
  #expect(timing.providers.allSatisfy { $0.durationMilliseconds >= 10 })
  #expect(first.historyError == nil)
  #expect(second.historyError == nil)
  #expect(second.counts.incomplete)
  let report = try await history.report(
    from: instant.addingTimeInterval(-1),
    to: instant.addingTimeInterval(6), timeZone: TimeZone(identifier: "Europe/Oslo")!)
  #expect(report.sampleCount == 2)
  #expect(report.refreshLatency.sampleCount == 2)
  #expect(report.providerLatencies.first { $0.harness == .codex }?.latency.sampleCount == 2)
}
