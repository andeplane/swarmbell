import CSQLite
import CoreFoundation
import Darwin
import Foundation

/// Passive, versioned observation of the installed desktop app's existing thread streams.
/// This private protocol was observed in Codex Electron 26.1103.60933. It never resumes
/// a thread, claims ownership, submits a turn, or answers an approval request.
public struct CodexDesktopProvider: AgentProvider {
  public let harness = Harness.codex
  private let observer: CodexIPCObserver
  private let fallback: (any AgentProvider)?

  public init(
    socketPath: String? = nil, stateDatabaseURL: URL? = nil,
    fallback: (any AgentProvider)? = nil
  ) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    observer = CodexIPCObserver(
      socketPath: socketPath ?? home.appendingPathComponent(".codex/ipc/ipc.sock").path,
      stateDatabaseURL: stateDatabaseURL ?? home.appendingPathComponent(".codex/state_5.sqlite"))
    self.fallback = fallback
  }

  public func poll(at date: Date) async -> ProviderSnapshot {
    let observed = await observer.snapshot(at: date)
    guard observed.status.health == .unavailable, let fallback else { return observed }
    let alternate = await fallback.poll(at: date)
    return alternate.status.health == .unavailable ? observed : alternate
  }

  /// Shipped desktop code constructs this URI; activation still needs UI acceptance testing.
  public static func threadURL(sessionID: String, host: String = "local") -> URL? {
    guard UUID(uuidString: sessionID) != nil else { return nil }
    var components = URLComponents()
    components.scheme = "codex"
    components.host = "threads"
    components.path = "/" + sessionID
    if host != "local" { components.queryItems = [.init(name: "hostId", value: host)] }
    return components.url
  }
}

/// Keeps only source/status/navigation metadata. Incoming conversation text is discarded
/// immediately after projection and is never retained in this object or persisted.
struct CodexIPCProjection {
  var id: String
  var host: String
  var title: String = "Codex session"
  var workspace: String?
  var runtimeType: String?
  var activeFlags: [String]?
  var isSubagent = false
  var requestKinds: [String] = []
  var revision: Int?
  var valid = false
  var lastEvent = Date()
  var ownerClientID: String?
  private var totalTokenUsage: [String: Int64]?
  private var usageObservedAt: Date?

  init(id: String, host: String) {
    self.id = id
    self.host = host
  }

  mutating func acceptSnapshot(_ state: [String: Any], revision: Int) -> Bool {
    guard state["id"] as? String == id, revision >= 0 else {
      valid = false
      return false
    }
    title = (state["title"] as? String).map { String($0.prefix(512)) } ?? "Codex session"
    workspace = (state["cwd"] as? String).map { String($0.prefix(4096)) }
    readStatus(state["threadRuntimeStatus"])
    requestKinds = Self.requestTypes(state["requests"])
    readTokenUsage(state["latestTokenUsageInfo"])
    isSubagent =
      state["parentThreadId"] as? String != nil
      || (state["source"] as? [String: Any])?["subAgent"] != nil
    self.revision = revision
    valid = true
    lastEvent = Date()
    return true
  }

  /// Returns false when a tracked change cannot be reconstructed safely; caller re-subscribes.
  mutating func acceptPatches(_ changes: [[String: Any]], base: Int, revision: Int) -> Bool {
    guard valid, self.revision == base, revision > base else {
      valid = false
      return false
    }
    for change in changes {
      guard let path = change["path"] as? [Any], let operation = change["op"] as? String,
        ["add", "remove", "replace"].contains(operation)
      else {
        valid = false
        return false
      }
      if path.isEmpty {
        guard let state = change["value"] as? [String: Any], operation != "remove",
          acceptSnapshot(state, revision: revision)
        else {
          valid = false
          return false
        }
        continue
      }
      guard let field = path[0] as? String else {
        valid = false
        return false
      }
      switch field {
      case "threadRuntimeStatus":
        guard path.count == 1 else {
          valid = false
          return false
        }
        readStatus(operation == "remove" ? nil : change["value"])
      case "title":
        guard path.count == 1 else {
          valid = false
          return false
        }
        title = (change["value"] as? String).map { String($0.prefix(512)) } ?? "Codex session"
      case "cwd":
        guard path.count == 1 else {
          valid = false
          return false
        }
        workspace =
          operation == "remove" ? nil : (change["value"] as? String).map { String($0.prefix(4096)) }
      case "requests":
        if path.count == 1 {
          requestKinds = Self.requestTypes(change["value"])
        } else {
          requestKinds = []
        }  // Runtime attention flags remain authoritative.
      case "latestTokenUsageInfo":
        applyTokenUsagePatch(path: path, operation: operation, value: change["value"])
      case "parentThreadId", "source":
        guard path.count == 1 else {
          valid = false
          return false
        }
        if field == "parentThreadId" {
          isSubagent = operation != "remove" && change["value"] as? String != nil
        } else {
          isSubagent = (change["value"] as? [String: Any])?["subAgent"] != nil
        }
      default: break  // Transcript/tool/history patches are deliberately not retained.
      }
    }
    self.revision = revision
    lastEvent = Date()
    return true
  }

