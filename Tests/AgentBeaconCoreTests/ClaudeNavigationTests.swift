import Foundation
import Testing

@testable import AgentBeaconCore

private let navigationCLI = "11111111-1111-4111-8111-111111111111"
private let navigationLocal = "local_22222222-2222-4222-8222-222222222222"

private func writeClaudeMetadata(
  _ directory: URL, localID: String = navigationLocal,
  cliID: String = navigationCLI, archived: Bool = false
) throws {
  let folder = directory.appendingPathComponent("account/org", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let data = try JSONSerialization.data(withJSONObject: [
    "sessionId": localID, "cliSessionId": cliID, "isArchived": archived,
    "title": " A precise desktop task ",
    "promptAppendSnapshot": "PRIVATE_PROMPT_MUST_NOT_BE_NAVIGATION",
  ])
  try data.write(to: folder.appendingPathComponent(localID + ".json"))
}

@Test func claudeDesktopURLUsesExistingLocalSessionInsteadOfCLIImport() throws {
  let url = try #require(ClaudeNavigationResolver.desktopThreadURL(localSessionID: navigationLocal))
  #expect(url.scheme == "claude")
  #expect(url.host == "code")
  #expect(url.path == "/continue")
  #expect(
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
      .init(name: "session", value: navigationLocal)
    ])
  #expect(ClaudeNavigationResolver.desktopThreadURL(localSessionID: navigationCLI) == nil)
  #expect(ClaudeNavigationResolver.desktopThreadURL(localSessionID: "local_../../other") == nil)
}

@Test func claudeDesktopNavigationRequiresBothLiveOwnerAndExactMetadata() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try writeClaudeMetadata(directory)
  let resolver = ClaudeNavigationResolver(
    sessionsDirectory: directory, desktopOwnerCheck: { $0 == 123 })
  let target = await resolver.resolve(sessionID: navigationCLI, processID: 123)
  #expect(target?.kind == .openDesktopThread)
  #expect(target?.url?.contains(navigationLocal) == true)
  #expect(target?.url?.contains("PRIVATE") == false)
  let destination = await resolver.resolveDestination(sessionID: navigationCLI, processID: 123)
  #expect(destination?.title == "A precise desktop task")
  #expect(await resolver.resolve(sessionID: navigationCLI, processID: 456) == nil)
  #expect(await resolver.resolve(sessionID: navigationCLI, processID: nil) == nil)
}

@Test func archivedOrAmbiguousClaudeMetadataCannotOpenTheWrongThread() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try writeClaudeMetadata(directory, archived: true)
  let archived = ClaudeNavigationResolver(
    sessionsDirectory: directory, desktopOwnerCheck: { _ in true })
  #expect(await archived.resolve(sessionID: navigationCLI, processID: 123) == nil)
  try writeClaudeMetadata(directory)
  try writeClaudeMetadata(directory, localID: "local_33333333-3333-4333-8333-333333333333")
  let ambiguous = ClaudeNavigationResolver(
    sessionsDirectory: directory, desktopOwnerCheck: { _ in true })
  #expect(await ambiguous.resolve(sessionID: navigationCLI, processID: 123) == nil)
}

@Test func malformedClaudeMetadataAndTerminalOwnedProcessStayUnresolved() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let folder = directory.appendingPathComponent("account/org", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try Data("invalid".utf8).write(to: folder.appendingPathComponent(navigationLocal + ".json"))
  let resolver = ClaudeNavigationResolver(
    sessionsDirectory: directory, desktopOwnerCheck: { _ in true })
  #expect(await resolver.resolve(sessionID: navigationCLI, processID: 123) == nil)
  #expect(!ClaudeNavigationResolver.isDesktopManaged(0))
  #expect(!ClaudeNavigationResolver.isDesktopManaged(Int(Int32.max) + 1))
}
