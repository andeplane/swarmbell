import Foundation
import Testing

@testable import SwarmbellCompanion

/// Explicit opt-in: requires Bonjour/Local Network access. Uses a fresh secret and synthetic
/// aggregates only; it never reads real credentials, history, collectors or installed apps.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWARMBELL_COMPANION_LOOPBACK_TEST"] == "1"))
@MainActor func authenticatedAnalyticsRoundTripPreservesPushesAndSanitizesFailures() async throws {
  let credential = try SwarmbellPairingCredential.generate()
  let server = SwarmbellCompanionServer(credential: credential)
  let client = SwarmbellCompanionClient(credential: credential)
  defer {
    client.stop()
    server.stop()
  }
  let now = Date()
  let queries = (0..<3).map { offset in
    SwarmbellAnalyticsQuery(
      from: now.addingTimeInterval(-Double(offset + 1) * 86_400), to: now,
      timeZoneID: "Europe/Oslo", harness: "codex")
  }
  var received: [SwarmbellAnalyticsResponse] = []
  var pushed = 0
  var started = false
  var callbackFailed = false
  var invocations = 0
  var cancellations = 0
  let canceledQuery = SwarmbellAnalyticsQuery(
    from: now.addingTimeInterval(-3_600), to: now, timeZoneID: "UTC")
  server.onAnalyticsQuery = { query in
    invocations += 1
    if query.requestID == canceledQuery.requestID {
      do { try await Task.sleep(for: .seconds(20)) } catch {
        cancellations += 1
        throw error
      }
    }
    try await Task.sleep(for: .milliseconds(150))
    if query.requestID == queries.last?.requestID {
      throw NSError(domain: "/private/local-sensitive-path", code: 1)
    }
    return Data("{\"sampleCount\":3}".utf8)
  }
  client.onEnvelope = { envelope in
    pushed += 1
    if !started, client.supportsAnalyticsQueries {
      started = true
      do { try client.requestAnalytics(queries[0]) } catch { callbackFailed = true }
    }
  }
  client.onAnalyticsResponse = { response in
    received.append(response)
    if received.count < queries.count {
      do { try client.requestAnalytics(queries[received.count]) } catch { callbackFailed = true }
    }
  }
  try server.start()
  client.start()
  for _ in 0..<200 {
    try server.publish(envelope: .init(generatedAt: Date(), snapshot: Data("{}".utf8)))
    if received.count == queries.count || callbackFailed { break }
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(!callbackFailed)
  #expect(invocations == 3)
  #expect(pushed > 3)
  #expect(received.map(\.requestID) == queries.map(\.requestID))
  #expect(received.first?.reportData == Data("{\"sampleCount\":3}".utf8))
  #expect(received.last?.error == .unavailable)
  #expect(received.last?.reportData == nil)

  // Stop during a report: the client completes its pending UUID with a public error and
  // the server cancels that peer's report task instead of retaining work after disconnect.
  if received.count == queries.count {
    try client.requestAnalytics(canceledQuery)
    for _ in 0..<40 {
      if invocations == 4 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(invocations == 4)
    client.stop()
    #expect(!client.supportsAnalyticsQueries)
    #expect(received.last?.requestID == canceledQuery.requestID)
    #expect(received.last?.error == .unavailable)
    for _ in 0..<40 {
      if cancellations == 1 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(cancellations == 1)
  }

  let replacement = SwarmbellCompanionClient(credential: credential)
  defer { replacement.stop() }
  let freshQuery = SwarmbellAnalyticsQuery(
    from: now.addingTimeInterval(-7_200), to: now, timeZoneID: "UTC")
  var freshStarted = false
  var freshResponse: SwarmbellAnalyticsResponse?
  replacement.onEnvelope = { _ in
    guard !freshStarted, replacement.supportsAnalyticsQueries else { return }
    freshStarted = true
    do { try replacement.requestAnalytics(freshQuery) } catch { callbackFailed = true }
  }
  replacement.onAnalyticsResponse = { freshResponse = $0 }
  replacement.start()
  for _ in 0..<200 {
    try server.publish(envelope: .init(generatedAt: Date(), snapshot: Data("{}".utf8)))
    if freshResponse != nil || callbackFailed { break }
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(!callbackFailed)
  #expect(freshResponse?.requestID == freshQuery.requestID)
  #expect(freshResponse?.error == nil)
  #expect(freshResponse?.reportData != nil)
}
