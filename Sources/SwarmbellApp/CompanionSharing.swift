import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import Security
import SwarmbellCompanion
import SwarmbellCore
import SwiftUI

@MainActor
final class CompanionSharing: ObservableObject {
  @Published private(set) var enabled = false
  @Published private(set) var status = "Sharing is off"
  @Published private(set) var peerCount = 0
  @Published private(set) var pairingImage: NSImage?
  @Published private(set) var authorizationRequired = false
  private var server: SwarmbellCompanionServer?
  private var pairingLink: String?
  private let resetPendingKey = "companionPairingResetPending"
  private var reports: [String: Data] = [:]
  private var lastReports = Date.distantPast
  private var history: HistoryStore?
  private var startupTask: Task<Void, Never>?
  private var startupIntent: UUID?
  enum CredentialAccessError: Error {
    case authorizationRequired, authorizationCanceled
  }
  private let credentialOperation: @Sendable (Bool, Bool) throws -> SwarmbellPairingCredential
  // Existing pairings stay in their original Keychain service after the rebrand.
  private nonisolated static let service = "local.agentbeacon.mac.companion"
  // Canceling a Task cannot interrupt an OS Keychain dialog. Serialize even canceled workers
  // so a second enable/reset cannot race the first worker's credential read or creation.
  private nonisolated static let credentialLock = NSLock()

  init(
    credentialOperation: @escaping @Sendable (Bool, Bool) throws -> SwarmbellPairingCredential = {
      try CompanionSharing.loadCredential(reset: $0, allowAuthorization: $1)
    }
  ) {
    self.credentialOperation = credentialOperation
    if UserDefaults.standard.bool(forKey: resetPendingKey) {
      authorizationRequired = true
      status = "Authorize sharing to finish resetting the previous pairing."
    } else if UserDefaults.standard.bool(forKey: "companionSharingEnabled") {
      // Launch never summons an authorization dialog. Only a deliberate enable/retry may.
      beginStartup(reset: false, allowAuthorization: false)
    }
  }

  func enable() {
    guard server == nil, startupTask == nil else { return }
    beginStartup(
      reset: UserDefaults.standard.bool(forKey: resetPendingKey), allowAuthorization: true)
  }

  private func beginStartup(reset: Bool, allowAuthorization: Bool) {
    let intent = UUID()
    startupIntent = intent
    enabled = true
    authorizationRequired = false
    status =
      reset
      ? "Resetting companion pairing…"
      : (allowAuthorization
        ? "Authorizing sharing. Respond to macOS Keychain if prompted."
        : "Starting companion sharing…")
    UserDefaults.standard.set(true, forKey: "companionSharingEnabled")
    let operation = credentialOperation
    startupTask = Task { [weak self] in
      do {
        // Security.framework may wait for macOS authorization. Never block app startup or
        // the main actor while that dialog is pending; authentication itself is unchanged.
        let worker = Task.detached(priority: .utility) { try operation(reset, allowAuthorization) }
        let credential = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: {
          worker.cancel()
        }
        guard let self, self.startupIntent == intent, !Task.isCancelled else { return }
        self.startupTask = nil
        try self.startServer(credential: credential)
        if reset { UserDefaults.standard.removeObject(forKey: self.resetPendingKey) }
        self.startupIntent = nil
      } catch {
        guard let self, self.startupIntent == intent, !Task.isCancelled else { return }
        self.startupTask = nil
        self.startupIntent = nil
        self.server?.stop()
        self.server = nil
        self.pairingLink = nil
        self.pairingImage = nil
        if let accessError = error as? CredentialAccessError {
          self.authorizationRequired = true
          switch accessError {
          case .authorizationRequired:
            self.status =
              reset
              ? "Pairing reset needs Keychain permission. Choose Authorize sharing to finish the reset."
              : "Sharing needs permission to read your saved pairing. Choose Authorize sharing to let macOS ask."
          case .authorizationCanceled:
            self.status =
              reset
              ? "Pairing reset authorization was canceled. Choose Authorize sharing to finish the reset."
              : "Keychain authorization was canceled. Your saved pairing is unchanged. Choose Authorize sharing to retry."
          }
        } else {
          self.status =
            reset
            ? "Pairing could not be reset. Unlock your login Keychain and try again."
            : "Pairing could not start. Check that your login Keychain is unlocked and try again."
        }
        self.enabled = false
      }
    }
  }

