import Foundation
@preconcurrency import WatchConnectivity

/// Sends only the shared count schema. Pairing credentials and session metadata never
/// enter WatchConnectivity or the widget App Group.
@MainActor
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
  static let shared = PhoneWatchBridge()
  private var latestData: Data?
  private var started = false

  func start() {
    guard !started, WCSession.isSupported() else { return }
    started = true
    if let snapshot = GlanceStore.shared.load() {
      latestData = try? snapshot.encodedData()
    }
    let session = WCSession.default
    session.delegate = self
    session.activate()
  }

  func publish(_ snapshot: GlanceSnapshot) {
    guard let data = try? snapshot.encodedData() else { return }
    latestData = data
    start()
    sendLatest()
  }

  func clear() {
    // An explicit tombstone removes old counts on the watch after unpairing.
    latestData = Data()
    start()
    sendLatest()
  }

  private func sendLatest() {
    guard WCSession.isSupported(), let latestData else { return }
    let session = WCSession.default
    guard session.activationState == .activated, session.isPaired,
      session.isWatchAppInstalled
    else { return }
    // Application context coalesces to the latest state while the watch is away.
    // System delivery and widget budgets determine refresh timing.
    let context: [String: Any] = [GlanceConstants.contextKey: latestData]
    try? session.updateApplicationContext(context)
    if session.isReachable {
      session.sendMessage(context, replyHandler: nil, errorHandler: nil)
    }
  }

  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: (any Error)?
  ) {
    Task { @MainActor [weak self] in self?.sendLatest() }
  }

  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

  nonisolated func sessionDidDeactivate(_ session: WCSession) {
    Task { @MainActor in WCSession.default.activate() }
  }

  nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor [weak self] in self?.sendLatest() }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    guard message["requestGlance"] as? Bool == true else { return }
    // A watch refresh request can only re-send the last observed aggregate.
    // It cannot run commands or access a coding harness.
    Task { @MainActor [weak self] in self?.sendLatest() }
  }
}