  private mutating func readStatus(_ value: Any?) {
    let status = value as? [String: Any]
    runtimeType = status?["type"] as? String
    activeFlags = status?["activeFlags"] as? [String]
  }

  // Installed desktop code copies thread/tokenUsage/updated into this exact field.
  // Read cumulative totals only: last-turn/context counters are not session totals.
  private mutating func readTokenUsage(_ value: Any?) {
    readTokenTotals((value as? [String: Any])?["total"])
  }

  private static let requiredTokenFields = [
    "inputTokens", "cachedInputTokens", "outputTokens", "reasoningOutputTokens", "totalTokens",
  ]
  private static let optionalTokenFields = ["cacheWriteInputTokens"]

  private static func tokenCount(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      let count = Int64(number.stringValue), count >= 0
    else { return nil }
    return count
  }

  private mutating func readTokenTotals(_ value: Any?) {
    totalTokenUsage = nil
    usageObservedAt = nil
    guard let values = value as? [String: Any] else { return }
    var totals: [String: Int64] = [:]
    for field in Self.requiredTokenFields {
      guard let count = Self.tokenCount(values[field]) else { return }
      totals[field] = count
    }
    for field in Self.optionalTokenFields where values[field] != nil {
      guard let count = Self.tokenCount(values[field]) else { return }
      totals[field] = count
    }
    totalTokenUsage = totals
    usageObservedAt = Date()
  }

  private mutating func applyTokenUsagePatch(path: [Any], operation: String, value: Any?) {
    if path.count == 1 {
      readTokenUsage(operation == "remove" ? nil : value)
      return
    }
    guard path[1] as? String == "total" else { return }
    if path.count == 2 {
      readTokenTotals(operation == "remove" ? nil : value)
      return
    }
    guard path.count == 3, let field = path[2] as? String,
      (Self.requiredTokenFields + Self.optionalTokenFields).contains(field)
    else {
      // An unsupported nested mutation cannot produce fabricated token totals.
      totalTokenUsage = nil
      usageObservedAt = nil
      return
    }
    guard var totals = totalTokenUsage else { return }
    if operation == "remove", Self.optionalTokenFields.contains(field) {
      totals.removeValue(forKey: field)
    } else if operation != "remove", let count = Self.tokenCount(value) {
      totals[field] = count
    } else {
      totalTokenUsage = nil
      usageObservedAt = nil
      return
    }
    totalTokenUsage = totals
    usageObservedAt = Date()
  }

  private var measuredUsage: AgentUsage? {
    guard valid, let totals = totalTokenUsage, let observedAt = usageObservedAt else { return nil }
    return .init(
      inputTokens: totals["inputTokens"], cachedInputTokens: totals["cachedInputTokens"],
      cacheCreationInputTokens: totals["cacheWriteInputTokens"],
      outputTokens: totals["outputTokens"],
      reasoningOutputTokens: totals["reasoningOutputTokens"], totalTokens: totals["totalTokens"],
      source: "Codex desktop thread/tokenUsage/updated cumulative total", observedAt: observedAt,
      scope: .session)
  }

  private static func requestTypes(_ value: Any?) -> [String] {
    (value as? [[String: Any]] ?? []).prefix(32).compactMap {
      ($0["type"] as? String ?? $0["method"] as? String).map { String($0.prefix(128)) }
    }
  }

  mutating func expireQuietActivity(at date: Date) -> Bool {
    guard valid, record(at: date).state.isActive, date.timeIntervalSince(lastEvent) > 60 else {
      return false
    }
    valid = false
    return true
  }

