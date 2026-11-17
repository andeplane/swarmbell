import Foundation
@preconcurrency import Network
import Security

// Retain Bonjour and TLS-PSK identifiers for already-paired clients.
private let swarmbellServiceType = "_agentbeacon._tcp"

/// Apple's Network framework TLS-PSK mode is TLS 1.2 only. No certificate-verification
/// bypass is installed: the 256-bit secret authenticates both endpoints in the handshake.
private func swarmbellParameters(_ credential: SwarmbellPairingCredential) -> NWParameters {
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

private func swarmbellUsesAuthenticatedPSK(_ connection: NWConnection) -> Bool {
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
public final class SwarmbellCompanionServer {
  public var onStatus: ((String) -> Void)?
  public var onPeerCount: ((Int) -> Void)?
  public var onAnalyticsQuery: ((SwarmbellAnalyticsQuery) async throws -> Data)?
  private let credential: SwarmbellPairingCredential
  private var listener: NWListener?
  private var peers: [UUID: Peer] = [:]
  private var latestFrame: Data?
  private var runningQueries = 0

  private struct Peer {
    let connection: NWConnection
    var ready = false
    var sending = false
    var pending: Data?
    var pendingResponse: Data?
    var queryInFlight = false
    var queryTask: Task<Void, Never>?
    var readTimeout: Task<Void, Never>?
    var timeout: Task<Void, Never>?
  }

  public init(credential: SwarmbellPairingCredential) { self.credential = credential }

  public func start() throws {
    guard listener == nil else { return }
    let listener = try NWListener(using: swarmbellParameters(credential), on: .any)
    self.listener = listener
    listener.service = .init(name: credential.serviceName, type: swarmbellServiceType)
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
      peer.queryTask?.cancel()
      peer.readTimeout?.cancel()
      peer.connection.cancel()
    }
    peers.removeAll()
    latestFrame = nil
    onPeerCount?(0)
    onStatus?("Companion sharing is off")
  }

  public func publish(envelope: SwarmbellCompanionEnvelope) throws {
    var envelope = envelope
    envelope.capabilities = [SwarmbellAnalyticsWire.capability]
    let frame = try SwarmbellCompanionWire.encode(envelope)
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
          guard swarmbellUsesAuthenticatedPSK(connection) else {
            self.remove(id)
            return
          }
          self.peers[id]?.timeout?.cancel()
          self.peers[id]?.timeout = nil
          self.peers[id]?.ready = true
          self.onPeerCount?(self.peers.values.filter(\.ready).count)
          if let frame = self.latestFrame { self.send(frame, to: id) }
          self.receiveQueryHeader(from: id)
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
    peer.queryTask?.cancel()
    peer.readTimeout?.cancel()
    peer.connection.cancel()
    onPeerCount?(peers.values.filter(\.ready).count)
  }

  private func receiveQueryHeader(from id: UUID) {
    receiveExactly(4, from: id) { [weak self] header in
      guard let self else { return }
      do {
        let count = try SwarmbellAnalyticsWire.payloadLength(header: header)
        self.peers[id]?.readTimeout = Task { [weak self] in
          try? await Task.sleep(for: .seconds(15))
          guard !Task.isCancelled else { return }
          self?.remove(id)
        }
        self.receiveExactly(count, from: id) { [weak self] payload in
          guard let self else { return }
          self.peers[id]?.readTimeout?.cancel()
          self.peers[id]?.readTimeout = nil
          do {
            let query = try SwarmbellAnalyticsWire.decode(payload)
            guard self.peers[id]?.queryInFlight == false else {
              self.remove(id)
              return
            }
            self.peers[id]?.queryInFlight = true
            self.run(query, for: id)
            self.receiveQueryHeader(from: id)
          } catch { self.remove(id) }
        }
      } catch { self.remove(id) }
    }
  }

  private func receiveExactly(
    _ count: Int, from id: UUID, completion: @escaping @MainActor (Data) -> Void
  ) {
    guard let peer = peers[id], peer.ready else { return }
    peer.connection.receive(minimumIncompleteLength: count, maximumLength: count) {
      [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, self.peers[id] != nil else { return }
        guard error == nil, let data, data.count == count else {
          self.remove(id)
          return
        }
        completion(data)
        if complete { self.remove(id) }
      }
    }
  }

  private func run(_ query: SwarmbellAnalyticsQuery, for id: UUID) {
    guard runningQueries < 2 else {
      reply(.init(requestID: query.requestID, error: .busy), to: id)
      return
    }
    guard let onAnalyticsQuery else {
      reply(.init(requestID: query.requestID, error: .unavailable), to: id)
      return
    }
    runningQueries += 1
    peers[id]?.queryTask = Task { [weak self] in
      guard let self else { return }
      defer { self.runningQueries -= 1 }
      let response: SwarmbellAnalyticsResponse
      do {
        let report = try await onAnalyticsQuery(query)
        response = .init(requestID: query.requestID, reportData: report)
      } catch {
        // Never expose local filenames, database contents or underlying errors.
        response = .init(requestID: query.requestID, error: .unavailable)
      }
      guard !Task.isCancelled, self.peers[id] != nil else { return }
      self.peers[id]?.queryTask = nil
      self.reply(response, to: id)
    }
  }

  private func reply(_ response: SwarmbellAnalyticsResponse, to id: UUID) {
    do { send(try SwarmbellAnalyticsWire.responseFrame(response), to: id, response: true) } catch {
      remove(id)
    }
  }

  private func send(_ frame: Data, to id: UUID, response: Bool = false) {
    guard let peer = peers[id], peer.ready else { return }
    if peer.sending {
      // Bounded backpressure: retain only the newest unsent refresh per peer.
      if response {
        guard peer.pendingResponse == nil else {
          remove(id)
          return
        }
        peers[id]?.pendingResponse = frame
      } else {
        peers[id]?.pending = frame
      }
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
          if response { self.peers[id]?.queryInFlight = false }
          if let next = self.peers[id]?.pendingResponse {
            self.peers[id]?.pendingResponse = nil
            self.send(next, to: id, response: true)
          } else if let next = self.peers[id]?.pending {
            self.peers[id]?.pending = nil
            self.send(next, to: id)
          }
        }
      })
  }
}

