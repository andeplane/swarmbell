import Foundation

public struct ClaudeProvider: AgentProvider {
  public let harness = Harness.claudeCode
  private let executable: String?
  private let runner: any CommandRunning
  private let navigationResolver: ClaudeNavigationResolver?
  public init(
    executable: String? = Executables.find("claude"),
    runner: any CommandRunning = SystemCommandRunner(),
    navigationResolver: ClaudeNavigationResolver? = ClaudeNavigationResolver()
  ) {
    self.executable = executable
    self.runner = runner
    self.navigationResolver = navigationResolver
  }

  public func poll(at date: Date) async -> ProviderSnapshot {
    guard let executable else {
      return .unavailable(harness, at: date, message: "Claude CLI not found")
    }
    do {
      let result = try await runner.run(
        executable: executable, arguments: ["agents", "--json", "--all"], timeout: 3)
      guard result.exitCode == 0 else {
        throw SwarmbellError("claude agents --json failed; check CLI version and access")
      }
      var snapshot = try Self.decode(result.data, at: date, executable: executable)
      let sessions = try JSONDecoder().decode([Session].self, from: result.data)
      for index in snapshot.agents.indices {
        let id = snapshot.agents[index].sessionID
        let session = sessions.first { ($0.sessionId ?? $0.id) == id }
        if let destination = await navigationResolver?.resolveDestination(
          sessionID: id, processID: session?.pid)
        {
          snapshot.agents[index].navigation = destination.navigation
          if let title = destination.title { snapshot.agents[index].title = title }
        } else {
          snapshot.agents[index].navigation = .init(
            kind: .copySessionID,
            explanation:
              "The original conversation location is unavailable. You can copy its session ID.")
        }
      }
      return snapshot
    } catch {
      return .unavailable(
        harness, at: date, message: "Claude status unavailable: \(error.localizedDescription)")
    }
  }

  public static func decode(_ data: Data, at date: Date, executable: String = "claude") throws
    -> ProviderSnapshot
  {
    let rows = try JSONDecoder().decode([Session].self, from: data)
    var unknown = false
    var agents: [AgentRecord] = []
    for row in rows {
      if InternalSessions.isMemoryObserver(workspace: row.cwd) { continue }
      guard let id = row.sessionId ?? row.id, !id.isEmpty else {
        unknown = true
        continue
      }
      let state: AgentState
      // Overall job state takes priority over the process's momentary idle/busy status.
      switch row.state {
      case "blocked": state = .needsYou
      case "done": state = .finished
      case "failed": state = .failed
      case "stopped": state = .stopped
      case "working": state = row.status == "waiting" ? .needsYou : .working
      case nil:
        switch row.status {
        case "waiting": state = .needsYou
        case "busy": state = .working
        case "idle": state = .idle
        default: state = .unknown
        }
      default: state = .unknown
      }
      if state == .unknown { unknown = true }
      let navigation: Navigation
      if row.kind == "background", let jobID = row.id {
        navigation = .init(
          kind: .attachInTerminal, executable: executable, arguments: ["attach", jobID],
          explanation:
            "Attach in a terminal; focusing the original terminal is a separate integration.")
      } else {
        navigation = .init(
          kind: .resumeInTerminal, executable: executable, arguments: ["--resume", id],
          explanation:
            "Resume fallback only; do not resume while the original session is busy or blocked.")
      }
      agents.append(
        .init(
          harness: .claudeCode, sessionID: id, title: row.name ?? "Claude Code session",
          workspace: row.cwd, state: state,
          reason: state == .needsYou ? row.waitingFor ?? "Input needed" : nil,
          lastSeen: date, navigation: navigation))
    }
    return .init(
      status: .init(
        harness: .claudeCode, health: unknown ? .partial : .healthy,
        message: unknown
          ? "Some session states were not recognized" : "Live session status via Claude CLI",
        checkedAt: date, observesAttention: true), agents: agents)
  }

  private struct Session: Decodable {
    var id: String?
    var sessionId: String?
    var kind: String?
    var cwd: String?
    var name: String?
    var state: String?
    var status: String?
    var waitingFor: String?
    var pid: Int?
  }
}
