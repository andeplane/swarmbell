import Foundation
@preconcurrency import Network
import Security

private let beaconServiceType = "_agentbeacon._tcp"

/// Apple's Network framework TLS-PSK mode is TLS 1.2 only. No certificate-verification
/// bypass is installed: the 256-bit secret authenticates both endpoints in the handshake.
private func beaconParameters(_ credential: BeaconPairingCredential) -> NWParameters {
  let tls = NWProtocolTLS.Options()
  let options = tls.securityProtocolOptions
  sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
  sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
  sec_protocol_options_append_tls_ciphersuite(
    options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
  let key = credential.secret.withUnsafeBytes { DispatchData(bytes: $0) }
  let identity = Data("agent-beacon-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
  sec_protocol_options_add_pre_shared_key(
    options, key as __DispatchData, identity as __DispatchData)
  let tcp = NWProtocolTCP.Options()
  tcp.connectionTimeout = 10
  let parameters = NWParameters(tls: tls, tcp: tcp)
  parameters.includePeerToPeer = true
  return parameters
}

private func beaconUsesAuthenticatedPSK(_ connection: NWConnection) -> Bool {
  guard
    let metadata = connection.metadata(definition: NWProtocolTLS.definition)
      as? NWProtocolTLS.Metadata
  else { return false }
  return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata)
    .rawValue == UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)
}

/// All state and callbacks are main-actor isolated. Network.framework runs its handlers
/// on the main dispatch queue, then explicitly enters the main actor before mutation.
@MainActor
public final class BeaconCompanionServer {
  public var onStatus: ((String) -> Void)?
  public var onPeerCount: ((Int) -> Void)?
  private let credential: BeaconPairingCredential
  private var listener: NWListener?
  private var peers: [UUID: Peer] = [:]
  private var latestFrame: Data?

  private struct Peer {
    let connection: NWConnection
    var ready = false
    var sending = false
    var pending: Data?
    var timeout: Task<Void, Never>?
  }

  public init(credential: BeaconPairingCredential) { self.credential = credential }

  public func start() throws {
    guard listener == nil else { return }
    let listener = try NWListener(using: beaconParameters(credential), on: .any)
    self.listener = listener
    listener.service = .init(name: credential.serviceName, type: beaconServiceType)
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      Task { @MainActor in
        guard let self, let listener, self.listener === listener else { return }
        switch state {
        case .ready: self.onStatus?("Available to your paired iPhone")
        case .failed:
          self.stop()
          self.onStatus?("Companion sharing could not start. Check local network access.")
        default: break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection) }
    }
    listener.start(queue: .main)
    onStatus?("Starting local companion sharing…")
  }

  public func stop() {
    listener?.cancel()
    listener = nil
    for peer in peers.values {
      peer.timeout?.cancel()
      peer.connection.cancel()
    }
    peers.removeAll()
    latestFrame = nil
    onPeerCount?(0)
    onStatus?("Companion sharing is off")
  }

  public func publish(envelope: BeaconCompanionEnvelope) throws {
    let frame = try BeaconCompanionWire.encode(envelope)
    latestFrame = frame
    for id in Array(peers.keys) where peers[id]?.ready == true { send(frame, to: id) }
  }

  private func accept(_ connection: NWConnection) {
    guard listener != nil, peers.count < 4 else {
      connection.cancel()
      return
    }
    let id = UUID()
    peers[id] = Peer(connection: connection)
    peers[id]?.timeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(15))
      guard !Task.isCancelled else { return }
      self?.remove(id)
    }
    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self, self.peers[id] != nil else { return }
        switch state {
        case .ready:
          guard beaconUsesAuthenticatedPSK(connection) else {
            self.remove(id)
            return
          }
          self.peers[id]?.timeout?.cancel()
          self.peers[id]?.timeout = nil
          self.peers[id]?.ready = true
          self.onPeerCount?(self.peers.values.filter(\.ready).count)
          if let frame = self.latestFrame { self.send(frame, to: id) }
          // This protocol is server-push only. Any client application data is invalid.
          connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
            Task { @MainActor in self.remove(id) }
          }
        case .failed, .cancelled, .waiting: self.remove(id)
        default: break
        }
      }
    }
    connection.start(queue: .main)
  }

  private func remove(_ id: UUID) {
    guard let peer = peers.removeValue(forKey: id) else { return }
    peer.timeout?.cancel()
    peer.connection.cancel()
    onPeerCount?(peers.values.filter(\.ready).count)
  }

  private func send(_ frame: Data, to id: UUID) {
    guard let peer = peers[id], peer.ready else { return }
    if peer.sending {
      // Bounded backpressure: retain only the newest unsent refresh per peer.
      peers[id]?.pending = frame
      return
    }
    peers[id]?.sending = true
    peer.connection.send(
      content: frame,
      completion: .contentProcessed { [weak self] error in
        Task { @MainActor in
          guard let self, self.peers[id] != nil else { return }
          guard error == nil else {
            self.remove(id)
            return
          }
          self.peers[id]?.sending = false
          if let next = self.peers[id]?.pending {
            self.peers[id]?.pending = nil
            self.send(next, to: id)
          }
        }
      })
  }
}

