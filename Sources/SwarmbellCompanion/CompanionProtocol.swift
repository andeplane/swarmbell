import Foundation
import Security

public enum SwarmbellCompanionError: Error, LocalizedError, Sendable {
  case invalidPairingCode, randomGenerationFailed, invalidFrame, unsupportedVersion
  public var errorDescription: String? {
    switch self {
    case .invalidPairingCode: "This is not a valid Swarmbell pairing code."
    case .randomGenerationFailed: "A secure pairing code could not be created."
    case .invalidFrame: "The companion sent an invalid or oversized message."
    case .unsupportedVersion: "This companion version is not supported."
    }
  }
}

/// Bearer credential: show only during deliberate pairing; never log or include in diagnostics.
public struct SwarmbellPairingCredential: Sendable {
  public let serverID: UUID
  public let secret: Data
  // Stable Bonjour instance prefix preserves discovery for already-paired companions.
  public var serviceName: String { "beacon-" + serverID.uuidString.lowercased() }

  public static func generate() throws -> Self {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw SwarmbellCompanionError.randomGenerationFailed
    }
    return Self(serverID: UUID(), secret: Data(bytes))
  }

  private init(serverID: UUID, secret: Data) {
    self.serverID = serverID
    self.secret = secret
  }

  public init(pairingURL: String) throws {
    guard pairingURL.utf8.count <= 512,
      let parts = URLComponents(string: pairingURL),
      ["swarmbell", "agentbeacon"].contains(parts.scheme ?? ""), parts.host == "pair",
      parts.path.isEmpty,
      parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
      let items = parts.queryItems, items.count == 3,
      Set(items.map(\.name)) == Set(["version", "id", "key"]),
      items.first(where: { $0.name == "version" })?.value == "1",
      let rawID = items.first(where: { $0.name == "id" })?.value,
      let id = UUID(uuidString: rawID),
      let rawKey = items.first(where: { $0.name == "key" })?.value,
      rawKey.count == 43,
      rawKey.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
      let secret = Data(
        base64Encoded: rawKey.replacingOccurrences(of: "-", with: "+")
          .replacingOccurrences(of: "_", with: "/") + "="), secret.count == 32
    else { throw SwarmbellCompanionError.invalidPairingCode }
    self.init(serverID: id, secret: secret)
    // Reject noncanonical encodings with unused nonzero padding bits.
    guard self.keyText == rawKey else { throw SwarmbellCompanionError.invalidPairingCode }
  }

  private var keyText: String {
    secret.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  // Emit the legacy URL scheme so pre-rebrand iPhone versions can still pair.
  // Parsing accepts both public brands; the version-1 wire and secret are unchanged.
  public var pairingURL: String {
    "agentbeacon://pair?version=1&id=\(serverID.uuidString.lowercased())&key=\(keyText)"
  }
}

public struct SwarmbellCompanionEnvelope: Codable, Sendable {
  public var version: Int = 1
  public var generatedAt: Date
  public var snapshot: Data
  public var reports: [String: Data]
  public init(generatedAt: Date, snapshot: Data, reports: [String: Data] = [:]) {
    self.generatedAt = generatedAt
    self.snapshot = snapshot
    self.reports = reports
  }
}

/// Four-byte big-endian length followed by a bounded JSON envelope.
public enum SwarmbellCompanionWire {
  public static let maximumPayloadBytes = 8 * 1_024 * 1_024
  public static func encode(_ envelope: SwarmbellCompanionEnvelope) throws -> Data {
    guard envelope.version == 1 else { throw SwarmbellCompanionError.unsupportedVersion }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = try encoder.encode(envelope)
    guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
      throw SwarmbellCompanionError.invalidFrame
    }
    let size = UInt32(payload.count)
    var frame = Data([
      UInt8(size >> 24), UInt8((size >> 16) & 255),
      UInt8((size >> 8) & 255), UInt8(size & 255),
    ])
    frame.append(payload)
    return frame
  }

  public static func decode(_ payload: Data) throws -> SwarmbellCompanionEnvelope {
    guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
      throw SwarmbellCompanionError.invalidFrame
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(SwarmbellCompanionEnvelope.self, from: payload)
    guard envelope.version == 1 else { throw SwarmbellCompanionError.unsupportedVersion }
    return envelope
  }

  public static func payloadLength(header: Data) throws -> Int {
    guard header.count == 4 else { throw SwarmbellCompanionError.invalidFrame }
    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length > 0, length <= UInt32(maximumPayloadBytes) else {
      throw SwarmbellCompanionError.invalidFrame
    }
    return Int(length)
  }
}
