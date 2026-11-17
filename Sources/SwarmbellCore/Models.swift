import Foundation

public enum Harness: String, Codable, CaseIterable, Sendable {
  case codex, claudeCode, cursor
}

public enum AgentState: String, Codable, Sendable {
  case working, needsYou, idle, finished, failed, stopped, unknown
  public var isActive: Bool { self == .working || self == .needsYou }
}

public enum Freshness: String, Codable, Sendable { case current, stale, missing }
public enum SourceHealth: String, Codable, Sendable { case healthy, partial, unavailable }

/// Source-reported measurements. Token usage is not a subscription bill.
public struct AgentUsage: Codable, Equatable, Sendable {
  public enum Scope: String, Codable, Sendable { case session, lastTurn, contextWindow }
  public var inputTokens: Int64?
  public var cachedInputTokens: Int64?
  public var cacheCreationInputTokens: Int64?
  public var outputTokens: Int64?
  public var reasoningOutputTokens: Int64?
  public var totalTokens: Int64?
  public var model: String?
  public var reportedCostUSD: Double?
  public var source: String
  public var observedAt: Date
  public var scope: Scope

  public init(
    inputTokens: Int64? = nil, cachedInputTokens: Int64? = nil,
    cacheCreationInputTokens: Int64? = nil, outputTokens: Int64? = nil,
    reasoningOutputTokens: Int64? = nil, totalTokens: Int64? = nil,
    model: String? = nil, reportedCostUSD: Double? = nil,
    source: String, observedAt: Date, scope: Scope = .session
  ) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.cacheCreationInputTokens = cacheCreationInputTokens
    self.outputTokens = outputTokens
    self.reasoningOutputTokens = reasoningOutputTokens
    self.totalTokens = totalTokens
    self.model = model
    self.reportedCostUSD = reportedCostUSD
    self.source = source
    self.observedAt = observedAt
    self.scope = scope
  }
}

/// An action description, never an automatically executed shell command.
public struct Navigation: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case attachInTerminal, resumeInTerminal, copySessionID, openDesktopThread
  }
  public var kind: Kind
  public var executable: String?
  public var arguments: [String]
  public var explanation: String
  public var url: String?

  public init(
    kind: Kind, executable: String? = nil, arguments: [String] = [], explanation: String,
    url: String? = nil
  ) {
    self.kind = kind
    self.executable = executable
    self.arguments = arguments
    self.explanation = explanation
    self.url = url
  }
}

public struct AgentRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: String { "\(host):\(harness.rawValue):\(sessionID)" }
  public var host: String
  public var harness: Harness
  public var sessionID: String
  public var title: String
  public var workspace: String?
  public var state: AgentState
  public var reason: String?
  public var lastSeen: Date
  public var changedAt: Date
  public var freshness: Freshness
  public var isSubagent: Bool
  public var navigation: Navigation
  public var usage: AgentUsage?

  public init(
    host: String = "local", harness: Harness, sessionID: String, title: String,
    workspace: String? = nil, state: AgentState, reason: String? = nil,
    lastSeen: Date, changedAt: Date? = nil, freshness: Freshness = .current,
    isSubagent: Bool = false, navigation: Navigation? = nil, usage: AgentUsage? = nil
  ) {
    self.host = host
    self.harness = harness
    self.sessionID = sessionID
    self.title = title
    self.workspace = workspace
    self.state = state
    self.reason = reason
    self.lastSeen = lastSeen
    self.changedAt = changedAt ?? lastSeen
    self.freshness = freshness
    self.isSubagent = isSubagent
    self.usage = usage
    self.navigation =
      navigation
      ?? Navigation(
        kind: .copySessionID,
        explanation: "Exact original-thread activation has not been verified.")
  }
}

public struct ProviderStatus: Codable, Equatable, Sendable {
  public var harness: Harness
  public var health: SourceHealth
  public var message: String
  public var checkedAt: Date
  public var observesAttention: Bool
  public var scope: String

  public init(
    harness: Harness, health: SourceHealth, message: String, checkedAt: Date,
    observesAttention: Bool, scope: String = "local sessions"
  ) {
    self.harness = harness
    self.health = health
    self.message = message
    self.checkedAt = checkedAt
    self.observesAttention = observesAttention
    self.scope = scope
  }
}

public struct ProviderSnapshot: Sendable {
  public var status: ProviderStatus
  public var agents: [AgentRecord]
  public init(status: ProviderStatus, agents: [AgentRecord] = []) {
    self.status = status
    self.agents = agents
  }
  public static func unavailable(_ harness: Harness, at: Date, message: String) -> Self {
    .init(
      status: .init(
        harness: harness, health: .unavailable, message: message,
        checkedAt: at, observesAttention: false))
  }
}

public struct Counts: Codable, Equatable, Sendable {
  /// Active includes working and waiting on the user. Idle and finished do not count.
  public var active: Int
  public var needsYou: Int
  public var working: Int
  public var uncertain: Int
  public var incomplete: Bool
}

public struct MonitorSnapshot: Codable, Sendable {
  public var schemaVersion: Int = 1
  public var generatedAt: Date
  public var counts: Counts
  public var providers: [ProviderStatus]
  public var agents: [AgentRecord]
  public var refreshTiming: RefreshTiming? = nil
  public var historyError: String? = nil
}

public protocol AgentProvider: Sendable {
  var harness: Harness { get }
  func poll(at date: Date) async -> ProviderSnapshot
}

public struct SwarmbellError: Error, LocalizedError, Sendable {
  public var message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
