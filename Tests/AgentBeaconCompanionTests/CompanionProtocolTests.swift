import Foundation
import Testing

@testable import AgentBeaconCompanion

@Test func pairingCredentialsRoundTripWithDistinctStrongSecrets() throws {
  let a = try BeaconPairingCredential.generate()
  let b = try BeaconPairingCredential.generate()
  #expect(a.secret.count == 32)
  #expect(a.secret != b.secret)
  #expect(a.serverID != b.serverID)
  #expect(a.serviceName.utf8.count < 64)
  let parsed = try BeaconPairingCredential(pairingURL: a.pairingURL)
  #expect(parsed.serverID == a.serverID)
  #expect(parsed.secret == a.secret)
  #expect(parsed.pairingURL == a.pairingURL)
}

@Test func malformedAndAmbiguousPairingCredentialsAreRejected() throws {
  let valid = try BeaconPairingCredential.generate().pairingURL
  let bad = [
    "https://example.com", valid + "&version=1", valid + "&extra=1", valid + "#fragment",
    valid.replacingOccurrences(of: "version=1", with: "version=2"),
    valid.replacingOccurrences(of: "agentbeacon://pair", with: "agentbeacon://pair/path"),
    valid.replacingOccurrences(of: "agentbeacon://pair", with: "agentbeacon://user@pair"),
    "agentbeacon://pair?version=1&id=not-a-uuid&key=" + String(repeating: "A", count: 43),
    String(repeating: "A", count: 513),
  ]
  for candidate in bad {
    #expect(throws: BeaconCompanionError.self) {
      try BeaconPairingCredential(pairingURL: candidate)
    }
  }
}

@Test func framePreservesSnapshotAndReportsWithoutInterpretingCommands() throws {
  let snapshot = Data(#"{"schemaVersion":1,"agents":[]}"#.utf8)
  let report = Data(#"{"sampleCount":3}"#.utf8)
  let envelope = BeaconCompanionEnvelope(
    generatedAt: Date(timeIntervalSince1970: 100), snapshot: snapshot, reports: ["week": report])
  let frame = try BeaconCompanionWire.encode(envelope)
  let length = try BeaconCompanionWire.payloadLength(header: frame.prefix(4))
  #expect(length == frame.count - 4)
  let decoded = try BeaconCompanionWire.decode(Data(frame.dropFirst(4)))
  #expect(decoded.version == 1)
  #expect(decoded.snapshot == snapshot)
  #expect(decoded.reports == ["week": report])
  #expect(decoded.generatedAt == envelope.generatedAt)
}

@Test func framingRejectsZeroHugeTruncatedAndUnknownVersionMessages() throws {
  for header in [Data(), Data([0, 0, 0]), Data([0, 0, 0, 0]), Data([255, 255, 255, 255])] {
    #expect(throws: BeaconCompanionError.self) {
      try BeaconCompanionWire.payloadLength(header: header)
    }
  }
  #expect(throws: (any Error).self) { try BeaconCompanionWire.decode(Data("{".utf8)) }
  var unknown = BeaconCompanionEnvelope(generatedAt: Date(), snapshot: Data())
  unknown.version = 2
  #expect(throws: BeaconCompanionError.self) { try BeaconCompanionWire.encode(unknown) }
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let payload = try encoder.encode(unknown)
  #expect(throws: BeaconCompanionError.self) { try BeaconCompanionWire.decode(payload) }
  let huge = BeaconCompanionEnvelope(
    generatedAt: Date(),
    snapshot: Data(repeating: 0, count: BeaconCompanionWire.maximumPayloadBytes))
  #expect(throws: BeaconCompanionError.self) { try BeaconCompanionWire.encode(huge) }
}