  func record(at date: Date) -> AgentRecord {
    let state: AgentState
    let reason: String?
    if !valid {
      state = .unknown
      reason = "Desktop state is resynchronizing"
    } else {
      switch runtimeType {
      case "active":
        if let flags = activeFlags {
          if flags.contains("waitingOnApproval") {
            state = .needsYou
            reason = "Approval required"
          } else if flags.contains("waitingOnUserInput") {
            state = .needsYou
            reason = "Question for you"
          } else if flags.isEmpty {
            state = .working
            reason = nil
          } else {
            state = .unknown
            reason = "Unrecognized desktop runtime flags"
          }
        } else {
          state = .unknown
          reason = "Desktop runtime flags missing"
        }
      case "idle":
        state = .idle
        reason = nil
      case "systemError":
        state = .failed
        reason = "Codex runtime error"
      default:
        state = .unknown
        reason = "Desktop runtime state unavailable"
      }
    }
    let navigation = CodexDesktopProvider.threadURL(sessionID: id, host: host).map {
      Navigation(
        kind: .openDesktopThread, explanation: "Open the observed Codex desktop conversation.",
        url: $0.absoluteString)
    }
    return .init(
      host: host, harness: .codex, sessionID: id, title: title, workspace: workspace,
      state: state, reason: reason, lastSeen: date, isSubagent: isSubagent, navigation: navigation,
      usage: measuredUsage)
  }
}

/// All mutable state is confined to the utility queue. Continuous draining prevents a
/// quiet five-second polling interval from back-pressuring the desktop app's stream.
private final class CodexIPCObserver: @unchecked Sendable {
  private let queue = DispatchQueue(label: "local.agentbeacon.codex-ipc", qos: .utility)
  private let socketPath: String
  private let stateDatabaseURL: URL
  private var descriptor: Int32 = -1
  private var readSource: DispatchSourceRead?
  private var clientID: String?
  private var connectedAt = Date.distantPast
  private var incoming = Data()
  private var outgoing = Data()
  private var projections: [String: CodexIPCProjection] = [:]
  private var subscribed = Set<String>()
  private var lastResyncAttempt: [String: Date] = [:]
  private var candidateQueue: [(String, String)] = []
  private var subscriptionScheduled = false
  private var lastError = "Desktop observer has not connected"
  private var lastAttempt = Date.distantPast
  private let maximumFrameBytes = 32 * 1024 * 1024

  init(socketPath: String, stateDatabaseURL: URL) {
    self.socketPath = socketPath
    self.stateDatabaseURL = stateDatabaseURL
  }

  deinit {
    readSource?.cancel()
    if descriptor >= 0 { Darwin.close(descriptor) }
  }

  func snapshot(at date: Date) async -> ProviderSnapshot {
    await withCheckedContinuation { continuation in
      queue.async {
        if self.descriptor < 0, Date().timeIntervalSince(self.lastAttempt) >= 3 { self.connect() }
        if self.clientID == nil, self.descriptor >= 0,
          Date().timeIntervalSince(self.connectedAt) > 3
        {
          self.disconnect("Desktop observer initialization timed out")
        }
        guard self.descriptor >= 0, self.clientID != nil else {
          continuation.resume(returning: .unavailable(.codex, at: date, message: self.lastError))
          return
        }
        // The broker staying alive does not prove that a particular renderer still
        // owns a quiet thread. Require renewed runtime evidence for old active states.
        for (key, var projection) in self.projections {
          let age = Date().timeIntervalSince(projection.lastEvent)
          if projection.record(at: date).state.isActive && age > 45 {
            self.requestResync(id: projection.id, host: projection.host)
          }
          if projection.expireQuietActivity(at: Date()) { self.projections[key] = projection }
          if !projection.valid && age > 30 {
            self.requestResync(id: projection.id, host: projection.host)
          }
        }
        let records = self.projections.values.map { $0.record(at: date) }
        continuation.resume(
          returning: .init(
            status: .init(
              harness: .codex, health: .partial,
              message:
                "Live desktop streams (private protocol 26.1103.60933); recent 64 candidates and announced threads only",
              checkedAt: date, observesAttention: true,
              scope:
                "already-owned desktop conversations; independent CLI/cloud processes may be outside scope"
            ), agents: records))
      }
    }
  }

