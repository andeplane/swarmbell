import SwiftUI
import UIKit

struct PairingView: View {
  @ObservedObject var model: SwarmbellPhoneModel
  @State private var pairingText = ""
  @State private var scannerPresented = false
  @State private var forgetPresented = false
  @Environment(\.openURL) private var openURL
  var body: some View {
    Form {
      Section {
        Label(
          model.isConnected
            ? "Connected to your Mac" : model.isPaired ? "Pairing code saved" : "Pair your Mac",
          systemImage: model.isConnected ? "checkmark.circle.fill" : "desktopcomputer"
        )
        .font(.headline)
        Text(model.connectionStatus).foregroundStyle(.secondary)
          .accessibilityAddTraits(.updatesFrequently)
        if model.isConnected && model.snapshot != nil {
          NavigationLink("View agents") { AgentsView(model: model) }
        }
        Text(
          "Swarmbell on your Mac collects agent status. This iPhone receives it over an encrypted local connection while the app is open."
        )
        .font(.subheadline).foregroundStyle(.secondary)
      }
      Section(model.isPaired ? "Pair another Mac" : "Connect") {
        Text(
          "On your Mac, open Swarmbell → Settings → iPhone companion. Enable sharing, then scan the pairing code."
        )
        .font(.subheadline)
        Button {
          scannerPresented = true
        } label: {
          Label("Scan pairing code", systemImage: "qrcode.viewfinder")
        }
        SecureField("Or paste a pairing link", text: $pairingText)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("Pair with this Mac") {
          model.pair(pairingText)
          if model.pairingError == nil { pairingText = "" }
        }.disabled(pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let error = model.pairingError {
        Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
      }
      if model.isPaired {
        Section {
          Button("Reconnect") {
            model.stop()
            model.start()
          }
          Button("Forget this Mac", role: .destructive) { forgetPresented = true }
        } footer: {
          Text(
            "Keep both devices on the same local network and allow Local Network access. Sharing stops when the Mac app quits. Pairing links grant read access; keep yours private."
          )
        }
        if !model.isConnected {
          Section("Mac not appearing?") {
            Text(
              "Keep sharing enabled on the Mac and connect both devices to the same Wi-Fi network. In iPhone Settings, allow Swarmbell to access the Local Network."
            )
            .font(.subheadline)
            Button("Open iPhone Settings") {
              if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
          }
        }
      }
      Section("Privacy") {
        Text(
          "No hosted backend. No prompts or transcripts are transferred. Session titles, project paths, source status and statistics come from your paired Mac."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Connection")
    .sheet(isPresented: $scannerPresented) {
      NavigationStack {
        PairingScanner { code in
          scannerPresented = false
          model.pair(code)
        }
        .navigationTitle("Scan pairing code").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { scannerPresented = false }
          }
        }
      }
    }
    .confirmationDialog(
      "Forget your paired Mac?", isPresented: $forgetPresented, titleVisibility: .visible
    ) {
      Button("Forget Mac", role: .destructive) { model.forget() }
    } message: {
      Text("You can pair again using the code in Swarmbell on your Mac.")
    }
  }
}
