import Foundation

public protocol CodexReading: Sendable {
  func loadedThreads() async throws -> Data
}

/// Connects only to an already-running daemon. It never starts a new app-server,
/// resumes a thread, changes a setting, or approves a request.
public struct CodexProxyReader: CodexReading {
  public let executable: String
  public let socketPath: String
  public init(executable: String, socketPath: String) {
    self.executable = executable
    self.socketPath = socketPath
  }

  public func loadedThreads() async throws -> Data {
    let executable = executable
    let socketPath = socketPath
    return try await Task.detached(priority: .utility) {
      guard FileManager.default.fileExists(atPath: socketPath) else {
        throw BeaconError(
          "No running shared app-server socket; desktop process coverage is unverified")
      }
      let process = try BoundedProcess(
        executable: executable,
        arguments: ["app-server", "proxy", "--sock", socketPath], timeout: 3)
      defer { process.close() }
      try process.send([
        "id": 1, "method": "initialize",
        "params": [
          "clientInfo": [
            "name": "agent_beacon", "title": "Agent Beacon", "version": "0.1.0",
          ]
        ],
      ])
      _ = try process.response(id: 1)
      try process.send(["method": "initialized", "params": [:]])
      try process.send(["id": 2, "method": "thread/loaded/list"])
      let result = try process.response(id: 2)
      guard let ids = result["data"] as? [String], ids.count <= 256 else {
        throw BeaconError("Unexpected loaded-thread response or more than 256 loaded threads")
      }
      var threads: [[String: Any]] = []
      for (index, id) in ids.enumerated() {
        let requestID = index + 3
        try process.send(["id": requestID, "method": "thread/read", "params": ["threadId": id]])
        let response = try process.response(id: requestID)
        guard let thread = response["thread"] as? [String: Any] else {
          throw BeaconError("Missing thread in app-server response")
        }
        threads.append(thread)
      }
      return try JSONSerialization.data(withJSONObject: threads)
    }.value
  }
}

public struct CodexProvider: AgentProvider {
  public let harness = Harness.codex
  private let reader: (any CodexReading)?
  public init(reader: (any CodexReading)?) { self.reader = reader }
  public static func local(executableOverride: String? = nil, socketOverride: String? = nil) -> Self
  {
    guard let executable = Executables.find("codex", override: executableOverride) else {
      return .init(reader: nil)
    }
    let socket =
      socketOverride
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/app-server-control/app-server-control.sock").path
    return .init(reader: CodexProxyReader(executable: executable, socketPath: socket))
  }

  public func poll(at date: Date) async -> ProviderSnapshot {
    guard let reader else { return .unavailable(harness, at: date, message: "Codex CLI not found") }
    do { return try Self.decode(try await reader.loadedThreads(), at: date) } catch {
      return .unavailable(
        harness, at: date, message: "Codex status unavailable: \(error.localizedDescription)")
    }
  }

  public static func decode(_ data: Data, at date: Date) throws -> ProviderSnapshot {
    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw BeaconError("Invalid Codex thread list")
    }
    var agents: [AgentRecord] = []
    for row in rows {
      guard let id = row["id"] as? String, !id.isEmpty else {
        throw BeaconError("Codex thread has no ID")
      }
      let status = row["status"] as? [String: Any] ?? [:]
      let flags = status["activeFlags"] as? [String] ?? []
      let state: AgentState
      let reason: String?
      switch status["type"] as? String {
      case "active":
        if status["activeFlags"] as? [String] == nil {
          state = .unknown
          reason = "Missing or invalid Codex activity flags"
        } else if flags.contains("waitingOnApproval") {
          state = .needsYou
          reason = "Approval required"
        } else if flags.contains("waitingOnUserInput") {
          state = .needsYou
          reason = "Question for you"
        } else if !flags.isEmpty {
          state = .unknown
          reason = "Unrecognized Codex activity flag"
        } else {
          state = .working
          reason = nil
        }
      case "idle":
        state = .idle
        reason = nil
      case "notLoaded":
        state = .unknown
        reason = "Thread unloaded during the refresh"
      case "systemError":
        state = .failed
        reason = "Codex runtime error"
      default:
        state = .unknown
        reason = "Unrecognized Codex runtime state"
      }
      let source = row["source"]
      let child =
        (source as? String)?.lowercased().hasPrefix("subagent") == true
        || (source as? [String: Any])?["subAgent"] != nil
      agents.append(
        .init(
          harness: .codex, sessionID: id, title: row["name"] as? String ?? "Codex session",
          workspace: row["cwd"] as? String, state: state, reason: reason, lastSeen: date,
          isSubagent: child))
    }
    return .init(
      status: .init(
        harness: .codex, health: .partial,
        message:
          "Connected daemon only; independent desktop/CLI processes may be outside its scope",
        checkedAt: date, observesAttention: true, scope: "loaded threads on the connected daemon"),
      agents: agents)
  }
}
