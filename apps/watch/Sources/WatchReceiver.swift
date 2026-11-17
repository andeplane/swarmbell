import Foundation
import SwiftUI
@preconcurrency import WatchConnectivity
import WidgetKit

/// Receives only the aggregate schema from the paired iPhone. No Mac connection or actions.
@MainActor
final class WatchReceiver: NSObject, ObservableObject, WCSessionDelegate {
  static let shared = WatchReceiver()
  @Published private(set) var snapshot: GlanceSnapshot?
  @Published private(set) var syncUnavailable = false
  private var started = false
  private var lastWidgetReload: Date?

  override private init() {
    snapshot = GlanceStore.shared.load()
    super.init()
  }

  func activate() {
    guard !started, WCSession.isSupported() else { return }
    started = true
    let session = WCSession.default
    session.delegate = self
    session.activate()
  }

  func readReceivedContext() {
    guard WCSession.isSupported() else { return }
    receive(WCSession.default.receivedApplicationContext[GlanceConstants.contextKey] as? Data)
  }

  func requestLatest() {
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    guard session.activationState == .activated, session.isReachable else { return }
    session.sendMessage(["requestGlance": true], replyHandler: nil) { [weak self] _ in
      Task { @MainActor [weak self] in self?.syncUnavailable = true }
    }
  }

  private func receive(_ data: Data?) {
    guard let data else { return }
    if data.isEmpty {
      do {
        try GlanceStore.shared.clear()
        snapshot = nil
        syncUnavailable = false
        WidgetCenter.shared.reloadAllTimelines()
        lastWidgetReload = nil
      } catch {
        syncUnavailable = true
      }
      return
    }
    do {
      let next = try GlanceSnapshot.decode(data)
      let previous = snapshot
      let changed = try GlanceStore.shared.save(next)
      snapshot = GlanceStore.shared.load()
      syncUnavailable = false
      let valuesChanged =
        previous?.active != snapshot?.active
        || previous?.working != snapshot?.working
        || previous?.needsYou != snapshot?.needsYou
        || previous?.connection != snapshot?.connection
        || previous?.incomplete != snapshot?.incomplete
      let refreshDue = lastWidgetReload.map { Date().timeIntervalSince($0) >= 15 * 60 } ?? true
      if changed && (valuesChanged || refreshDue) {
        WidgetCenter.shared.reloadAllTimelines()
        lastWidgetReload = Date()
      }
    } catch {
      // Keep the last validated counts; malformed data must never freshen them.
      syncUnavailable = true
    }
  }

  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: (any Error)?
  ) {
    Task { @MainActor [weak self] in
      self?.syncUnavailable = activationState != .activated || error != nil
      self?.readReceivedContext()
      self?.requestLatest()
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor [weak self] in self?.requestLatest() }
  }

  nonisolated func session(
    _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    let data = applicationContext[GlanceConstants.contextKey] as? Data
    Task { @MainActor [weak self] in self?.receive(data) }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    let data = message[GlanceConstants.contextKey] as? Data
    Task { @MainActor [weak self] in self?.receive(data) }
  }
}
