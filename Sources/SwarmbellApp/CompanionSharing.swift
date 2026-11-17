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
  private var server: SwarmbellCompanionServer?
  private var reports: [String: Data] = [:]
  private var lastReports = Date.distantPast
  // Existing pairings stay in their original Keychain service after the rebrand.
  private let service = "local.agentbeacon.mac.companion"

  init() {
    if UserDefaults.standard.bool(forKey: "companionSharingEnabled") { enable() }
  }

  func enable() {
    guard server == nil else { return }
    do {
      let credential = try loadCredential()
      let server = SwarmbellCompanionServer(credential: credential)
      server.onStatus = { [weak self] message in
        Task { @MainActor in self?.status = message }
      }
      server.onPeerCount = { [weak self] count in
        Task { @MainActor in
          self?.peerCount = count
          self?.lastReports = .distantPast
        }
      }
      self.server = server
      enabled = true
      UserDefaults.standard.set(true, forKey: "companionSharingEnabled")
      let filter = CIFilter.qrCodeGenerator()
      filter.message = Data(credential.pairingURL.utf8)
      if let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
        let image = CIContext().createCGImage(output, from: output.extent)
      {
        pairingImage = NSImage(cgImage: image, size: .init(width: 260, height: 260))
      }
      try server.start()
    } catch {
      server?.stop()
      server = nil
      pairingImage = nil
      status = "Pairing could not start. Check that your login Keychain is unlocked and try again."
      enabled = false
    }
  }

  func stop() {
    server?.stop()
    server = nil
    enabled = false
    peerCount = 0
    pairingImage = nil
    reports = [:]
    status = "Sharing is off"
  }

  func disable() {
    UserDefaults.standard.set(false, forKey: "companionSharingEnabled")
    stop()
  }

  func resetPairing() {
    disable()
    let result = SecItemDelete(
      [
        kSecClass: kSecClassGenericPassword, kSecAttrService: service,
        kSecAttrAccount: "pairing-v1",
      ] as CFDictionary)
    if result == errSecSuccess || result == errSecItemNotFound {
      enable()
    } else {
      status = "Pairing could not be reset. Unlock your login Keychain and try again."
    }
  }

  func publish(_ snapshot: MonitorSnapshot, history: HistoryStore?) async {
    guard enabled, let server else { return }
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

  private func loadCredential() throws -> SwarmbellPairingCredential {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: "pairing-v1", kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
    ]
    var item: CFTypeRef?
    let result = SecItemCopyMatching(query as CFDictionary, &item)
    if result == errSecSuccess, let data = item as? Data,
      let url = String(data: data, encoding: .utf8)
    {
      return try .init(pairingURL: url)
    }
    guard result == errSecItemNotFound else { throw SwarmbellError("Pairing key unavailable") }
    let credential = try SwarmbellPairingCredential.generate()
    let saved = SecItemAdd(
      [
        kSecClass: kSecClassGenericPassword, kSecAttrService: service,
        kSecAttrAccount: "pairing-v1", kSecValueData: Data(credential.pairingURL.utf8),
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ] as CFDictionary, nil)
    guard saved == errSecSuccess else { throw SwarmbellError("Pairing key could not be saved") }
    return credential
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
