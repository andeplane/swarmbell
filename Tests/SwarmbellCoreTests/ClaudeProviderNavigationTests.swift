import Foundation
import Testing

@testable import SwarmbellCore

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

@Test func claudePollIncludesLiveLetsSessionsAcrossProfilesWithoutDuplicates() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let cliID = UUID().uuidString
  let letsID = UUID().uuidString
  let staleID = UUID().uuidString
  let start = "Mon Nov 23 22:09:18 2026"
  for (profile, pid, id, processStart) in [
    ("cred-one", 41, cliID, start),
    ("cred-two", 42, letsID, start),
    ("cred-two", 43, staleID, "stale process start"),
  ] {
    let directory = root.appendingPathComponent("\(profile)/sessions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: [
      "pid": pid, "sessionId": id, "pidDomain": "darwin", "procStart": processStart,
      "entrypoint": "sdk-cli", "kind": "interactive", "status": "busy", "name": "Lets task",
    ])
    try data.write(to: directory.appendingPathComponent("\(pid).json"))
  }
  let registry = LetsClaudeRegistry(root: root, ownsProcess: { _, value in value == start })
  let cli = NavigationFixtureRunner(
    data: Data(
      """
      [{"sessionId":"\(cliID.lowercased())","status":"idle","name":"CLI task"}]
      """.utf8))
  let provider = ClaudeProvider(
    executable: "/fixture/claude", runner: cli, navigationResolver: nil, letsRegistry: registry)
  let result = await provider.poll(at: Date())
  #expect(result.agents.map(\.title) == ["CLI task", "Lets task"])
  #expect(result.agents.map(\.state) == [.idle, .working])
  #expect(result.agents.last?.navigation.kind == .copySessionID)
  #expect(result.status.health == .healthy)

  let withoutCLI = await ClaudeProvider(
    executable: nil, runner: cli, navigationResolver: nil, letsRegistry: registry
  ).poll(at: Date())
  #expect(Set(withoutCLI.agents.map(\.sessionID)) == [cliID, letsID])
  #expect(withoutCLI.status.health == .partial)
}
