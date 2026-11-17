import Foundation
import Testing

@testable import SwarmbellCompanion

@Test func pairingCredentialsRoundTripWithDistinctStrongSecrets() throws {
  let a = try SwarmbellPairingCredential.generate()
  let b = try SwarmbellPairingCredential.generate()
  #expect(a.secret.count == 32)
  #expect(a.secret != b.secret)
  #expect(a.serverID != b.serverID)
  #expect(a.serviceName.utf8.count < 64)
  let parsed = try SwarmbellPairingCredential(pairingURL: a.pairingURL)
  #expect(parsed.serverID == a.serverID)
  #expect(parsed.secret == a.secret)
  #expect(parsed.pairingURL == a.pairingURL)
}

@Test func rebrandPreservesPairingIdentityAndAcceptsBothSchemes() throws {
  let legacy = try SwarmbellPairingCredential.generate()
  #expect(legacy.pairingURL.hasPrefix("agentbeacon://pair?"))
  #expect(legacy.serviceName == "beacon-" + legacy.serverID.uuidString.lowercased())
  let brandedURL = legacy.pairingURL.replacingOccurrences(
    of: "agentbeacon://", with: "swarmbell://")
  let branded = try SwarmbellPairingCredential(pairingURL: brandedURL)
  #expect(branded.serverID == legacy.serverID)
  #expect(branded.secret == legacy.secret)
  #expect(branded.pairingURL == legacy.pairingURL)
  for invalid in [
    brandedURL.replacingOccurrences(of: "swarmbell://pair", with: "swarmbell://pair/path"),
    brandedURL.replacingOccurrences(of: "swarmbell://pair", with: "swarmbell://user@pair"),
    brandedURL.replacingOccurrences(of: "swarmbell://", with: "other://"),
  ] {
    #expect(throws: SwarmbellCompanionError.self) {
      try SwarmbellPairingCredential(pairingURL: invalid)
    }
  }
}

@Test func malformedAndAmbiguousPairingCredentialsAreRejected() throws {
  let valid = try SwarmbellPairingCredential.generate().pairingURL
  let bad = [
    "https://example.com", valid + "&version=1", valid + "&extra=1", valid + "#fragment",
    valid.replacingOccurrences(of: "version=1", with: "version=2"),
    valid.replacingOccurrences(of: "agentbeacon://pair", with: "agentbeacon://pair/path"),
    valid.replacingOccurrences(of: "agentbeacon://pair", with: "agentbeacon://user@pair"),
    "agentbeacon://pair?version=1&id=not-a-uuid&key=" + String(repeating: "A", count: 43),
    String(repeating: "A", count: 513),
  ]
  for candidate in bad {
    #expect(throws: SwarmbellCompanionError.self) {
      try SwarmbellPairingCredential(pairingURL: candidate)
    }
  }
}

@Test func framePreservesSnapshotAndReportsWithoutInterpretingCommands() throws {
  let snapshot = Data(#"{"schemaVersion":1,"agents":[]}"#.utf8)
  let report = Data(#"{"sampleCount":3}"#.utf8)
  let envelope = SwarmbellCompanionEnvelope(
    generatedAt: Date(timeIntervalSince1970: 100), snapshot: snapshot, reports: ["week": report])
  let frame = try SwarmbellCompanionWire.encode(envelope)
  let length = try SwarmbellCompanionWire.payloadLength(header: frame.prefix(4))
  #expect(length == frame.count - 4)
  let decoded = try SwarmbellCompanionWire.decode(Data(frame.dropFirst(4)))
  #expect(decoded.version == 1)
  #expect(decoded.snapshot == snapshot)
  #expect(decoded.reports == ["week": report])
  #expect(decoded.generatedAt == envelope.generatedAt)
}

@Test func framingRejectsZeroHugeTruncatedAndUnknownVersionMessages() throws {
  for header in [Data(), Data([0, 0, 0]), Data([0, 0, 0, 0]), Data([255, 255, 255, 255])] {
    #expect(throws: SwarmbellCompanionError.self) {
      try SwarmbellCompanionWire.payloadLength(header: header)
    }
  }
  #expect(throws: (any Error).self) { try SwarmbellCompanionWire.decode(Data("{".utf8)) }
  var unknown = SwarmbellCompanionEnvelope(generatedAt: Date(), snapshot: Data())
  unknown.version = 2
  #expect(throws: SwarmbellCompanionError.self) { try SwarmbellCompanionWire.encode(unknown) }
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let payload = try encoder.encode(unknown)
  #expect(throws: SwarmbellCompanionError.self) { try SwarmbellCompanionWire.decode(payload) }
  let huge = SwarmbellCompanionEnvelope(
    generatedAt: Date(),
    snapshot: Data(repeating: 0, count: SwarmbellCompanionWire.maximumPayloadBytes))
  #expect(throws: SwarmbellCompanionError.self) { try SwarmbellCompanionWire.encode(huge) }
}
