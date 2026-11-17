import Foundation
import Testing

@testable import SwarmbellCompanion

private let queryNow = Date(timeIntervalSince1970: 1_800_000_000)
private func validQuery() -> SwarmbellAnalyticsQuery {
  .init(from: queryNow.addingTimeInterval(-86_400), to: queryNow, timeZoneID: "Europe/Oslo")
}

@Test func analyticsQueryPreservesRangeZoneHarnessAndCorrelation() throws {
  for harness: String? in [nil, "codex", "claudeCode", "cursor"] {
    var query = validQuery()
    query.harness = harness
    let frame = try SwarmbellAnalyticsWire.encode(query, now: queryNow)
    #expect(try SwarmbellAnalyticsWire.payloadLength(header: frame.prefix(4)) == frame.count - 4)
    #expect(try SwarmbellAnalyticsWire.decode(Data(frame.dropFirst(4)), now: queryNow) == query)
  }
}

@Test func analyticsRejectsNonfiniteReversedExcessiveFutureAndInvalidFilters() throws {
  var invalid: [SwarmbellAnalyticsQuery] = []
  for from in [
    queryNow, queryNow.addingTimeInterval(1), Date(timeIntervalSince1970: .nan),
    Date(timeIntervalSince1970: -.infinity), queryNow.addingTimeInterval(-367 * 86_400),
  ] {
    var query = validQuery()
    query.from = from
    invalid.append(query)
  }
  for to in [Date(timeIntervalSince1970: .infinity), queryNow.addingTimeInterval(31)] {
    var query = validQuery()
    query.to = to
    invalid.append(query)
  }
  for zone in ["", "not/a/timezone", String(repeating: "A", count: 129)] {
    var query = validQuery()
    query.timeZoneID = zone
    invalid.append(query)
  }
  for harness in ["Codex", "", "shell", String(repeating: "a", count: 17_000)] {
    var query = validQuery()
    query.harness = harness
    invalid.append(query)
  }
  for query in invalid {
    #expect(throws: SwarmbellCompanionError.self) { try query.validate(now: queryNow) }
  }
  var maximum = validQuery()
  maximum.from = queryNow.addingTimeInterval(-366 * 86_400)
  try maximum.validate(now: queryNow)
}

