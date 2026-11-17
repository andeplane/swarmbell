@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct PairingScanner: UIViewControllerRepresentable {
  var onCode: (String) -> Void
  func makeUIViewController(context: Context) -> ScannerController {
    let controller = ScannerController()
    controller.onCode = onCode
    return controller
  }
  func updateUIViewController(_ controller: ScannerController, context: Context) {}
  static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) {
    controller.stop()
  }
}

private final class CaptureBox: @unchecked Sendable {
  let session = AVCaptureSession()
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onCode: ((String) -> Void)?
  private let capture = CaptureBox()
  private let captureQueue = DispatchQueue(label: "AgentBeacon.Camera")
  private var preview: AVCaptureVideoPreviewLayer?
  private var accepted = false
  private var isStopped = false
  private let message = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    message.text = "Point your camera at the pairing code on your Mac."
    message.textColor = .white
    message.font = .preferredFont(forTextStyle: .body)
    message.adjustsFontForContentSizeCategory = true
    message.numberOfLines = 0
    message.textAlignment = .center
    message.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(message)
    NSLayoutConstraint.activate([
      message.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      message.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      message.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
    ])
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: configure()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        Task { @MainActor in
          if granted { self?.configure() } else { self?.showUnavailable() }
        }
      }
    default: showUnavailable()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
  }

  private func configure() {
    guard !isStopped else { return }
    guard let device = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: device), capture.session.canAddInput(input)
    else {
      showUnavailable()
      return
    }
    capture.session.addInput(input)
    let output = AVCaptureMetadataOutput()
    guard capture.session.canAddOutput(output) else {
      showUnavailable()
      return
    }
    capture.session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]
    let layer = AVCaptureVideoPreviewLayer(session: capture.session)
    layer.videoGravity = .resizeAspectFill
    layer.frame = view.bounds
    view.layer.insertSublayer(layer, at: 0)
    preview = layer
    let box = capture
    captureQueue.async { box.session.startRunning() }
  }

  func stop() {
    isStopped = true
    let box = capture
    captureQueue.async { if box.session.isRunning { box.session.stopRunning() } }
  }

  private func showUnavailable() {
    message.text =
      "Camera access is unavailable. Enable it in iPhone Settings, or go back and paste the pairing link."
  }

  nonisolated func metadataOutput(
    _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
      let code = object.stringValue, code.hasPrefix("agentbeacon://pair"), code.utf8.count < 4096
    else { return }
    Task { @MainActor [weak self] in
      guard let self, !accepted else { return }
      accepted = true
      stop()
      onCode?(code)
    }
  }
}
