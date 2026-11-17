import Foundation
import Testing

@testable import AgentBeaconCore

private let instant = Date(timeIntervalSince1970: 1_800_000_000)
private func bytes(_ json: String) -> Data { Data(json.utf8) }
private func agent(
  _ id: String, harness: Harness = .claudeCode, state: AgentState,
  at: Date = instant, child: Bool = false
) -> AgentRecord {
  .init(harness: harness, sessionID: id, title: id, state: state, lastSeen: at, isSubagent: child)
}
private func providerResult(
  _ harness: Harness, _ agents: [AgentRecord], health: SourceHealth = .healthy
) -> ProviderSnapshot {
  .init(
    status: .init(
      harness: harness, health: health, message: "fixture", checkedAt: instant,
      observesAttention: true), agents: agents)
}
private actor SequenceProvider: AgentProvider {
  nonisolated let harness: Harness
  private var results: [ProviderSnapshot]
  init(_ harness: Harness, _ results: [ProviderSnapshot]) {
    self.harness = harness
    self.results = results
  }
  func poll(at date: Date) async -> ProviderSnapshot {
    results.count > 1 ? results.removeFirst() : results[0]
  }
}

private struct FailedRunner: CommandRunning {
  func run(executable: String, arguments: [String], timeout: TimeInterval) async throws
    -> CommandResult
  {
    .init(data: Data("PRIVATE_HARNESS_OUTPUT".utf8), exitCode: 9)
  }
}

@Test func failedClaudeCommandIsUnavailableAndDoesNotLeakRawOutput() async {
  let result = await ClaudeProvider(executable: "/fixture/claude", runner: FailedRunner()).poll(
    at: instant)
  #expect(result.status.health == .unavailable)
  #expect(!result.status.message.contains("PRIVATE"))
  #expect(result.agents.isEmpty)
}

