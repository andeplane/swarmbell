import Foundation

/// The complete widget and Watch payload. Never add conversation or pairing data here.
struct GlanceSnapshot: Codable, Equatable, Sendable {
  enum Connection: String, Codable, Sendable {
    case unavailable, disconnected, connected
  }

  static let currentVersion = 1
  static let maximumCount = 1_000_000
  static let freshnessInterval: TimeInterval = 20
  static let maximumFutureSkew: TimeInterval = 30
  static let maximumEncodedBytes = 4_096

  let version: Int
  let observedAt: Date
  let receivedAt: Date
  let active: Int
  let working: Int
  let needsYou: Int
  let incomplete: Bool
  let connection: Connection

  init(
    observedAt: Date, receivedAt: Date, active: Int, working: Int,
    needsYou: Int, incomplete: Bool, connection: Connection
  ) {
    version = Self.currentVersion
    self.observedAt = observedAt
    self.receivedAt = receivedAt
    self.active = active
    self.working = working
    self.needsYou = needsYou
    self.incomplete = incomplete
    self.connection = connection
  }

  enum ValidationError: Error {
    case unsupportedVersion, invalidDate, invalidCounts, oversizedPayload
  }

  private enum CodingKeys: String, CodingKey {
    case version, observedAt, receivedAt, active, working, needsYou, incomplete, connection
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    observedAt = try container.decode(Date.self, forKey: .observedAt)
    receivedAt = try container.decode(Date.self, forKey: .receivedAt)
    active = try container.decode(Int.self, forKey: .active)
    working = try container.decode(Int.self, forKey: .working)
    needsYou = try container.decode(Int.self, forKey: .needsYou)
    incomplete = try container.decode(Bool.self, forKey: .incomplete)
    connection = try container.decode(Connection.self, forKey: .connection)
    try validate()
  }

  func validate(at now: Date = Date()) throws {
    guard version == Self.currentVersion else { throw ValidationError.unsupportedVersion }
    for date in [observedAt, receivedAt] {
      let timestamp = date.timeIntervalSince1970
      guard timestamp.isFinite, timestamp >= 0,
        date.timeIntervalSince(now) <= Self.maximumFutureSkew
      else { throw ValidationError.invalidDate }
    }
    guard (0...Self.maximumCount).contains(active),
      (0...Self.maximumCount).contains(working),
      (0...Self.maximumCount).contains(needsYou),
      working <= active, needsYou == active - working
    else { throw ValidationError.invalidCounts }
  }

  func isCurrent(at now: Date = Date()) -> Bool {
    guard (try? validate(at: now)) != nil, connection == .connected else { return false }
    return now.timeIntervalSince(observedAt) <= Self.freshnessInterval
      && now.timeIntervalSince(receivedAt) <= Self.freshnessInterval
  }

  func encodedData() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  static func decode(_ data: Data, at now: Date = Date()) throws -> GlanceSnapshot {
    guard data.count <= maximumEncodedBytes else { throw ValidationError.oversizedPayload }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(Self.self, from: data)
    try snapshot.validate(at: now)
    return snapshot
  }
}

enum GlanceConstants {
  static let appGroup = "group.dev.andeplane.swarmbell"
  static let contextKey = "swarmbell.glance.v1"
  static let widgetKind = "dev.andeplane.swarmbell.counts"
  static let appURL = URL(string: "swarmbell://agents")!
}