@MainActor
public final class BeaconCompanionClient {
  public var onStatus: ((String) -> Void)?
  public var onEnvelope: ((BeaconCompanionEnvelope) -> Void)?
  public var onConnectionChanged: ((Bool) -> Void)?
  private let credential: BeaconPairingCredential
  private var browser: NWBrowser?
  private var connection: NWConnection?
  private var endpoint: NWEndpoint?
  private var retry: Task<Void, Never>?
  private var handshakeTimeout: Task<Void, Never>?
  private var discoveryTimeout: Task<Void, Never>?
  private var failureCount = 0

  public init(credential: BeaconPairingCredential) { self.credential = credential }

  public func start() {
    guard browser == nil else { return }
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let browser = NWBrowser(for: .bonjour(type: beaconServiceType, domain: nil), using: parameters)
    self.browser = browser
    browser.stateUpdateHandler = { [weak self, weak browser] state in
      Task { @MainActor in
        guard let self, let browser, self.browser === browser else { return }
        switch state {
        case .ready:
          if self.connection == nil, self.endpoint == nil {
            self.onStatus?("Looking for your paired Mac…")
            self.scheduleDiscoveryTimeout()
          }
        case .waiting, .failed:
          self.discoveryTimeout?.cancel()
          self.discoveryTimeout = nil
          // Discovery can fail while an established connection is still usable.
          // Preserve that connection's live status rather than replacing it.
          guard self.connection == nil else { return }
          self.onConnectionChanged?(false)
          self.onStatus?(
            "Cannot discover your Mac. Allow Local Network access in iPhone Settings, and keep both devices on the same Wi-Fi network."
          )
        default: break
        }
      }
    }
    browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
      Task { @MainActor in
        guard let self, let browser, self.browser === browser else { return }
        self.endpoint =
          results.first(where: { result in
            if case .service(let name, _, _, _) = result.endpoint {
              return name == self.credential.serviceName
            }
            return false
          })?.endpoint
        if self.connection == nil, self.retry == nil, let endpoint = self.endpoint {
          self.connect(to: endpoint)
        }
      }
    }
    browser.start(queue: .main)
    onConnectionChanged?(false)
    onStatus?("Looking for your paired Mac…")
    scheduleDiscoveryTimeout()
  }

  public func stop() {
    browser?.cancel()
    browser = nil
    retry?.cancel()
    retry = nil
    handshakeTimeout?.cancel()
    handshakeTimeout = nil
    discoveryTimeout?.cancel()
    discoveryTimeout = nil
    let old = connection
    connection = nil
    old?.cancel()
    endpoint = nil
    failureCount = 0
    onConnectionChanged?(false)
    onStatus?("Disconnected")
  }

  private func scheduleDiscoveryTimeout() {
    discoveryTimeout?.cancel()
    guard browser != nil, connection == nil, endpoint == nil else { return }
    discoveryTimeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(15))
      guard !Task.isCancelled, let self, self.browser != nil,
        self.connection == nil, self.endpoint == nil
      else { return }
      self.onConnectionChanged?(false)
      self.onStatus?(
        "Your Mac has not been found yet. Keep Agent Beacon sharing on, use the same Wi-Fi network, and check Local Network access in iPhone Settings."
      )
    }
  }

  private func connect(to endpoint: NWEndpoint) {
    guard browser != nil, connection == nil else { return }
    discoveryTimeout?.cancel()
    discoveryTimeout = nil
    let connection = NWConnection(to: endpoint, using: beaconParameters(credential))
    self.connection = connection
    onConnectionChanged?(false)
    onStatus?("Connecting securely to your Mac…")
    handshakeTimeout?.cancel()
    handshakeTimeout = Task { [weak self, weak connection] in
      try? await Task.sleep(for: .seconds(15))
      guard !Task.isCancelled, let self, let connection, self.connection === connection else {
        return
      }
      self.disconnected(connection)
    }
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      Task { @MainActor in
        guard let self, let connection, self.connection === connection else { return }
        switch state {
        case .ready:
          guard beaconUsesAuthenticatedPSK(connection) else {
            self.disconnected(connection)
            self.onStatus?("The Mac could not authenticate this pairing code.")
            return
          }
          self.handshakeTimeout?.cancel()
          self.handshakeTimeout = nil
          self.failureCount = 0
          self.onConnectionChanged?(true)
          self.onStatus?("Connected to your Mac")
          self.receiveHeader(connection)
        case .failed, .cancelled, .waiting: self.disconnected(connection)
        default: break
        }
      }
    }
    connection.start(queue: .main)
  }

  private func disconnected(_ old: NWConnection) {
    guard connection === old else { return }
    connection = nil
    old.cancel()
    handshakeTimeout?.cancel()
    handshakeTimeout = nil
    onConnectionChanged?(false)
    onStatus?("Mac disconnected. Reconnecting…")
    guard browser != nil else { return }
    failureCount = min(failureCount + 1, 4)
    let delay = min(30, 1 << failureCount)
    retry?.cancel()
    retry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.retry = nil
      if let endpoint = self.endpoint {
        self.connect(to: endpoint)
      } else {
        self.onStatus?("Looking for your paired Mac…")
        self.scheduleDiscoveryTimeout()
      }
    }
  }

  private func receiveHeader(_ connection: NWConnection) {
    receiveExactly(4, from: connection) { [weak self] header in
      guard let self else { return }
      do {
        let length = try BeaconCompanionWire.payloadLength(header: header)
        self.receiveExactly(length, from: connection) { [weak self] payload in
          guard let self else { return }
          do {
            let envelope = try BeaconCompanionWire.decode(payload)
            self.onEnvelope?(envelope)
            self.receiveHeader(connection)
          } catch {
            self.disconnected(connection)
            self.onStatus?("The Mac sent an unsupported companion message.")
          }
        }
      } catch {
        self.disconnected(connection)
        self.onStatus?("The Mac sent an invalid companion message.")
      }
    }
  }

  private func receiveExactly(
    _ count: Int, from connection: NWConnection, completion: @escaping @MainActor (Data) -> Void
  ) {
    connection.receive(minimumIncompleteLength: count, maximumLength: count) {
      [weak self, weak connection] data, _, complete, error in
      Task { @MainActor in
        guard let self, let connection, self.connection === connection else { return }
        guard error == nil, let data, data.count == count else {
          self.disconnected(connection)
          return
        }
        completion(data)
        if complete { self.disconnected(connection) }
      }
    }
  }
}