@MainActor
public final class SwarmbellCompanionClient {
  public var onStatus: ((String) -> Void)?
  public var onEnvelope: ((SwarmbellCompanionEnvelope) -> Void)?
  public var onConnectionChanged: ((Bool) -> Void)?
  public var onAnalyticsResponse: ((SwarmbellAnalyticsResponse) -> Void)?
  public private(set) var supportsAnalyticsQueries = false
  private var analyticsPending = SwarmbellAnalyticsPendingRequest()
  private var analyticsTimeout: Task<Void, Never>?
  private let credential: SwarmbellPairingCredential
  private var browser: NWBrowser?
  private var connection: NWConnection?
  private var endpoint: NWEndpoint?
  private var retry: Task<Void, Never>?
  private var handshakeTimeout: Task<Void, Never>?
  private var discoveryTimeout: Task<Void, Never>?
  private var failureCount = 0

  public init(credential: SwarmbellPairingCredential) { self.credential = credential }

  /// Available only after a new Mac explicitly advertises the read-only capability.
  public func requestAnalytics(_ query: SwarmbellAnalyticsQuery) throws {
    guard let connection, supportsAnalyticsQueries else {
      throw SwarmbellCompanionError.analyticsUnavailable
    }
    let frame = try SwarmbellAnalyticsWire.encode(query)
    try analyticsPending.begin(query.requestID, supported: supportsAnalyticsQueries)
    analyticsTimeout = Task { [weak self, weak connection] in
      try? await Task.sleep(for: .seconds(45))
      guard !Task.isCancelled, let self, let connection, self.connection === connection,
        self.analyticsPending.requestID == query.requestID
      else { return }
      self.disconnected(connection)
    }
    connection.send(
      content: frame,
      completion: .contentProcessed { [weak self, weak connection] error in
        Task { @MainActor in
          guard error != nil, let self, let connection, self.connection === connection else {
            return
          }
          self.disconnected(connection)
        }
      })
  }

  private func clearAnalytics() {
    supportsAnalyticsQueries = false
    analyticsTimeout?.cancel()
    analyticsTimeout = nil
    let requestID = analyticsPending.requestID
    analyticsPending.reset()
    if let requestID { onAnalyticsResponse?(.init(requestID: requestID, error: .unavailable)) }
  }

  public func start() {
    guard browser == nil else { return }
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjour(type: swarmbellServiceType, domain: nil), using: parameters)
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
    clearAnalytics()
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
        "Your Mac has not been found yet. Keep Swarmbell sharing on, use the same Wi-Fi network, and check Local Network access in iPhone Settings."
      )
    }
  }

  private func connect(to endpoint: NWEndpoint) {
    guard browser != nil, connection == nil else { return }
    discoveryTimeout?.cancel()
    discoveryTimeout = nil
    let connection = NWConnection(to: endpoint, using: swarmbellParameters(credential))
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
          guard swarmbellUsesAuthenticatedPSK(connection) else {
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
    clearAnalytics()
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
        let length = try SwarmbellCompanionWire.payloadLength(header: header)
        self.receiveExactly(length, from: connection) { [weak self] payload in
          guard let self else { return }
          do {
            let envelope = try SwarmbellCompanionWire.decode(payload)
            if let response = envelope.analyticsResponse {
              try self.analyticsPending.consume(response)
              self.analyticsTimeout?.cancel()
              self.analyticsTimeout = nil
              self.onAnalyticsResponse?(response)
            } else {
              self.supportsAnalyticsQueries =
                envelope.capabilities?.contains(
                  SwarmbellAnalyticsWire.capability) == true
              self.onEnvelope?(envelope)
            }
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