  private func startServer(credential: SwarmbellPairingCredential) throws {
    let server = SwarmbellCompanionServer(credential: credential)
    server.onAnalyticsQuery = { [weak self, weak server] query in
      guard let self, let server, self.enabled, self.server === server,
        let history = self.history,
        let timeZone = TimeZone(identifier: query.timeZoneID)
      else { throw SwarmbellCompanionError.analyticsUnavailable }
      try query.validate()
      // Query existing persisted aggregates only. This never collects or changes agent state.
      let report = try await history.report(
        from: query.from, to: query.to, timeZone: timeZone,
        harness: query.harness.flatMap(Harness.init(rawValue:)))
      guard self.enabled, self.server === server, !Task.isCancelled else {
        throw SwarmbellCompanionError.analyticsUnavailable
      }
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      return try encoder.encode(report)
    }
    server.onStatus = { [weak self, weak server] message in
      Task { @MainActor in
        guard let self, let server, self.server === server else { return }
        self.status = message
      }
    }
    server.onPeerCount = { [weak self, weak server] count in
      Task { @MainActor in
        guard let self, let server, self.server === server else { return }
        self.peerCount = count
        self.lastReports = .distantPast
      }
    }
    self.server = server
    enabled = true
    UserDefaults.standard.set(true, forKey: "companionSharingEnabled")
    let filter = CIFilter.qrCodeGenerator()
    pairingLink = credential.pairingURL
    filter.message = Data(credential.pairingURL.utf8)
    if let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
      let image = CIContext().createCGImage(output, from: output.extent)
    {
      pairingImage = NSImage(cgImage: image, size: .init(width: 260, height: 260))
    }
    try server.start()
  }

  func stop() {
    startupIntent = nil
    startupTask?.cancel()
    startupTask = nil
    server?.stop()
    server = nil
    enabled = false
    authorizationRequired = false
    peerCount = 0
    pairingLink = nil
    pairingImage = nil
    reports = [:]
    history = nil
    status = "Sharing is off"
  }

  func disable() {
    UserDefaults.standard.set(false, forKey: "companionSharingEnabled")
    stop()
  }

  func copyPairingLink() {
    guard enabled, let pairingLink else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    pasteboard.setString(pairingLink, forType: .string)
  }

  func resetPairing() {
    UserDefaults.standard.set(true, forKey: resetPendingKey)
    disable()
    beginStartup(reset: true, allowAuthorization: true)
  }

  func publish(_ snapshot: MonitorSnapshot, history: HistoryStore?) async {
    guard enabled, let server else { return }
    self.history = history
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if peerCount > 0, Date().timeIntervalSince(lastReports) >= 30, let history {
      lastReports = Date()
      let to = Date()
      for (name, days) in [("week", 7), ("month", 30)] {
        if let report = try? await history.report(
          from: to.addingTimeInterval(-Double(days) * 86_400), to: to,
          timeZone: TimeZone(identifier: "Europe/Oslo") ?? .current, harness: nil),
          let data = try? encoder.encode(report)
        {
          reports[name] = data
        }
      }
    }
    guard enabled, self.server === server,
      let data = try? encoder.encode(snapshot)
    else { return }
    do {
      try server.publish(envelope: .init(generatedAt: Date(), snapshot: data, reports: reports))
    } catch {
      status = "The latest update could not be shared. Waiting for the next refresh."
    }
  }