@Test func onlyVersionOneReadOnlyQueriesAreAccepted() throws {
  let frame = try SwarmbellAnalyticsWire.encode(validQuery(), now: queryNow)
  let payload = Data(frame.dropFirst(4))
  let json = try #require(String(data: payload, encoding: .utf8))
  let invalid = [
    "{}", "{", json.replacingOccurrences(of: "analyticsQuery", with: "launchAgent"),
    json.replacingOccurrences(of: #""version":1"#, with: #""version":2"#),
    json.replacingOccurrences(of: #""requestID":""#, with: #""requestID":"bad-"#),
    json.replacingOccurrences(
      of: #""kind":"analyticsQuery""#,
      with: #""kind":"analyticsQuery","command":"rm""#),
    json.replacingOccurrences(
      of: #""timeZoneID":"Europe\/Oslo""#,
      with: #""timeZoneID":"Europe\/Oslo","action":"resume""#),
  ]
  for candidate in invalid {
    #expect(candidate != json)
    #expect(throws: (any Error).self) {
      try SwarmbellAnalyticsWire.decode(Data(candidate.utf8), now: queryNow)
    }
  }
}

@Test func clientFramesAreBoundedBeforePayloadRead() throws {
  for header in [Data([0, 0, 0, 0]), Data([0, 0, 64, 1]), Data([0, 128, 0, 0]), Data([1])] {
    #expect(throws: SwarmbellCompanionError.self) {
      try SwarmbellAnalyticsWire.payloadLength(header: header)
    }
  }
  #expect(try SwarmbellAnalyticsWire.payloadLength(header: Data([0, 0, 64, 0])) == 16_384)
  #expect(throws: SwarmbellCompanionError.self) {
    try SwarmbellAnalyticsWire.decode(Data(repeating: 32, count: 16_385))
  }
}

@Test func legacyEnvelopesDecodeWithNoCapabilitiesAndOldClientsIgnoreNewFields() throws {
  let oldJSON = Data(
    #"{"version":1,"generatedAt":"2026-01-01T00:00:00Z","snapshot":"e30=","reports":{}}"#.utf8)
  let old = try SwarmbellCompanionWire.decode(oldJSON)
  #expect(old.capabilities == nil)
  #expect(old.analyticsResponse == nil)
  struct LegacyEnvelope: Decodable {
    let version: Int
    let generatedAt: Date
    let snapshot: Data
    let reports: [String: Data]
  }
  let current = SwarmbellCompanionEnvelope(
    generatedAt: queryNow, snapshot: Data("{}".utf8), reports: ["week": Data("{}".utf8)],
    capabilities: [SwarmbellAnalyticsWire.capability])
  let frame = try SwarmbellCompanionWire.encode(current)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let legacy = try decoder.decode(LegacyEnvelope.self, from: Data(frame.dropFirst(4)))
  #expect(legacy.version == 1)
  #expect(legacy.reports["week"] == Data("{}".utf8))
}

@Test func pendingQueriesRequireNegotiationAndMatchExactlyOnce() throws {
  var pending = SwarmbellAnalyticsPendingRequest()
  let requestID = UUID()
  #expect(throws: SwarmbellCompanionError.self) { try pending.begin(requestID, supported: false) }
  #expect(pending.requestID == nil)
  try pending.begin(requestID, supported: true)
  #expect(throws: SwarmbellCompanionError.self) { try pending.begin(UUID(), supported: true) }
  #expect(throws: SwarmbellCompanionError.self) {
    try pending.consume(.init(requestID: UUID(), error: .busy))
  }
  #expect(pending.requestID == requestID)
  try pending.consume(.init(requestID: requestID, reportData: Data("{}".utf8)))
  #expect(pending.requestID == nil)
  #expect(throws: SwarmbellCompanionError.self) {
    try pending.consume(.init(requestID: requestID, error: .unavailable))
  }
  try pending.begin(UUID(), supported: true)
  pending.reset()
  #expect(pending.requestID == nil)
}

@Test @MainActor func unnegotiatedClientNeverSendsQueries() throws {
  let client = SwarmbellCompanionClient(credential: try .generate())
  #expect(!client.supportsAnalyticsQueries)
  #expect(throws: SwarmbellCompanionError.self) { try client.requestAnalytics(validQuery()) }
  client.stop()
}

@Test func analyticsResponsesAreBoundedAndErrorsAreAllowlisted() throws {
  let requestID = UUID()
  let frame = try SwarmbellAnalyticsWire.responseFrame(
    .init(requestID: requestID, reportData: Data(repeating: 0, count: 8 * 1_024 * 1_024)))
  #expect(frame.count < 1_024)
  let envelope = try SwarmbellCompanionWire.decode(Data(frame.dropFirst(4)))
  #expect(envelope.analyticsResponse?.requestID == requestID)
  #expect(envelope.analyticsResponse?.error == .reportTooLarge)
  #expect(envelope.analyticsResponse?.reportData == nil)
  #expect(envelope.snapshot.isEmpty)
  var invalid = SwarmbellAnalyticsResponse(requestID: requestID, error: .unavailable)
  invalid.reportData = Data("{}".utf8)
  #expect(throws: SwarmbellCompanionError.self) { try invalid.validate() }
  #expect(throws: SwarmbellCompanionError.self) {
    try SwarmbellAnalyticsResponse(requestID: requestID, reportData: Data()).validate()
  }
  let json = Data("{\"requestID\":\"\(requestID)\",\"error\":\"/private/database-secret\"}".utf8)
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(SwarmbellAnalyticsResponse.self, from: json)
  }
}
