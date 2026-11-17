import Foundation
import Testing

@testable import AgentBeaconCore

private struct CursorInstallFixture {
  let directory: URL
  let configuration: URL
  let events: URL
  let backups: URL
  let helper: URL
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    configuration = directory.appendingPathComponent("cursor/hooks.json")
    events = directory.appendingPathComponent("events")
    backups = directory.appendingPathComponent("backups")
    helper = directory.appendingPathComponent("App's helper/agent-beacon")
    try FileManager.default.createDirectory(
      at: helper.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
  }
  func write(_ root: [String: Any]) throws {
    try FileManager.default.createDirectory(
      at: configuration.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: root).write(to: configuration)
  }
  func root() throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: Any])
  }
  func hooks() throws -> [String: [[String: Any]]] {
    try #require(root()["hooks"] as? [String: [[String: Any]]])
  }
  func install(helper replacement: URL? = nil) throws -> CursorInstallationResult {
    try CursorHookInstaller.install(
      executableURL: replacement ?? helper,
      configurationURL: configuration, eventDirectory: events, backupDirectoryURL: backups)
  }
  func uninstall() throws -> CursorInstallationResult {
    try CursorHookInstaller.uninstall(
      configurationURL: configuration,
      eventDirectory: events, backupDirectoryURL: backups)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Test func cursorInstallationPreservesExistingHooksFieldsOrderAndPermissions() throws {
  let fixture = try CursorInstallFixture()
  defer { fixture.remove() }
  let a: [String: Any] = ["command": "orca hook", "matcher": "repo", "timeout": 17]
  let b: [String: Any] = ["command": "claude-mem context", "unknownOption": ["enabled": true]]
  let permission: [[String: Any]] = [["command": "existing permission policy", "matcher": "rm"]]
  try fixture.write([
    "version": 1, "unknownTopLevel": ["setting": "retained"],
    "hooks": [
      "beforeSubmitPrompt": [a, b], "preToolUse": permission,
      "futureEvent": [["type": "prompt", "prompt": "existing future integration"]],
    ],
  ])
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o640],
    ofItemAtPath: fixture.configuration.path)
  let original = try Data(contentsOf: fixture.configuration)
  let result = try fixture.install()
  #expect(result.changed)
  #expect(result.installedHookCount == CursorEvent.observedHooks.count)
  let backup = try #require(result.backupURL)
  #expect(try Data(contentsOf: backup) == original)
  #expect(
    (try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions]
      as? NSNumber)?.intValue == 0o600)
  #expect(
    (try FileManager.default.attributesOfItem(atPath: fixture.configuration.path)[.posixPermissions]
      as? NSNumber)?.intValue == 0o640)
  let hooks = try fixture.hooks()
  let submit = try #require(hooks["beforeSubmitPrompt"])
  #expect(submit.count == 3)
  #expect(NSDictionary(dictionary: submit[0]).isEqual(to: a))
  #expect(NSDictionary(dictionary: submit[1]).isEqual(to: b))
  #expect(NSArray(array: hooks["preToolUse"] ?? []).isEqual(to: permission))
  #expect((try fixture.root()["unknownTopLevel"] as? [String: String]) == ["setting": "retained"])
  #expect(hooks["beforeShellExecution"] == nil)
  #expect(
    FileManager.default.fileExists(
      atPath:
        fixture.events.appendingPathComponent(CursorHookInstaller.markerFileName).path))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: fixture.events.path)
      .filter { $0.hasSuffix(".json") }.isEmpty)
}

@Test func cursorInstallationIsIdempotentAndUpdatesOnlyItsOwnHelperCommands() throws {
  let fixture = try CursorInstallFixture()
  defer { fixture.remove() }
  try fixture.write(["version": 1, "hooks": ["stop": [["command": "existing stop hook"]]]])
  _ = try fixture.install()
  let first = try Data(contentsOf: fixture.configuration)
  let repeated = try fixture.install()
  #expect(!repeated.changed)
  #expect(repeated.backupURL == nil)
  #expect(try Data(contentsOf: fixture.configuration) == first)
  let replacement = fixture.directory.appendingPathComponent("new helper")
  try FileManager.default.copyItem(at: fixture.helper, to: replacement)
  let updated = try fixture.install(helper: replacement)
  #expect(updated.changed)
  for event in CursorEvent.observedHooks {
    let commands = (try fixture.hooks()[event] ?? []).compactMap { $0["command"] as? String }
    #expect(commands.filter { $0.hasSuffix(" " + CursorHookInstaller.ownershipFlag) }.count == 1)
    #expect(commands.last?.contains("'" + replacement.path + "'") == true)
    #expect(commands.last?.contains("App's helper") == false)
  }
  #expect((try fixture.hooks()["stop"]?.first?["command"] as? String) == "existing stop hook")
}

