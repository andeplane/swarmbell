import Foundation
import Security
import SwarmbellCompanion
import SwiftUI
import WidgetKit

@MainActor
final class SwarmbellPhoneModel: ObservableObject {
  @Published private(set) var snapshot: MonitorSnapshot?
  @Published private(set) var reports: [String: AnalyticsReport] = [:]
  @Published private(set) var connectionStatus = "Not paired"
  @Published private(set) var receivedAt: Date?
  @Published private(set) var isPaired = false
  @Published private(set) var isConnected = false
  @Published var pairingError: String?
  @Published private(set) var requestedReport: AnalyticsReport?
  @Published private(set) var comparisonReport: AnalyticsReport?
  @Published private(set) var statisticsLoading = false
  @Published private(set) var statisticsError: String?
  @Published private(set) var supportsAnalyticsQueries = false
  private var client: SwarmbellCompanionClient?
  private var credential: SwarmbellPairingCredential?
  private var statisticsSelection: StatisticsSelection?
  private var statisticsRequest: StatisticsRequest?
  private var statisticsTimeout: Task<Void, Never>?
  private var lastWidgetReload: Date?
  private var lastWidgetReloadState: String?

  private struct StatisticsSelection {
    let id = UUID()
    let from: Date
    let to: Date
    let harness: Harness?
    let compare: Bool
  }

  private struct StatisticsRequest {
    let selectionID: UUID
    let comparison: Bool
    let query: SwarmbellAnalyticsQuery
  }

  init() {
    PhoneWatchBridge.shared.start()
    do {
      if let saved = try PairingStorage.load() {
        credential = try SwarmbellPairingCredential(pairingURL: saved)
        isPaired = true
        connectionStatus = "Ready to connect"
      }
    } catch {
      pairingError = "Your saved pairing could not be loaded. Pair this iPhone again."
    }
  }

  func pair(_ text: String) {
    do {
      let parsed = try SwarmbellPairingCredential(
        pairingURL: text.trimmingCharacters(in: .whitespacesAndNewlines))
      try PairingStorage.save(parsed.pairingURL)
      stop()
      snapshot = nil
      reports = [:]
      receivedAt = nil
      clearGlance()
      clearStatistics()
      credential = parsed
      isPaired = true
      pairingError = nil
      start()
    } catch {
      pairingError =
        "Could not pair. Scan the current code in Swarmbell’s Mac Settings, or paste its complete pairing link."
    }
  }

  func start() {
    guard client == nil, let credential else { return }
    let connection = SwarmbellCompanionClient(credential: credential)
    connection.onStatus = { [weak self] status in self?.connectionStatus = status }
    connection.onConnectionChanged = { [weak self] connected in
      guard let self else { return }
      self.isConnected = connected
      if !connected {
        self.supportsAnalyticsQueries = false
        if self.statisticsLoading {
          self.statisticsError = "Connect to your Mac to load this statistics range."
        }
        self.cancelStatisticsRequests()
      }
      self.publishGlance(forceReload: true)
    }
    connection.onEnvelope = { [weak self] envelope in self?.receive(envelope) }
    connection.onAnalyticsResponse = { [weak self] response in
      self?.receiveAnalytics(response)
    }
    client = connection
    connection.start()
  }

  func stop() {
    client?.stop()
    client = nil
    isConnected = false
    supportsAnalyticsQueries = false
    cancelStatisticsRequests()
    publishGlance(forceReload: true)
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
    clearStatistics()
    clearGlance()
    connectionStatus = "Not paired"
  }

  func isCurrent(at now: Date) -> Bool {
    guard let receivedAt, let snapshot else { return false }
    return now.timeIntervalSince(receivedAt) < 15
      && now.timeIntervalSince(snapshot.generatedAt) < 20
      && now.timeIntervalSince(snapshot.generatedAt) >= -30
      && isConnected
  }

