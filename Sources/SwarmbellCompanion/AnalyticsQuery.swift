import Foundation

/// Read-only aggregate query. This protocol has no agent actions or arbitrary commands.
public struct SwarmbellAnalyticsQuery: Codable, Sendable, Equatable {
  public var requestID: UUID
  public var from: Date
  public var to: Date
  public var timeZoneID: String
  public var harness: String?

  public init(
    requestID: UUID = UUID(), from: Date, to: Date, timeZoneID: String, harness: String? = nil
  ) {
    self.requestID = requestID
    self.from = from
    self.to = to
    self.timeZoneID = timeZoneID
    self.harness = harness
  }

  public func validate(now: Date = Date()) throws {
    let start = from.timeIntervalSince1970
    let end = to.timeIntervalSince1970
    guard start.isFinite, end.isFinite, start >= -62_135_596_800,
      end > start, end - start <= 366 * 86_400,
      end <= now.timeIntervalSince1970 + 30,
      !timeZoneID.isEmpty, timeZoneID.utf8.count <= 128,
      TimeZone(identifier: timeZoneID) != nil,
      harness == nil || ["codex", "claudeCode", "cursor"].contains(harness!)
    else { throw SwarmbellCompanionError.invalidAnalyticsQuery }
  }
}

/// Only fixed public messages cross the wire; underlying database errors never do.
public enum SwarmbellAnalyticsResponseError: String, Codable, Sendable, LocalizedError {
  case unavailable, busy, reportTooLarge

  public var errorDescription: String? {
    switch self {
    case .unavailable: "Statistics are unavailable. Keep sharing enabled on your Mac and try again."
    case .busy: "Your Mac is preparing statistics. Try again shortly."
    case .reportTooLarge: "This report is too large to share. Choose a shorter range."
    }
  }
}

public struct SwarmbellAnalyticsResponse: Codable, Sendable, Equatable {
  public var requestID: UUID
  public var reportData: Data?
  public var error: SwarmbellAnalyticsResponseError?

  public init(requestID: UUID, reportData: Data) {
    self.requestID = requestID
    self.reportData = reportData
  }

  public init(requestID: UUID, error: SwarmbellAnalyticsResponseError) {
    self.requestID = requestID
    self.error = error
  }

  func validate() throws {
    guard (reportData != nil) != (error != nil), reportData?.isEmpty != true else {
      throw SwarmbellCompanionError.invalidFrame
    }
  }
}

/// Deliberately separate from server-push envelopes. No generic command dispatch exists.
public enum SwarmbellAnalyticsWire {
  public static let capability = "analyticsQueriesV1"
  public static let maximumRequestBytes = 16 * 1_024

  private struct Request: Codable {
    var version = 1
    var kind = "analyticsQuery"
    var query: SwarmbellAnalyticsQuery
  }

  public static func encode(_ query: SwarmbellAnalyticsQuery, now: Date = Date()) throws -> Data {
    try query.validate(now: now)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = try encoder.encode(Request(query: query))
    guard payload.count <= maximumRequestBytes else { throw SwarmbellCompanionError.invalidFrame }
    let length = UInt32(payload.count)
    var frame = Data([
      UInt8(length >> 24), UInt8((length >> 16) & 255),
      UInt8((length >> 8) & 255), UInt8(length & 255),
    ])
    frame.append(payload)
    return frame
  }

  public static func payloadLength(header: Data) throws -> Int {
    let length = try SwarmbellCompanionWire.payloadLength(header: header)
    guard length <= maximumRequestBytes else { throw SwarmbellCompanionError.invalidFrame }
    return length
  }

  public static func decode(_ payload: Data, now: Date = Date()) throws -> SwarmbellAnalyticsQuery {
    guard !payload.isEmpty, payload.count <= maximumRequestBytes,
      let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
      Set(root.keys) == Set(["version", "kind", "query"]),
      let queryObject = root["query"] as? [String: Any],
      Set(queryObject.keys).isSubset(of: ["requestID", "from", "to", "timeZoneID", "harness"])
    else { throw SwarmbellCompanionError.invalidFrame }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let request = try decoder.decode(Request.self, from: payload)
    guard request.version == 1 else { throw SwarmbellCompanionError.unsupportedVersion }
    guard request.kind == "analyticsQuery" else { throw SwarmbellCompanionError.invalidFrame }
    try request.query.validate(now: now)
    return request.query
  }

  /// Encodes size failures as a small sanitized error rather than dropping the connection.
  static func responseFrame(_ response: SwarmbellAnalyticsResponse) throws -> Data {
    do {
      guard (response.reportData?.count ?? 0) <= SwarmbellCompanionWire.maximumPayloadBytes else {
        throw SwarmbellCompanionError.invalidFrame
      }
      return try SwarmbellCompanionWire.encode(
        .init(generatedAt: Date(), snapshot: Data(), analyticsResponse: response))
    } catch {
      return try SwarmbellCompanionWire.encode(
        .init(
          generatedAt: Date(), snapshot: Data(),
          analyticsResponse: .init(requestID: response.requestID, error: .reportTooLarge)))
    }
  }
}

/// Request correlation is independent of snapshots; late or unsolicited replies are rejected.
struct SwarmbellAnalyticsPendingRequest {
  private(set) var requestID: UUID?
  mutating func begin(_ id: UUID, supported: Bool) throws {
    guard supported else { throw SwarmbellCompanionError.analyticsUnavailable }
    guard requestID == nil else { throw SwarmbellCompanionError.analyticsBusy }
    requestID = id
  }
  mutating func consume(_ response: SwarmbellAnalyticsResponse) throws {
    try response.validate()
    guard requestID == response.requestID else { throw SwarmbellCompanionError.invalidFrame }
    requestID = nil
  }
  mutating func reset() { requestID = nil }
}
