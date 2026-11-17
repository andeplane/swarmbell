import Foundation

/// Only this allowlist is persisted. Prompts, reasoning, transcripts, tool arguments,
/// tool results, user email, and environment variables are deliberately not stored.
public struct CursorEvent: Codable, Sendable {
  public var eventID: String
  public var receivedAt: Date
  public var conversationID: String
  public var generationID: String?
  public var name: String
  public var workspace: String?
  public var status: String?

  public init(
    eventID: String = UUID().uuidString, receivedAt: Date, conversationID: String,
    generationID: String? = nil, name: String, workspace: String? = nil, status: String? = nil
  ) {
    self.eventID = eventID
    self.receivedAt = receivedAt
    self.conversationID = conversationID
    self.generationID = generationID
    self.name = name
    self.workspace = workspace
    self.status = status
  }

  public static func fromHook(_ data: Data, at date: Date = Date()) throws -> Self {
    guard data.count <= 1_048_576,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let name = object["hook_event_name"] as? String,
      observedHooks.contains(name),
      let id = object["conversation_id"] as? String ?? object["session_id"] as? String,
      !id.isEmpty, id.utf8.count <= 256
    else { throw BeaconError("Unsupported Cursor hook payload") }
    return .init(
      receivedAt: date, conversationID: id,
      generationID: object["generation_id"] as? String, name: name,
      workspace: (object["workspace_roots"] as? [String])?.first,
      status: object["status"] as? String)
  }

  // No permission hooks: an observer must never supply an allow/deny decision.
  public static let observedHooks = [
    "sessionStart", "sessionEnd", "beforeSubmitPrompt", "afterAgentResponse",
    "afterAgentThought", "stop",
  ]
}

public enum CursorSpool {
  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/AgentBeacon/cursor-events", isDirectory: true)
  }

  public static func write(_ event: CursorEvent, to directory: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let data = try encoder.encode(event)
    // A separate atomic file per event avoids interleaving concurrent hook writes.
    let file = directory.appendingPathComponent(UUID().uuidString + ".json")
    // Collection continues while the session is locked; the private directory and
    // 0600 event permissions control access without lock-dependent file protection.
    try data.write(to: file, options: [.atomic])
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  public static func configuration(executable: String, directory: URL? = nil) throws -> Data {
    guard executable.hasPrefix("/"), !executable.contains("\n") else {
      throw BeaconError("The hook executable must be an absolute path")
    }
    func quote(_ value: String) -> String {
      "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    var command = quote(executable) + " --cursor-hook"
    if let directory { command += " --cursor-events " + quote(directory.path) }
    let hooks = Dictionary(
      uniqueKeysWithValues: CursorEvent.observedHooks.map {
        ($0, [["command": command + " --hook-event " + quote($0)]])
      })
    return try JSONSerialization.data(
      withJSONObject: ["version": 1, "hooks": hooks], options: [.prettyPrinted, .sortedKeys])
  }
}

public struct CursorProvider: AgentProvider {
  public let harness = Harness.cursor
  private let directory: URL
  public init(directory: URL = CursorSpool.defaultDirectory) { self.directory = directory }

  public func poll(at date: Date) async -> ProviderSnapshot {
    let directory = directory
    return await Task.detached(priority: .utility) {
      let fm = FileManager.default
      guard fm.fileExists(atPath: directory.path) else {
        return .unavailable(
          .cursor, at: date,
          message:
            "Cursor observer has not received an event; hooks are not installed by this prototype")
      }
      do {
        let files = try fm.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )
        .filter { $0.pathExtension == "json" }
        guard files.count <= 20_000 else {
          throw BeaconError("Cursor spool exceeds 20,000 events; archive it before continuing")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var events: [CursorEvent] = []
        var malformed = 0
        for file in files {
          do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16_384 else {
              malformed += 1
              continue
            }
            let event = try decoder.decode(CursorEvent.self, from: Data(contentsOf: file))
            // A future clock jump must not keep a session alive indefinitely.
            guard event.receivedAt <= date.addingTimeInterval(5) else {
              malformed += 1
              continue
            }
            if date.timeIntervalSince(event.receivedAt) <= 86_400 { events.append(event) }
          } catch { malformed += 1 }
        }
        if events.isEmpty {
          let ready = fm.fileExists(
            atPath: directory.appendingPathComponent(CursorHookInstaller.markerFileName).path)
          return .unavailable(
            .cursor, at: date,
            message: ready
              ? "Cursor observer configured; waiting for its first lifecycle event"
              : "No Cursor lifecycle events received; install the observer in Settings")
        }
        return Self.reduce(events, at: date, malformed: malformed)
      } catch {
        return .unavailable(
          .cursor, at: date, message: "Cursor observer unavailable: \(error.localizedDescription)")
      }
    }.value
  }

  public static func reduce(_ events: [CursorEvent], at date: Date, malformed: Int = 0)
    -> ProviderSnapshot
  {
    struct State {
      var record: AgentRecord
      var generation: String?
    }
    var sessions: [String: State] = [:]
    var seen = Set<String>()
    for event in events.sorted(by: {
      $0.receivedAt == $1.receivedAt ? $0.eventID < $1.eventID : $0.receivedAt < $1.receivedAt
    }) {
      guard seen.insert(event.eventID).inserted, CursorEvent.observedHooks.contains(event.name)
      else { continue }
      var current =
        sessions[event.conversationID]
        ?? State(
          record: .init(
            harness: .cursor,
            sessionID: event.conversationID,
            title: "Cursor session \(event.conversationID.prefix(8))",
            workspace: event.workspace, state: .unknown, lastSeen: event.receivedAt),
          generation: nil)
      // A late stop from turn A must not overwrite the currently running turn B.
      if event.name != "beforeSubmitPrompt", let generation = event.generationID,
        let active = current.generation, generation != active
      {
        continue
      }
      let state: AgentState
      switch event.name {
      case "beforeSubmitPrompt":
        state = .working
        current.generation = event.generationID
      case "afterAgentThought", "afterAgentResponse":
        // A response may be followed by more tools; only stop establishes completion.
        state = current.record.state == .unknown ? .unknown : current.record.state
      case "stop":
        switch event.status {
        case "completed": state = .finished
        case "aborted": state = .stopped
        case "error": state = .failed
        default: state = .unknown
        }
      case "sessionEnd": state = current.record.state == .finished ? .finished : .unknown
      default: state = current.record.state
      }
      if current.record.state != state { current.record.changedAt = event.receivedAt }
      current.record.state = state
      current.record.lastSeen = event.receivedAt
      current.record.workspace = event.workspace ?? current.record.workspace
      sessions[event.conversationID] = current
    }
    let records = sessions.values.map { value -> AgentRecord in
      var row = value.record
      if row.state.isActive && date.timeIntervalSince(row.lastSeen) > 120 {
        row.freshness = .stale
        row.reason = "No recent Cursor event; current activity is uncertain"
      }
      return row
    }
    return .init(
      status: .init(
        harness: .cursor, health: .partial,
        message:
          "Lifecycle events only; approval/question detection and existing-session discovery are unverified"
          + (malformed > 0 ? "; \(malformed) unreadable events" : ""),
        checkedAt: date, observesAttention: false, scope: "local sessions emitting configured hooks"
      ), agents: records)
  }
}