  private func receive(_ envelope: SwarmbellCompanionEnvelope) {
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
    supportsAnalyticsQueries = client?.supportsAnalyticsQueries == true
    publishGlance()
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

  /// Requests only aggregate history. No phone command can approve or control an agent.
  func loadStatistics(from: Date, to: Date, harness: Harness?, compare: Bool) {
    statisticsSelection = StatisticsSelection(
      from: from, to: to, harness: harness, compare: compare)
    requestedReport = nil
    comparisonReport = nil
    statisticsError = nil
    guard supportsAnalyticsQueries, isConnected else {
      statisticsSelection = nil
      statisticsLoading = false
      statisticsError = "Connect to an updated Swarmbell on your Mac to load this range."
      return
    }
    statisticsLoading = true
    // The transport allows one pending request. A newer selection replaces queued work;
    // a response to an older selection is discarded before this one is sent.
    if statisticsRequest == nil { sendStatisticsRequest(comparison: false) }
  }

  private func sendStatisticsRequest(comparison: Bool) {
    guard let selection = statisticsSelection, let client, isConnected else { return }
    let duration = selection.to.timeIntervalSince(selection.from)
    let query = SwarmbellAnalyticsQuery(
      from: comparison ? selection.from.addingTimeInterval(-duration) : selection.from,
      to: comparison ? selection.from : selection.to,
      timeZoneID: TimeZone.current.identifier, harness: selection.harness?.rawValue)
    do {
      try client.requestAnalytics(query)
      statisticsRequest = StatisticsRequest(
        selectionID: selection.id, comparison: comparison, query: query)
      statisticsTimeout?.cancel()
      statisticsTimeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(25))
        guard !Task.isCancelled, let self,
          self.statisticsRequest?.query.requestID == query.requestID
        else { return }
        self.statisticsError =
          "Your Mac did not finish this report. Reconnect and try a shorter range."
        // Dropping the connection also clears the transport's one-request correlation slot.
        self.stop()
        self.start()
      }
    } catch {
      statisticsError = error.localizedDescription
      cancelStatisticsRequests()
    }
  }

  private func receiveAnalytics(_ response: SwarmbellAnalyticsResponse) {
    guard let request = statisticsRequest, request.query.requestID == response.requestID else {
      return
    }
    statisticsTimeout?.cancel()
    statisticsTimeout = nil
    statisticsRequest = nil
    guard let selection = statisticsSelection else { return }
    guard request.selectionID == selection.id else {
      sendStatisticsRequest(comparison: false)
      return
    }
    if let error = response.error {
      statisticsError = error.localizedDescription
      cancelStatisticsRequests()
      return
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = response.reportData,
      let report = try? decoder.decode(AnalyticsReport.self, from: data),
      abs(report.from.timeIntervalSince(request.query.from)) < 2,
      abs(report.to.timeIntervalSince(request.query.to)) < 2,
      report.timeZoneID == request.query.timeZoneID
    else {
      statisticsError = "Your Mac sent an unsupported statistics report. Update both apps."
      cancelStatisticsRequests()
      return
    }
    if request.comparison {
      comparisonReport = report
      statisticsLoading = false
      statisticsSelection = nil
    } else {
      requestedReport = report
      if selection.compare {
        sendStatisticsRequest(comparison: true)
      } else {
        statisticsLoading = false
        statisticsSelection = nil
      }
    }
  }

  private func cancelStatisticsRequests() {
    statisticsTimeout?.cancel()
    statisticsTimeout = nil
    statisticsRequest = nil
    statisticsSelection = nil
    statisticsLoading = false
  }

  private func clearStatistics() {
    cancelStatisticsRequests()
    requestedReport = nil
    comparisonReport = nil
    statisticsError = nil
  }

  private func publishGlance(forceReload: Bool = false) {
    guard isPaired, let snapshot, let receivedAt else { return }
    let glance = GlanceSnapshot(
      observedAt: snapshot.generatedAt, receivedAt: receivedAt,
      active: snapshot.counts.active, working: snapshot.counts.working,
      needsYou: snapshot.counts.needsYou, incomplete: snapshot.counts.incomplete,
      connection: isConnected ? .connected : .disconnected)
    do {
      try GlanceStore.shared.save(glance)
      PhoneWatchBridge.shared.publish(glance)
      let now = Date()
      let state =
        "\(glance.active)|\(glance.working)|\(glance.needsYou)|\(glance.incomplete)|\(glance.connection.rawValue)"
      if forceReload || state != lastWidgetReloadState
        || lastWidgetReload.map({ now.timeIntervalSince($0) >= 15 * 60 }) != false
      {
        WidgetCenter.shared.reloadAllTimelines()
        lastWidgetReload = now
        lastWidgetReloadState = state
      }
    } catch {
      // A locked or unavailable App Group must never erase the last good counts.
      // Live phone data remains available independently of the widget cache.
    }
  }

  private func clearGlance() {
    try? GlanceStore.shared.clear()
    PhoneWatchBridge.shared.clear()
    WidgetCenter.shared.reloadAllTimelines()
    lastWidgetReload = nil
    lastWidgetReloadState = nil
  }
}

private enum PairingStorage {
  // Retain the original service so existing paired installations keep their credentials.
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
