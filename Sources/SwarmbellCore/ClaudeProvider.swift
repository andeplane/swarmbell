import Foundation

public struct ClaudeProvider: AgentProvider {
  public let harness = Harness.claudeCode
  private let executable: String?
  private let runner: any CommandRunning
  private let navigationResolver: ClaudeNavigationResolver?
  private let letsRegistry: LetsClaudeRegistry
  public init(
    executable: String? = Executables.find("claude"),
    runner: any CommandRunning = SystemCommandRunner(),
    navigationResolver: ClaudeNavigationResolver? = ClaudeNavigationResolver()
  ) {
    self.init(
      executable: executable, runner: runner, navigationResolver: navigationResolver,
      letsRegistry: .init())
  }

  init(
    executable: String?, runner: any CommandRunning, navigationResolver: ClaudeNavigationResolver?,
    letsRegistry: LetsClaudeRegistry
  ) {
    self.executable = executable
    self.runner = runner
    self.navigationResolver = navigationResolver
    self.letsRegistry = letsRegistry
  }

  public func poll(at date: Date) async -> ProviderSnapshot {
    var snapshot = await pollCLI(at: date)
    let lets = letsRegistry.read()
    guard !lets.sessions.isEmpty || lets.incomplete else { return snapshot }
    snapshot.status.scope = "local Claude CLI and Lets sessions"
    snapshot.status.observesAttention = snapshot.status.observesAttention || !lets.sessions.isEmpty
    if snapshot.status.health == .unavailable {
      snapshot.status.health = .partial
      if !lets.sessions.isEmpty { snapshot.status.message += ". Lets sessions are available." }
    } else if snapshot.status.health == .healthy {
      snapshot.status.message = "Live session status via Claude CLI and Lets"
    }
    var seen = Set(snapshot.agents.map { $0.sessionID.lowercased() })
    var unknown = false
    for session in lets.sessions {
      guard !InternalSessions.isMemoryObserver(workspace: session.cwd),
        var row = Self.record(session, at: date, executable: "claude"),
        seen.insert(row.sessionID.lowercased()).inserted
      else { continue }
      row.navigation = .init(
        kind: .copySessionID,
        explanation: "Copy the Claude session ID. Open the original conversation in Lets.")
      unknown = unknown || row.state == .unknown
      snapshot.agents.append(row)
    }
    if unknown {
      snapshot.status.health = .partial
      snapshot.status.message += ". Some Lets session states were not recognized."
    }
    if lets.incomplete {
      snapshot.status.health = .partial
      snapshot.status.message += "; Lets registry coverage incomplete"
    }
    return snapshot
  }

  private func pollCLI(at date: Date) async -> ProviderSnapshot {
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
      guard let agent = record(row, at: date, executable: executable) else {
        unknown = true
        continue
      }
      if agent.state == .unknown { unknown = true }
      agents.append(agent)
    }
    return .init(
      status: .init(
        harness: .claudeCode, health: unknown ? .partial : .healthy,
        message: unknown
          ? "Some session states were not recognized" : "Live session status via Claude CLI",
        checkedAt: date, observesAttention: true), agents: agents)
  }

  private static func record(_ row: Session, at date: Date, executable: String) -> AgentRecord? {
    guard let id = row.sessionId ?? row.id, !id.isEmpty else { return nil }
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
    return .init(
      harness: .claudeCode, sessionID: id, title: row.name ?? "Claude Code session",
      workspace: row.cwd, state: state,
      reason: state == .needsYou ? row.waitingFor ?? "Input needed" : nil,
      lastSeen: date, navigation: navigation)
  }

  struct Session: Decodable, Sendable {
    var id: String?
    var sessionId: String?
    var kind: String?
    var cwd: String?
    var name: String?
    var state: String?
    var status: String?
    var waitingFor: String?
    var pid: Int?
    var procStart: String?
    var pidDomain: String?
    var entrypoint: String?
  }
}