@Test func codexProxyClientInitializesAndUsesOnlyReadCalls() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let executable = directory.appendingPathComponent("fake codex")
  let socketMarker = directory.appendingPathComponent("fixture-socket")
  try Data().write(to: socketMarker)
  let script = #"""
    #!/bin/sh
    IFS= read -r message || exit 2
    case "$message" in *'"method":"initialize"'*) ;; *) exit 3;; esac
    printf '%s\n' '{"id":1,"result":{}}'
    IFS= read -r message || exit 4
    case "$message" in *'"method":"initialized"'*) ;; *) exit 5;; esac
    IFS= read -r message || exit 6
    case "$message" in *'"method":"thread'*'loaded'*'list"'*) ;; *) exit 7;; esac
    printf '%s\n' '{"id":2,"result":{"data":["fixture-thread"]}}'
    IFS= read -r message || exit 8
    case "$message" in *'"method":"thread'*'read"'*) ;; *) exit 9;; esac
    printf '%s\n' '{"id":3,"result":{"thread":{"id":"fixture-thread","name":"Fixture","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}}'
    """#
  try script.write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  let reader = CodexProxyReader(executable: executable.path, socketPath: socketMarker.path)
  let result = await CodexProvider(reader: reader).poll(at: instant)
  #expect(result.agents.first?.sessionID == "fixture-thread")
  #expect(result.agents.first?.state == .needsYou)
  #expect(result.status.health == .partial, "\(result.status.message)")
}

@Test func claudeDistinguishesIdleFromAttentionAndJobStateFromProcessState() throws {
  let result = try ClaudeProvider.decode(
    bytes(
      """
      [
        {"sessionId":"idle","kind":"interactive","status":"idle"},
        {"sessionId":"busy","status":"busy"},
        {"sessionId":"wait","status":"waiting","waitingFor":"permission prompt"},
        {"sessionId":"loop","id":"job","kind":"background","state":"working","status":"idle"},
        {"sessionId":"block","state":"blocked","status":"idle"},
        {"sessionId":"done","state":"done","status":"idle"}
      ]
      """), at: instant)
  #expect(
    result.agents.map(\.state) == [.idle, .working, .needsYou, .working, .needsYou, .finished])
  #expect(result.agents[2].reason == "permission prompt")
  #expect(result.agents[3].navigation.arguments == ["attach", "job"])
  #expect(result.status.health == .healthy)
}

@Test func schemaDriftCannotBecomeAFalseZero() throws {
  let result = try ClaudeProvider.decode(
    bytes("[{\"sessionId\":\"future\",\"state\":\"new-state\"},{\"status\":\"busy\"}]"), at: instant
  )
  #expect(result.status.health == .partial)
  #expect(result.agents.count == 1)
  #expect(result.agents[0].state == .unknown)
  #expect(throws: (any Error).self) {
    try ClaudeProvider.decode(bytes("{\"error\":true}"), at: instant)
  }
}

@Test func codexFlagsAndChildSourcesUseTheGeneratedProtocolSchema() throws {
  let result = try CodexProvider.decode(
    bytes(
      """
      [
        {"id":"working","status":{"type":"active","activeFlags":[]}},
        {"id":"approval","status":{"type":"active","activeFlags":["waitingOnApproval"]}},
        {"id":"input","status":{"type":"active","activeFlags":["waitingOnUserInput"]}},
        {"id":"child","source":{"subAgent":{"thread_spawn":{"depth":1,"parent_thread_id":"parent"}}},"status":{"type":"idle"}},
        {"id":"drift","status":{"type":"active","activeFlags":["newFlag"]}},
        {"id":"closed","status":{"type":"notLoaded"}},
        {"id":"malformed","status":{"type":"active"}}
      ]
      """), at: instant)
  #expect(
    result.agents.map(\.state) == [
      .working, .needsYou, .needsYou, .idle, .unknown, .unknown, .unknown,
    ])
  #expect(result.agents[3].isSubagent)
  #expect(result.status.health == .partial)  // Never claims every independent process is visible.
}

@Test func monitorCountsSessionsOnceAcrossHarnessesAndSortsAttentionFirst() async {
  let claude = SequenceProvider(
    .claudeCode,
    [
      providerResult(
        .claudeCode,
        [
          agent("same", state: .working), agent("same", state: .working),
          agent("idle", state: .idle),
          agent("child", state: .working, child: true),
        ])
    ])
  let codex = SequenceProvider(
    .codex, [providerResult(.codex, [agent("same", harness: .codex, state: .needsYou)])])
  let monitor = AgentMonitor(providers: [claude, codex])
  let result = await monitor.refresh(at: instant)
  #expect(result.counts.active == 2)
  #expect(result.counts.needsYou == 1)
  #expect(result.counts.working == 1)
  #expect(result.agents.first?.harness == .codex)
  #expect(result.agents.count == 4)
  #expect(!result.counts.incomplete)
}

@Test func providerFailureRetainsEvidenceAndMarksCountsIncomplete() async {
  let source = SequenceProvider(
    .claudeCode,
    [
      providerResult(.claudeCode, [agent("a", state: .needsYou)]),
      .unavailable(.claudeCode, at: instant, message: "disconnected"),
      providerResult(
        .claudeCode, [agent("a", state: .working, at: instant.addingTimeInterval(10))]),
    ])
  let monitor = AgentMonitor(providers: [source])
  _ = await monitor.refresh(at: instant)
  let failed = await monitor.refresh(at: instant.addingTimeInterval(5))
  #expect(failed.agents.count == 1)
  #expect(failed.agents[0].freshness == .stale)
  #expect(failed.counts.active == 0)
  #expect(failed.counts.uncertain == 1)
  #expect(failed.counts.incomplete)
  let recovered = await monitor.refresh(at: instant.addingTimeInterval(10))
  #expect(recovered.counts.active == 1)
  #expect(recovered.counts.needsYou == 0)
  #expect(recovered.agents[0].freshness == .current)
}

@Test func vanishedWorkIsUncertainRatherThanFinishedThenExpires() async {
  let source = SequenceProvider(
    .claudeCode,
    [
      providerResult(.claudeCode, [agent("a", state: .working)]),
      providerResult(.claudeCode, []),
    ])
  let monitor = AgentMonitor(providers: [source])
  _ = await monitor.refresh(at: instant)
  let missing = await monitor.refresh(at: instant.addingTimeInterval(5))
  #expect(missing.agents.first?.freshness == .missing)
  #expect(missing.agents.first?.state == .working)
  #expect(missing.counts.active == 0)
  #expect(missing.counts.incomplete)
  let expired = await monitor.refresh(at: instant.addingTimeInterval(301))
  #expect(expired.agents.isEmpty)
}

@Test func unchangedPollDoesNotMakeOldWorkLookNew() async {
  let source = SequenceProvider(
    .claudeCode,
    [
      providerResult(.claudeCode, [agent("a", state: .working)]),
      providerResult(.claudeCode, [agent("a", state: .working, at: instant.addingTimeInterval(5))]),
    ])
  let monitor = AgentMonitor(providers: [source])
  _ = await monitor.refresh(at: instant)
  let result = await monitor.refresh(at: instant.addingTimeInterval(5))
  #expect(result.agents[0].changedAt == instant)
  #expect(result.agents[0].lastSeen == instant.addingTimeInterval(5))
}

@Test func cursorIgnoresLateStopFromAnEarlierGeneration() {
  let events: [CursorEvent] = [
    .init(
      receivedAt: instant, conversationID: "chat", generationID: "A", name: "beforeSubmitPrompt"),
    .init(
      receivedAt: instant.addingTimeInterval(1), conversationID: "chat", generationID: "B",
      name: "beforeSubmitPrompt"),
    .init(
      receivedAt: instant.addingTimeInterval(2), conversationID: "chat", generationID: "A",
      name: "stop", status: "completed"),
  ]
  let result = CursorProvider.reduce(events, at: instant.addingTimeInterval(3))
  #expect(result.agents[0].state == .working)
  #expect(!result.status.observesAttention)
  #expect(result.status.health == .partial)
}

@Test func cursorDoesNotTreatAResponseAsCompletionOrSilenceAsAQuestion() {
  let events: [CursorEvent] = [
    .init(
      receivedAt: instant, conversationID: "chat", generationID: "A", name: "beforeSubmitPrompt"),
    .init(
      receivedAt: instant.addingTimeInterval(1), conversationID: "chat", generationID: "A",
      name: "afterAgentResponse"),
  ]
  let result = CursorProvider.reduce(events, at: instant.addingTimeInterval(125))
  #expect(result.agents[0].state == .working)
  #expect(result.agents[0].freshness == .stale)
  #expect(result.agents[0].state != .needsYou)
}

@Test(arguments: [
  ("completed", AgentState.finished), ("aborted", .stopped), ("error", .failed),
  ("new-state", .unknown),
])
func cursorStopStatuses(status: String, expected: AgentState) {
  let result = CursorProvider.reduce(
    [.init(receivedAt: instant, conversationID: "chat", name: "stop", status: status)], at: instant)
  #expect(result.agents[0].state == expected)
}

@Test func cursorSpoolPersistsOnlyAllowedMetadataAndCanReplayAfterRestart() async throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let event = try CursorEvent.fromHook(
    bytes(
      """
      {"hook_event_name":"beforeSubmitPrompt","conversation_id":"abc","generation_id":"g",
       "workspace_roots":["/project"],"prompt":"PRIVATE_PROMPT","tool_input":{"secret":"PRIVATE_SECRET"},
       "transcript_path":"PRIVATE_PATH","user_email":"PRIVATE_EMAIL"}
      """), at: instant)
  try CursorSpool.write(event, to: dir)
  let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
  let stored = try String(contentsOf: files[0], encoding: .utf8)
  #expect(!stored.contains("PRIVATE"))
  let attributes = try FileManager.default.attributesOfItem(atPath: files[0].path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  let replay = await CursorProvider(directory: dir).poll(at: instant.addingTimeInterval(2))
  #expect(replay.agents[0].state == .working)
  #expect(replay.agents[0].workspace == "/project")
}

@Test func cursorConfigQuotesPathsAndAddsNoPermissionDecisionHooks() throws {
  let data = try CursorSpool.configuration(executable: "/a path/it's-beacon")
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let hooks = try #require(object["hooks"] as? [String: Any])
  #expect(hooks["preToolUse"] == nil)
  #expect(hooks["beforeShellExecution"] == nil)
  let command = try #require(
    (hooks["beforeSubmitPrompt"] as? [[String: String]])?.first?["command"])
  #expect(command.contains("'\\''"))
  #expect(command.contains("--hook-event 'beforeSubmitPrompt'"))
}

@Test func boundedRunnerReportsExitAndTerminatesHungProcess() async throws {
  let runner = SystemCommandRunner()
  let result = try await runner.run(
    executable: "/usr/bin/printf", arguments: ["status"], timeout: 2)
  #expect(result.exitCode == 0)
  #expect(String(decoding: result.data, as: UTF8.self) == "status")
  let start = ContinuousClock.now
  await #expect(throws: (any Error).self) {
    try await runner.run(executable: "/bin/sleep", arguments: ["20"], timeout: 0.1)
  }
  #expect(start.duration(to: .now) < .seconds(2))
}

@Test func boundedRunnerRejectsOutputFloodWithoutDeadlock() async {
  await #expect(throws: (any Error).self) {
    try await SystemCommandRunner().run(executable: "/usr/bin/yes", arguments: [], timeout: 2)
  }
}