@Test func cursorInstallationQuotesApostrophesAndPreservesAnExactBackup() throws {
  let fixture = try CursorInstallFixture()
  defer { fixture.remove() }
  try fixture.write(["version": 1, "hooks": [:]])
  let original = try Data(contentsOf: fixture.configuration)
  let result = try fixture.install()
  let command = try #require(try fixture.hooks()["beforeSubmitPrompt"]?.last?["command"] as? String)
  #expect(command.contains("App'\\''s helper"))
  #expect(command.contains("--hook-event 'beforeSubmitPrompt'"))
  #expect(command.contains("--cursor-events '" + fixture.events.path + "'"))
  #expect(command.hasSuffix(" --agent-beacon-observer"))
  #expect(try Data(contentsOf: #require(result.backupURL)) == original)
}

@Test(arguments: [
  "{bad", "[]", "{\"version\":2,\"hooks\":{}}",
  "{\"version\":true,\"hooks\":{}}", "{\"version\":1,\"hooks\":[]}",
  "{\"version\":1,\"hooks\":{\"stop\":[\"bad\"]}}",
])
func malformedCursorConfigurationIsNeverOverwritten(json: String) throws {
  let fixture = try CursorInstallFixture()
  defer { fixture.remove() }
  try FileManager.default.createDirectory(
    at: fixture.configuration.deletingLastPathComponent(),
    withIntermediateDirectories: true)
  let original = Data(json.utf8)
  try original.write(to: fixture.configuration)
  #expect(throws: (any Error).self) { try fixture.install() }
  #expect(try Data(contentsOf: fixture.configuration) == original)
  #expect(!FileManager.default.fileExists(atPath: fixture.backups.path))
  #expect(!FileManager.default.fileExists(atPath: fixture.events.path))
}

@Test func cursorUninstallPreservesPluginsAndChangesMadeAfterInstallation() throws {
  let fixture = try CursorInstallFixture()
  defer { fixture.remove() }
  try fixture.write(["version": 1, "hooks": ["beforeSubmitPrompt": [["command": "original"]]]])
  _ = try fixture.install()
  var edited = try fixture.root()
  var hooks = try fixture.hooks()
  hooks["beforeSubmitPrompt", default: []].append(["command": "installed later", "timeout": 12])
  hooks["preToolUse"] = [["command": "later permission policy"]]
  edited["hooks"] = hooks
  edited["laterSetting"] = "must remain"
  try fixture.write(edited)
  let beforeUninstall = try Data(contentsOf: fixture.configuration)
  let result = try fixture.uninstall()
  #expect(result.changed)
  #expect(result.installedHookCount == 0)
  #expect(try Data(contentsOf: #require(result.backupURL)) == beforeUninstall)
  let retained = try fixture.hooks()
  #expect(
    retained["beforeSubmitPrompt"]?.compactMap { $0["command"] as? String }
      == ["original", "installed later"])
  #expect((retained["preToolUse"]?.first?["command"] as? String) == "later permission policy")
  #expect((try fixture.root()["laterSetting"] as? String) == "must remain")
  #expect(
    !FileManager.default.fileExists(
      atPath:
        fixture.events.appendingPathComponent(CursorHookInstaller.markerFileName).path))
  let again = try fixture.uninstall()
  #expect(!again.changed)
  #expect(again.backupURL == nil)
}

@Test func cursorUninstallDoesNotRemoveAnotherConfigurationsReadyMarker() throws {
  let fixture = try CursorInstallFixture()
  defer { fixture.remove() }
  _ = try fixture.install()
  let other = fixture.directory.appendingPathComponent("other/hooks.json")
  let result = try CursorHookInstaller.uninstall(
    configurationURL: other,
    eventDirectory: fixture.events, backupDirectoryURL: fixture.backups)
  #expect(!result.changed)
  #expect(
    FileManager.default.fileExists(
      atPath:
        fixture.events.appendingPathComponent(CursorHookInstaller.markerFileName).path))
}

@Test func cursorInstallationRejectsMissingHelperAndSymbolicConfiguration() throws {
  let fixture = try CursorInstallFixture()
  defer { fixture.remove() }
  #expect(throws: (any Error).self) {
    try fixture.install(helper: fixture.directory.appendingPathComponent("missing"))
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
  let actual = fixture.directory.appendingPathComponent("managed-hooks.json")
  try Data("{\"version\":1,\"hooks\":{}}".utf8).write(to: actual)
  try FileManager.default.createDirectory(
    at: fixture.configuration.deletingLastPathComponent(),
    withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: fixture.configuration, withDestinationURL: actual)
  #expect(throws: (any Error).self) { try fixture.install() }
  #expect(try Data(contentsOf: actual) == Data("{\"version\":1,\"hooks\":{}}".utf8))
}

@Test func cursorInstallationDoesNotReplaceADanglingManagedConfigurationLink() throws {
  let fixture = try CursorInstallFixture()
  defer { fixture.remove() }
  try FileManager.default.createDirectory(
    at: fixture.configuration.deletingLastPathComponent(),
    withIntermediateDirectories: true)
  let missing = fixture.directory.appendingPathComponent("not-mounted/hooks.json")
  try FileManager.default.createSymbolicLink(at: fixture.configuration, withDestinationURL: missing)
  #expect(throws: (any Error).self) { try fixture.install() }
  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: fixture.configuration.path)
      == missing.path)
}