  private nonisolated static func loadCredential(
    reset: Bool, allowAuthorization: Bool
  ) throws -> SwarmbellPairingCredential {
    credentialLock.lock()
    defer { credentialLock.unlock() }
    try Task.checkCancellation()
    let authenticationUI =
      allowAuthorization ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
    if reset {
      let result = SecItemDelete(
        [
          kSecClass: kSecClassGenericPassword, kSecAttrService: service,
          kSecAttrAccount: "pairing-v1", kSecUseAuthenticationUI: authenticationUI,
        ] as CFDictionary)
      try checkAuthorizationResult(result)
      guard result == errSecSuccess || result == errSecItemNotFound else {
        throw SwarmbellError("Pairing key could not be reset")
      }
      try Task.checkCancellation()
    }
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: "pairing-v1", kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationUI: authenticationUI,
    ]
    var item: CFTypeRef?
    let result = SecItemCopyMatching(query as CFDictionary, &item)
    try checkAuthorizationResult(result)
    if result == errSecSuccess, let data = item as? Data,
      let url = String(data: data, encoding: .utf8)
    {
      return try .init(pairingURL: url)
    }
    guard result == errSecItemNotFound else { throw SwarmbellError("Pairing key unavailable") }
    try Task.checkCancellation()
    let credential = try SwarmbellPairingCredential.generate()
    let saved = SecItemAdd(
      [
        kSecClass: kSecClassGenericPassword, kSecAttrService: service,
        kSecAttrAccount: "pairing-v1", kSecValueData: Data(credential.pairingURL.utf8),
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecUseAuthenticationUI: authenticationUI,
      ] as CFDictionary, nil)
    try checkAuthorizationResult(saved)
    guard saved == errSecSuccess else { throw SwarmbellError("Pairing key could not be saved") }
    return credential
  }

  private nonisolated static func checkAuthorizationResult(_ result: OSStatus) throws {
    if result == errSecUserCanceled { throw CredentialAccessError.authorizationCanceled }
    if result == errSecInteractionNotAllowed || result == errSecAuthFailed {
      throw CredentialAccessError.authorizationRequired
    }
  }
}

struct CompanionSettingsSection: View {
  @ObservedObject var sharing: CompanionSharing
  @State private var showPairing = false
  @State private var confirmReset = false
  var body: some View {
    Section("iPhone companion") {
      Toggle(
        "Share with paired iPhone",
        isOn: Binding(
          get: { sharing.enabled },
          set: { $0 ? sharing.enable() : sharing.disable() }))
      Text(sharing.status).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if sharing.authorizationRequired && !sharing.enabled {
        Button("Authorize sharing…") { sharing.enable() }
      }
      if sharing.enabled {
        HStack {
          Button("Pair iPhone…") { showPairing = true }
          Text("\(sharing.peerCount) connected").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .sheet(isPresented: $showPairing) {
      VStack(alignment: .leading, spacing: 18) {
        Text("Pair Swarmbell").font(.title2.bold())
        Text(
          "Open Swarmbell on your iPhone, choose Scan QR code, and scan this code. Keep both devices on the same Wi-Fi network."
        )
        .fixedSize(horizontal: false, vertical: true)
        if let image = sharing.pairingImage {
          Image(nsImage: image).interpolation(.none).resizable()
            .frame(width: 260, height: 260).padding(12).background(.white)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Private Swarmbell pairing QR code")
        }
        Text(
          "The code grants read access to agent titles, projects, status and statistics. Keep it private. Reset pairing to disconnect previously paired phones."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Copy pairing link") { sharing.copyPairingLink() }.disabled(
            sharing.pairingImage == nil)
          Button("Reset pairing…") { confirmReset = true }
          Spacer()
          Button("Done") { showPairing = false }.keyboardShortcut(.defaultAction)
        }
      }.padding(24).frame(width: 420)
        .alert("Reset all iPhone pairing?", isPresented: $confirmReset) {
          Button("Reset pairing", role: .destructive) { sharing.resetPairing() }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("Previously paired phones will need to scan the new code.")
        }
    }
  }
}
