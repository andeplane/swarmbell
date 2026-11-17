import Foundation
import Testing

@testable import SwarmbellCore

@Test func memoryObserverClassificationRequiresItsPrivateDirectory() {
  let root = URL(fileURLWithPath: "/fixture/home/.claude-mem/observer-sessions")
  #expect(InternalSessions.isMemoryObserver(workspace: root.path + "/1213", root: root))
  #expect(InternalSessions.isMemoryObserver(workspace: root.path + "/1213/nested", root: root))
  #expect(InternalSessions.isMemoryObserver(workspace: root.path, root: root))
  #expect(!InternalSessions.isMemoryObserver(workspace: "/fixture/projects/1213", root: root))
  #expect(!InternalSessions.isMemoryObserver(workspace: root.path + "-project/1213", root: root))
  #expect(!InternalSessions.isMemoryObserver(workspace: root.path + "/my-project", root: root))
  #expect(
    !InternalSessions.isMemoryObserver(workspace: root.path + "/1213/../../project", root: root))
  #expect(!InternalSessions.isMemoryObserver(workspace: nil, root: root))
}

@Test func claudeMemoryObserverIsOmittedWhileSameNamedRealSessionRemains() throws {
  let root = InternalSessions.memoryObserverDirectory.path
  let rows: [[String: Any]] = [
    [
      "sessionId": "observer", "name": "1213-b3", "cwd": root + "/1213",
      "kind": "interactive", "status": "busy",
    ],
    [
      "sessionId": "real", "name": "1213-b3", "cwd": "/fixture/projects/1213",
      "kind": "interactive", "status": "busy",
    ],
  ]
  let result = try ClaudeProvider.decode(
    JSONSerialization.data(withJSONObject: rows), at: Date())
  #expect(result.agents.map(\.sessionID) == ["real"])
  #expect(result.agents.first?.state == .working)
  #expect(result.status.health == .healthy)
}

@Test func onlyMemoryObserversIsAValidEmptyClaudeResult() throws {
  let row: [[String: Any]] = [
    [
      "sessionId": "observer", "name": "1213-b3",
      "cwd": InternalSessions.memoryObserverDirectory.appendingPathComponent("1213").path,
      "status": "busy",
    ]
  ]
  let result = try ClaudeProvider.decode(
    JSONSerialization.data(withJSONObject: row), at: Date())
  #expect(result.agents.isEmpty)
  #expect(result.status.health == .healthy)
}

private struct InternalObserverFixture: AgentProvider {
  let harness: Harness = .cursor
  func poll(at date: Date) async -> ProviderSnapshot {
    .init(
      status: .init(
        harness: harness, health: .healthy, message: "fixture",
        checkedAt: date, observesAttention: true),
      agents: [
        .init(
          harness: harness, sessionID: "internal", title: "Memory helper",
          workspace: InternalSessions.memoryObserverDirectory.appendingPathComponent("1213").path,
          state: .working, lastSeen: date),
        .init(
          harness: harness, sessionID: "real", title: "User coding session",
          workspace: "/fixture/project", state: .working, lastSeen: date),
      ])
  }
}

@Test func monitorExcludesMemoryHelpersFromListsCountsAndExports() async {
  let monitor = AgentMonitor(providers: [InternalObserverFixture()], countSubagents: true)
  let result = await monitor.refresh()
  #expect(result.agents.map(\.sessionID) == ["real"])
  #expect(result.counts.active == 1)
  #expect(result.counts.working == 1)
}