  private func connect() {
    lastAttempt = Date()
    guard FileManager.default.fileExists(atPath: socketPath) else {
      lastError = "Codex desktop IPC socket is unavailable"
      return
    }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      lastError = "Cannot create desktop observer socket"
      return
    }
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(socketPath.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      Darwin.close(fd)
      lastError = "Desktop observer socket path is too long"
      return
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result != 0 {
      var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
      guard errno == EINPROGRESS, Darwin.poll(&pending, 1, 250) > 0 else {
        Darwin.close(fd)
        lastError = "Codex desktop IPC is not accepting connections"
        return
      }
      var socketError: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0
      else {
        Darwin.close(fd)
        lastError = "Codex desktop IPC connection failed"
        return
      }
    }
    descriptor = fd
    connectedAt = Date()
    clientID = nil
    incoming.removeAll(keepingCapacity: false)
    outgoing.removeAll(keepingCapacity: false)
    subscribed.removeAll()
    lastResyncAttempt.removeAll()
    candidateQueue.removeAll()
    subscriptionScheduled = false
    projections.removeAll()
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.readAvailable() }
    readSource = source
    source.resume()
    send([
      "type": "request", "requestId": UUID().uuidString, "sourceClientId": "initializing-client",
      "version": 0, "method": "initialize", "params": ["clientType": "agent-beacon-observer"],
      "timeoutMs": 2000,
    ])
  }

  private func send(_ value: [String: Any]) {
    guard descriptor >= 0, let payload = try? JSONSerialization.data(withJSONObject: value),
      payload.count <= 65_536
    else { return }
    var length = UInt32(payload.count).littleEndian
    outgoing.append(withUnsafeBytes(of: &length) { Data($0) })
    outgoing.append(payload)
    guard outgoing.count <= 262_144 else {
      disconnect("Desktop observer outbound buffer exceeded limit")
      return
    }
    flushWrites()
  }

  private func flushWrites() {
    guard descriptor >= 0 else { return }
    while !outgoing.isEmpty {
      let count = outgoing.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      if count > 0 {
        outgoing.removeFirst(count)
      } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in self?.flushWrites()
        }
        return
      } else if count < 0 && errno == EINTR {
        continue
      } else {
        disconnect("Codex desktop observer connection closed")
        return
      }
    }
  }

  private func readAvailable() {
    guard descriptor >= 0 else { return }
    var bytes = [UInt8](repeating: 0, count: 65_536)
    for _ in 0..<128 {
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      if count > 0 {
        incoming.append(contentsOf: bytes.prefix(count))
        guard incoming.count <= maximumFrameBytes + 65_536 else {
          disconnect("Desktop stream exceeded the bounded input buffer")
          return
        }
      } else if count == 0 {
        disconnect("Codex desktop observer disconnected")
        return
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        break
      } else if errno == EINTR {
        continue
      } else {
        disconnect("Cannot read Codex desktop stream")
        return
      }
    }
    let started = ProcessInfo.processInfo.systemUptime
    while incoming.count >= 4 {
      let length = incoming.prefix(4).enumerated().reduce(UInt32(0)) {
        $0 | UInt32($1.element) << ($1.offset * 8)
      }
      guard length > 0, length <= maximumFrameBytes else {
        disconnect("Desktop stream frame is unsupported or exceeds 32 MiB")
        return
      }
      let end = 4 + Int(length)
      guard incoming.count >= end else { return }
      let startIndex = incoming.startIndex
      let frame = Data(incoming[(startIndex + 4)..<(startIndex + end)])
      incoming.removeFirst(end)
      let accepted = autoreleasepool { () -> Bool in
        guard let value = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
          return false
        }
        handle(value)
        return true
      }
      guard accepted else {
        disconnect("Desktop stream returned invalid JSON")
        return
      }
      if ProcessInfo.processInfo.systemUptime - started > 0.1 {
        queue.async { [weak self] in self?.readAvailable() }
        return
      }
    }
  }

  private func handle(_ value: [String: Any]) {
    switch value["type"] as? String {
    case "response":
      if value["method"] as? String == "initialize", value["resultType"] as? String == "success",
        let id = (value["result"] as? [String: Any])?["clientId"] as? String
      {
        clientID = id
        for id in candidateThreadIDs() { enqueueSubscription(id: id, host: "local") }
        scheduleSubscription()
      }
    case "client-discovery-request":
      // Never become a handler for app requests, particularly execution or approval.
      if let id = value["requestId"] as? String {
        send([
          "type": "client-discovery-response", "requestId": id, "response": ["canHandle": false],
        ])
      }
    case "broadcast":
      guard let params = value["params"] as? [String: Any] else { return }
      switch value["method"] as? String {
      case "client-status-changed":
        if params["status"] as? String == "disconnected", let owner = params["clientId"] as? String
        {
          for (key, var projection) in projections where projection.ownerClientID == owner {
            projection.valid = false
            projections[key] = projection
          }
        }
      case "thread-archived":
        if let id = params["conversationId"] as? String ?? params["threadId"] as? String {
          for (key, var projection) in projections where projection.id == id {
            projection.valid = false
            projections[key] = projection
          }
        }
      case "thread-stream-following-changed":
        if params["following"] as? Bool == true, let id = params["conversationId"] as? String,
          let host = params["hostId"] as? String
        {
          enqueueSubscription(id: id, host: host)
        }
      case "thread-stream-state-changed":
        guard value["version"] as? Int == 11 else {
          disconnect("Codex desktop stream protocol version changed")
          return
        }
        guard let id = params["conversationId"] as? String, let host = params["hostId"] as? String,
          let change = params["change"] as? [String: Any], let revision = change["revision"] as? Int
        else { return }
        let key = host + ":" + id
        guard subscribed.contains(key) else { return }
        var projection = projections[key] ?? .init(id: id, host: host)
        if let sourceClientID = value["sourceClientId"] as? String {
          projection.ownerClientID = sourceClientID
        }
        let accepted: Bool
        if change["type"] as? String == "snapshot",
          let state = change["conversationState"] as? [String: Any]
        {
          accepted = projection.acceptSnapshot(state, revision: revision)
        } else if change["type"] as? String == "patches", let base = change["baseRevision"] as? Int,
          let patches = change["patches"] as? [[String: Any]]
        {
          if let current = projection.revision, revision <= current { return }
          accepted = projection.acceptPatches(patches, base: base, revision: revision)
        } else {
          accepted = false
          projection.valid = false
        }
        projections[key] = projection
        if projections.count > 256,
          let oldest = projections.min(by: { $0.value.lastEvent < $1.value.lastEvent })?.key
        {
          projections.removeValue(forKey: oldest)
          lastResyncAttempt.removeValue(forKey: oldest)
        }
        if !accepted { requestResync(id: id, host: host) }
      default: break
      }
    default: break
    }
  }

  private func enqueueSubscription(id: String, host: String) {
    guard UUID(uuidString: id) != nil, host.utf8.count <= 256,
      subscribed.count + candidateQueue.count < 256, !subscribed.contains(host + ":" + id),
      !candidateQueue.contains(where: { $0.0 == id && $0.1 == host })
    else { return }
    candidateQueue.append((id, host))
    scheduleSubscription()
  }

  private func scheduleSubscription() {
    guard !subscriptionScheduled, clientID != nil, !candidateQueue.isEmpty else { return }
    subscriptionScheduled = true
    queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
      guard let self else { return }
      self.subscriptionScheduled = false
      guard self.descriptor >= 0, !self.candidateQueue.isEmpty else { return }
      let (id, host) = self.candidateQueue.removeFirst()
      self.subscribed.insert(host + ":" + id)
      self.subscribe(id: id, host: host)
      self.scheduleSubscription()
    }
  }

  private func requestResync(id: String, host: String) {
    let key = host + ":" + id
    let now = Date()
    guard now.timeIntervalSince(lastResyncAttempt[key] ?? .distantPast) >= 30,
      candidateQueue.count < 256, !candidateQueue.contains(where: { $0.0 == id && $0.1 == host })
    else { return }
    lastResyncAttempt[key] = now
    candidateQueue.append((id, host))
    scheduleSubscription()
  }

  private func subscribe(id: String, host: String) {
    guard let clientID else { return }
    send([
      "type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
      "sourceClientId": clientID,
      "params": ["conversationId": id, "hostId": host, "following": true],
    ])
  }

  private func candidateThreadIDs() -> [String] {
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        stateDatabaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        == SQLITE_OK
    else {
      if let database { sqlite3_close(database) }
      return []
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 100)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT id FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT 64", -1,
        &statement, nil) == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var ids: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let value = sqlite3_column_text(statement, 0) {
        let id = String(cString: value)
        if UUID(uuidString: id) != nil { ids.append(id) }
      }
    }
    return ids
  }

  private func disconnect(_ reason: String) {
    readSource?.cancel()
    readSource = nil
    if descriptor >= 0 { Darwin.close(descriptor) }
    descriptor = -1
    clientID = nil
    incoming.removeAll(keepingCapacity: false)
    outgoing.removeAll(keepingCapacity: false)
    candidateQueue.removeAll()
    lastError = reason
  }
}
