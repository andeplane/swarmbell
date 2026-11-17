import Foundation

/// Providers may run concurrently; publication is atomic and refreshes never overlap.
public actor AgentMonitor {
  private let providers: [any AgentProvider]
  private let countSubagents: Bool
  private let history: HistoryStore?
  private var agents: [String: AgentRecord] = [:]
  private var statuses: [Harness: ProviderStatus] = [:]
  private var refreshing = false
  private var generatedAt = Date.distantPast
  private var refreshTiming: RefreshTiming?
  private var historyError: String?

  public init(
    providers: [any AgentProvider], countSubagents: Bool = false, history: HistoryStore? = nil
  ) {
    self.providers = providers
    self.countSubagents = countSubagents
    self.history = history
  }

  public func refresh(at date: Date = Date()) async -> MonitorSnapshot {
    guard !refreshing else { return snapshot() }
    refreshing = true
    defer { refreshing = false }
    let started = ContinuousClock.now
    let results = await withTaskGroup(of: TimedSnapshot.self, returning: [TimedSnapshot].self) {
      group in
      for provider in providers {
        group.addTask {
          let start = ContinuousClock.now
          let result = await provider.poll(at: date)
          return TimedSnapshot(
            snapshot: result,
            timing: .init(
              harness: provider.harness,
              durationMilliseconds: Self.milliseconds(start.duration(to: .now))))
        }
      }
      var results: [TimedSnapshot] = []
      for await result in group { results.append(result) }
      return results
    }
    for result in results { apply(result.snapshot, at: date) }
    generatedAt = date
    let timing = RefreshTiming(
      startedAt: date,
      durationMilliseconds: Self.milliseconds(started.duration(to: .now)),
      providers: results.map(\.timing).sorted { $0.harness.rawValue < $1.harness.rawValue })
    refreshTiming = timing
    historyError = nil
    if let history {
      do { try await history.record(snapshot(), timing: timing) } catch {
        historyError = "History could not be saved: \(error.localizedDescription)"
      }
    }
    return snapshot()
  }

  private struct TimedSnapshot: Sendable {
    var snapshot: ProviderSnapshot
    var timing: ProviderRefreshTiming
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
  }

  private func apply(_ result: ProviderSnapshot, at date: Date) {
    let harness = result.status.harness
    statuses[harness] = result.status
    if result.status.health == .unavailable {
      // Keep the last evidence, but never count it as current live work.
      for (id, var agent) in agents where agent.harness == harness {
        agent.freshness = .stale
        agents[id] = agent
      }
      return
    }
    let previous = agents.filter { $0.value.harness == harness }
    let incomingIDs = Set(result.agents.map(\.id))
    for (id, var old) in previous where !incomingIDs.contains(id) {
      if old.state.isActive && date.timeIntervalSince(old.lastSeen) < 300 {
        old.freshness = .missing
        agents[id] = old
      } else {
        agents.removeValue(forKey: id)
      }
    }
    for var agent in result.agents {
      if let old = previous[agent.id], old.state == agent.state, old.reason == agent.reason {
        agent.changedAt = old.changedAt
      }
      agents[agent.id] = agent
    }
  }

  public func snapshot() -> MonitorSnapshot {
    let rows = agents.values.filter {
      !InternalSessions.isMemoryObserver(workspace: $0.workspace)
    }.sorted {
      let lhs = Self.rank($0)
      let rhs = Self.rank($1)
      if lhs != rhs { return lhs < rhs }
      if $0.changedAt != $1.changedAt { return $0.changedAt > $1.changedAt }
      return $0.id < $1.id
    }
    let included = rows.filter { countSubagents || !$0.isSubagent }
    let current = included.filter { $0.freshness == .current }
    let providerStates = statuses.values.sorted { $0.harness.rawValue < $1.harness.rawValue }
    let uncertain = included.filter { $0.freshness != .current || $0.state == .unknown }.count
    let counts = Counts(
      active: current.filter { $0.state.isActive }.count,
      needsYou: current.filter { $0.state == .needsYou }.count,
      working: current.filter { $0.state == .working }.count,
      uncertain: uncertain,
      incomplete: uncertain > 0 || providerStates.count != providers.count
        || providerStates.contains { $0.health != .healthy || !$0.observesAttention })
    return .init(
      generatedAt: generatedAt, counts: counts, providers: providerStates, agents: rows,
      refreshTiming: refreshTiming, historyError: historyError)
  }

  private static func rank(_ agent: AgentRecord) -> Int {
    if agent.freshness != .current { return 4 }
    switch agent.state {
    case .needsYou: return 0
    case .working: return 1
    case .failed: return 2
    case .idle: return 3
    case .unknown: return 4
    case .finished, .stopped: return 5
    }
  }
}
