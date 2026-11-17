import Foundation
import Testing

@testable import AgentBeaconCore

private struct NavigationFixtureRunner: CommandRunning {
  let data: Data
  func run(executable: String, arguments: [String], timeout: TimeInterval) async throws
    -> CommandResult
  {
    .init(data: data)
  }
}

@Test func claudePollUsesOwningDesktopConversationAndItsTitle() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let cliID = "d2c9c1af-24e5-453b-acc1-7c36fae7a4e4"
  let desktopID = "local_3f9a59db-d68f-48d8-a010-ac6a79fc0b7b"
  let folder = root.appendingPathComponent("account/org")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try JSONSerialization.data(withJSONObject: [
    "sessionId": desktopID, "cliSessionId": cliID,
    "title": "The actual Desktop conversation", "isArchived": false,
  ])
  .write(to: folder.appendingPathComponent(desktopID + ".json"))
  let input = try JSONSerialization.data(withJSONObject: [
    [
      "sessionId": cliID, "pid": 42,
      "kind": "interactive", "status": "waiting", "waitingFor": "permission prompt",
      "name": "generic-name",
    ]
  ])
  let resolver = ClaudeNavigationResolver(sessionsDirectory: root, desktopOwnerCheck: { $0 == 42 })
  let result = await ClaudeProvider(
    executable: "/fixture/claude", runner: NavigationFixtureRunner(data: input),
    navigationResolver: resolver
  ).poll(at: Date())
  let row = try #require(result.agents.first)
  #expect(row.state == .needsYou)
  #expect(row.title == "The actual Desktop conversation")
  #expect(row.navigation.kind == .openDesktopThread)
  #expect(
    row.navigation.url
      == ClaudeNavigationResolver.desktopThreadURL(localSessionID: desktopID)?.absoluteString)
  #expect(row.navigation.executable == nil)
}

@Test func unknownClaudeOriginProducesExplicitCopyActionInsteadOfLaunchingATerminal() async throws {
  let input = try JSONSerialization.data(withJSONObject: [
    [
      "sessionId": "d2c9c1af-24e5-453b-acc1-7c36fae7a4e4", "pid": 42,
      "kind": "interactive", "status": "busy", "name": "Fixture task",
    ]
  ])
  let resolver = ClaudeNavigationResolver(desktopOwnerCheck: { _ in false })
  let result = await ClaudeProvider(
    executable: "/fixture/claude", runner: NavigationFixtureRunner(data: input),
    navigationResolver: resolver
  ).poll(at: Date())
  let row = try #require(result.agents.first)
  #expect(row.navigation.kind == .copySessionID)
  #expect(row.navigation.executable == nil)
  #expect(row.navigation.arguments.isEmpty)
  #expect(row.navigation.url == nil)
}
