import AgentBeaconCompanion
import Foundation
import Security
import SwiftUI

@MainActor
final class BeaconPhoneModel: ObservableObject {
  @Published private(set) var snapshot: MonitorSnapshot?
  @Published private(set) var reports: [String: AnalyticsReport] = [:]
  @Published private(set) var connectionStatus = "Not paired"
  @Published private(set) var receivedAt: Date?
  @Published private(set) var isPaired = false
  @Published private(set) var isConnected = false
  @Published var pairingError: String?
  private var client: BeaconCompanionClient?
  private var credential: BeaconPairingCredential?

  init() {
    do {
      if let saved = try PairingStorage.load() {
        credential = try BeaconPairingCredential(pairingURL: saved)
        isPaired = true
        connectionStatus = "Ready to connect"
      }
    } catch {
      pairingError = "Your saved pairing could not be loaded. Pair this iPhone again."
    }
  }

  func pair(_ text: String) {
    do {
      let parsed = try BeaconPairingCredential(
        pairingURL: text.trimmingCharacters(in: .whitespacesAndNewlines))
      try PairingStorage.save(parsed.pairingURL)
      stop()
      snapshot = nil
      reports = [:]
      receivedAt = nil
      credential = parsed
      isPaired = true
      pairingError = nil
      start()
    } catch {
      pairingError =
        "Could not pair. Scan the current code in Agent Beacon’s Mac Settings, or paste its complete pairing link."
    }
  }

  func start() {
    guard client == nil, let credential else { return }
    let connection = BeaconCompanionClient(credential: credential)
    connection.onStatus = { [weak self] status in self?.connectionStatus = status }
    connection.onConnectionChanged = { [weak self] connected in self?.isConnected = connected }
    connection.onEnvelope = { [weak self] envelope in self?.receive(envelope) }
    client = connection
    connection.start()
  }

  func stop() {
    client?.stop()
    client = nil
    isConnected = false
    if isPaired { connectionStatus = "Disconnected" }
  }

  func forget() {
    do { try PairingStorage.remove() } catch {
      pairingError =
        "The saved pairing could not be removed. Try again while the iPhone is unlocked."
      return
    }
    stop()
    credential = nil
    snapshot = nil
    reports = [:]
    receivedAt = nil
    isPaired = false
    connectionStatus = "Not paired"
  }

  func isCurrent(at now: Date) -> Bool {
    guard let receivedAt, let snapshot else { return false }
    return now.timeIntervalSince(receivedAt) < 15
      && now.timeIntervalSince(snapshot.generatedAt) < 20
      && now.timeIntervalSince(snapshot.generatedAt) >= -30
      && isConnected
  }

  private func receive(_ envelope: BeaconCompanionEnvelope) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard envelope.version == 1,
      let next = try? decoder.decode(MonitorSnapshot.self, from: envelope.snapshot),
      next.schemaVersion == 1
    else {
      connectionStatus = "This Mac sent an unsupported update. Update both apps."
      return
    }
    snapshot = next
    receivedAt = Date()
    var nextReports: [String: AnalyticsReport] = [:]
    for key in ["week", "month"] {
      if let data = envelope.reports[key],
        let report = try? decoder.decode(AnalyticsReport.self, from: data)
      {
        nextReports[key] = report
      }
    }
    reports = nextReports
  }
}

private enum PairingStorage {
  static let service = "dev.andeplane.AgentBeacon.pairing"
  static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "paired-mac",
    ]
  }
  static func load() throws -> String? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, data.count < 4096,
      let text = String(data: data, encoding: .utf8)
    else { throw StorageError.unavailable }
    return text
  }
  static func save(_ text: String) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(text.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updated == errSecItemNotFound {
      var item = query
      item.merge(attributes, uniquingKeysWith: { _, next in next })
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
        throw StorageError.unavailable
      }
    } else if updated != errSecSuccess {
      throw StorageError.unavailable
    }
  }
  static func remove() throws {
    let result = SecItemDelete(query as CFDictionary)
    guard result == errSecSuccess || result == errSecItemNotFound else {
      throw StorageError.unavailable
    }
  }
  enum StorageError: Error { case unavailable }
}
