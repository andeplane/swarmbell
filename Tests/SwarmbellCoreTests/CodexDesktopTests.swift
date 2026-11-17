import Foundation
import Testing

@testable import SwarmbellCore

private func cumulativeTokens(_ total: Int64 = 1_500) -> [String: Any] {
  [
    "inputTokens": Int64(1_000), "cachedInputTokens": Int64(600),
    "cacheWriteInputTokens": Int64(25), "outputTokens": Int64(500),
    "reasoningOutputTokens": Int64(200), "totalTokens": total,
  ]
}

@Test func desktopProjectionRetainsReportedCumulativeTokensWithoutDoubleCounting() throws {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let usageResult100 = projection.acceptSnapshot(
    [
      "id": "fixture", "latestModel": "configured-model-not-billing-evidence",
      "threadRuntimeStatus": ["type": "active", "activeFlags": [] as [String]],
      "latestTokenUsageInfo": [
        "total": cumulativeTokens(), "last": cumulativeTokens(75), "modelContextWindow": 128_000,
      ],
      "turns": [["content": "PRIVATE_TRANSCRIPT"]],
    ], revision: 1)
  #expect(usageResult100)
  let first = try #require(projection.record(at: Date()).usage)
  #expect(first.scope == .session)
  #expect(first.totalTokens == 1_500)
  #expect(first.inputTokens == 1_000)
  #expect(first.cachedInputTokens == 600)
  #expect(first.cacheCreationInputTokens == 25)
  #expect(first.outputTokens == 500)
  #expect(first.reasoningOutputTokens == 200)
  #expect(first.model == nil)
  #expect(first.reportedCostUSD == nil)
  #expect(
    projection.record(at: Date().addingTimeInterval(300)).usage?.observedAt == first.observedAt)
  #expect(!String(describing: projection).contains("PRIVATE_TRANSCRIPT"))
}

@Test func desktopProjectionUpdatesNestedTokenPatchesAndClearsRemovedTotals() throws {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let usageResult101 = projection.acceptSnapshot(
    [
      "id": "fixture", "threadRuntimeStatus": ["type": "idle"],
      "latestTokenUsageInfo": ["total": cumulativeTokens()],
    ], revision: 1)
  #expect(usageResult101)
  let usageResult102 = projection.acceptPatches(
    [
      [
        "op": "replace", "path": ["latestTokenUsageInfo", "total", "totalTokens"], "value": 2_000,
      ],
      ["op": "replace", "path": ["latestTokenUsageInfo", "last", "totalTokens"], "value": 99],
    ], base: 1, revision: 2)
  #expect(usageResult102)
  #expect(projection.record(at: Date()).usage?.totalTokens == 2_000)
  let usageResult103 = projection.acceptPatches(
    [
      ["op": "remove", "path": ["latestTokenUsageInfo", "total", "cacheWriteInputTokens"]]
    ], base: 2, revision: 3)
  #expect(usageResult103)
  #expect(projection.record(at: Date()).usage?.cacheCreationInputTokens == nil)
  #expect(projection.record(at: Date()).usage?.totalTokens == 2_000)
  let usageResult104 = projection.acceptPatches(
    [
      ["op": "remove", "path": ["latestTokenUsageInfo"]]
    ], base: 3, revision: 4)
  #expect(usageResult104)
  #expect(projection.record(at: Date()).usage == nil)
  #expect(projection.record(at: Date()).state == .idle)
}

@Test func desktopProjectionRejectsMalformedUsageWithoutGuessingOrLosingRuntimeState() {
  for invalid: Any in [-1, true, 1.25, "1500", NSNumber(value: UInt64.max)] {
    var totals = cumulativeTokens()
    totals["totalTokens"] = invalid
    var projection = CodexIPCProjection(id: "fixture", host: "local")
    let usageResult105 = projection.acceptSnapshot(
      [
        "id": "fixture",
        "threadRuntimeStatus": ["type": "active", "activeFlags": [] as [String]],
        "latestTokenUsageInfo": ["total": totals],
      ], revision: 1)
    #expect(usageResult105)
    #expect(projection.record(at: Date()).usage == nil)
    #expect(projection.record(at: Date()).state == .working)
  }
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let usageResult106 = projection.acceptSnapshot(
    [
      "id": "fixture", "threadRuntimeStatus": ["type": "idle"],
      "latestTokenUsageInfo": ["last": cumulativeTokens()],
    ], revision: 1)
  #expect(usageResult106)
  #expect(projection.record(at: Date()).usage == nil)
}

@Test func desktopProjectionDropsUncertainOrExpiredUsageAndAcceptsFullReplacement() {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let usageResult107 = projection.acceptSnapshot(
    [
      "id": "fixture", "threadRuntimeStatus": ["type": "active", "activeFlags": [] as [String]],
    ], revision: 1)
  #expect(usageResult107)
  #expect(projection.record(at: Date()).usage == nil)
  let usageResult108 = projection.acceptPatches(
    [
      ["op": "add", "path": ["latestTokenUsageInfo"], "value": ["total": cumulativeTokens()]]
    ], base: 1, revision: 2)
  #expect(usageResult108)
  #expect(projection.record(at: Date()).usage?.totalTokens == 1_500)
  let usageResult1 = !projection.acceptPatches([], base: 5, revision: 6)
  #expect(usageResult1)
  #expect(projection.record(at: Date()).usage == nil)
  let usageResult109 = projection.acceptSnapshot(
    [
      "id": "fixture", "threadRuntimeStatus": ["type": "active", "activeFlags": [] as [String]],
      "latestTokenUsageInfo": ["total": cumulativeTokens(3_000)],
    ], revision: 7)
  #expect(usageResult109)
  let observed = Date()
  projection.lastEvent = observed
  let usageResult2 = projection.expireQuietActivity(at: observed.addingTimeInterval(61))
  #expect(usageResult2)
  #expect(projection.record(at: observed).usage == nil)
}

@Test func desktopProjectionUsesLiveRuntimeFlagsAndDiscardsTranscript() {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let accepted = projection.acceptSnapshot(
    [
      "id": "fixture", "title": "Live task", "cwd": "/project",
      "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnUserInput"]],
      "turns": [["text": "PRIVATE_TRANSCRIPT"]],
      "requests": [["type": "requestUserInput", "prompt": "PRIVATE_PROMPT"]],
    ], revision: 1)
  #expect(accepted)
  let record = projection.record(at: Date())
  #expect(record.state == .needsYou)
  #expect(record.reason == "Question for you")
  #expect(record.workspace == "/project")
  #expect(projection.requestKinds == ["requestUserInput"])
  #expect(!String(describing: projection).contains("PRIVATE"))
}

@Test func desktopProjectionDoesNotUseHistoricalTurnToInferActivity() {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  _ = projection.acceptSnapshot(
    ["id": "fixture", "turns": [["status": "inProgress"]]], revision: 1)
  #expect(projection.record(at: Date()).state == .unknown)
}

@Test func desktopProjectionChecksPatchRevisionsAndResynchronizes() {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  _ = projection.acceptSnapshot(
    [
      "id": "fixture", "threadRuntimeStatus": ["type": "active", "activeFlags": [] as [String]],
    ], revision: 8)
  #expect(projection.record(at: Date()).state == .working)
  let patchAccepted = projection.acceptPatches(
    [
      [
        "op": "replace", "path": ["threadRuntimeStatus"],
        "value": ["type": "active", "activeFlags": ["waitingOnApproval"]],
      ],
      ["op": "replace", "path": ["turns", 0, "text"], "value": "PRIVATE"],
    ], base: 8, revision: 9)
  #expect(patchAccepted)
  #expect(projection.record(at: Date()).state == .needsYou)
  #expect(!String(describing: projection).contains("PRIVATE"))
  let gapAccepted = projection.acceptPatches([], base: 10, revision: 11)
  #expect(!gapAccepted)
  #expect(projection.record(at: Date()).state == .unknown)
  let resynchronized = projection.acceptSnapshot(
    [
      "id": "fixture", "threadRuntimeStatus": ["type": "idle"],
    ], revision: 12)
  #expect(resynchronized)
  #expect(projection.record(at: Date()).state == .idle)
}

@Test func unsupportedNestedStatusPatchIsUncertainInsteadOfGuessing() {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  _ = projection.acceptSnapshot(
    [
      "id": "fixture", "threadRuntimeStatus": ["type": "active", "activeFlags": [] as [String]],
    ], revision: 1)
  let accepted = projection.acceptPatches(
    [
      [
        "op": "replace", "path": ["threadRuntimeStatus", "activeFlags", 0],
        "value": "waitingOnApproval",
      ]
    ], base: 1, revision: 2)
  #expect(!accepted)
  #expect(projection.record(at: Date()).state == .unknown)
}

@Test func shippedDesktopThreadURIsValidateIDsAndEncodeRemoteHost() {
  let id = "44444444-4444-4444-8444-444444444444"
  #expect(CodexDesktopProvider.threadURL(sessionID: "not-a-session") == nil)
  #expect(CodexDesktopProvider.threadURL(sessionID: id)?.absoluteString == "codex://threads/" + id)
  let url = CodexDesktopProvider.threadURL(sessionID: id, host: "remote host&name")
  #expect(
    URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
      == "remote host&name")
}

@Test func quietActiveDesktopStateExpiresWithoutRenewedEvidence() {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  _ = projection.acceptSnapshot(
    [
      "id": "fixture",
      "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnApproval"]],
    ], revision: 1)
  let observed = Date(timeIntervalSince1970: 1_800_000_000)
  projection.lastEvent = observed
  let premature = projection.expireQuietActivity(at: observed.addingTimeInterval(46))
  #expect(!premature)
  #expect(projection.record(at: observed.addingTimeInterval(46)).state == .needsYou)
  let expired = projection.expireQuietActivity(at: observed.addingTimeInterval(61))
  #expect(expired)
  #expect(projection.record(at: observed.addingTimeInterval(61)).state == .unknown)
}

// Sanitized metadata fixture matching the shipped canonical desktop stream:
// async questions live in agentMessage.questions, with no pending requests or flags.
private func asyncTurn(_ id: String = "turn", questionCount: Int = 1, status: String = "inProgress")
  -> [String: Any]
{
  [
    "turnId": id, "status": status,
    "items": [
      [
        "type": "agentMessage", "id": "question-item",
        "questions": Array(repeating: ["question": "PRIVATE_QUESTION"], count: questionCount),
        "text": "PRIVATE_TRANSCRIPT",
      ]
    ],
  ]
}

private func canonicalAsyncState(_ turn: [String: Any] = asyncTurn()) -> [String: Any] {
  [
    "id": "fixture", "requests": [] as [Any], "turns": [] as [Any],
    "threadRuntimeStatus": ["type": "active", "activeFlags": [] as [String]],
    "turnHistory": [
      "kind": "canonical",
      "history": [
        "entitiesByKey": ["tail:fixture": turn],
        "islands": [["entries": [["key": "tail:fixture", "value": "turn"]]]],
      ],
    ],
  ]
}

private func asyncReply(_ indexes: [Int] = [0], noncanonical: Bool = false) throws -> String {
  let rows = try indexes.map { index -> [String: String] in
    let identifier = try JSONSerialization.data(withJSONObject: [
      "request_user_input_async", "question-item", index,
    ])
    return [
      "questionItemId": noncanonical
        ? String(decoding: identifier, as: UTF8.self).replacingOccurrences(of: ",", with: ", ")
        : String(decoding: identifier, as: UTF8.self),
      "question": "PRIVATE_QUESTION", "answer": "PRIVATE_ANSWER",
    ]
  }
  let data = try JSONSerialization.data(withJSONObject: rows)
  return "<send_user_message_question_reply>" + String(decoding: data, as: UTF8.self)
    + "</send_user_message_question_reply>"
}

private var asyncItemsPath: [Any] {
  ["turnHistory", "history", "entitiesByKey", "tail:fixture", "items"]
}

@Test func desktopAsyncQuestionsNeedAttentionWithoutRuntimeFlagsOrRequests() {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let asyncMutationResult1 = projection.acceptSnapshot(canonicalAsyncState(), revision: 1)
  #expect(asyncMutationResult1)
  #expect(projection.requestKinds.isEmpty)
  #expect(projection.record(at: Date()).state == .needsYou)
  #expect(projection.record(at: Date()).reason == "Question for you")
  #expect(!String(describing: projection).contains("PRIVATE"))
  // The sidebar's async predicate is independent of the runtime flag field.
  let asyncMutationResult2 = projection.acceptPatches(
    [
      ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]]
    ], base: 1, revision: 2)
  #expect(asyncMutationResult2)
  #expect(projection.record(at: Date()).state == .needsYou)
}

@Test func desktopAsyncQuestionPatchesTrackAddsAnswersRemovalAndApprovalFlags() throws {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let asyncMutationResult3 = projection.acceptSnapshot(
    canonicalAsyncState(asyncTurn(questionCount: 0)), revision: 1)
  #expect(asyncMutationResult3)
  #expect(projection.record(at: Date()).state == .working)
  let asyncMutationResult4 = projection.acceptPatches(
    [
      [
        "op": "add", "path": asyncItemsPath + [0, "questions", 0],
        "value": ["question": "PRIVATE_QUESTION"],
      ]
    ], base: 1, revision: 2)
  #expect(asyncMutationResult4)
  #expect(projection.record(at: Date()).state == .needsYou)
  let reply: [String: Any] = [
    "type": "steeringUserMessage", "id": "reply-item", "status": "pending",
    "input": [["type": "text", "text": try asyncReply()]],
  ]
  let asyncMutationResult5 = projection.acceptPatches(
    [
      ["op": "add", "path": asyncItemsPath + [1], "value": reply]
    ], base: 2, revision: 3)
  #expect(asyncMutationResult5)
  #expect(projection.record(at: Date()).state == .needsYou)
  let asyncMutationResult6 = projection.acceptPatches(
    [
      ["op": "replace", "path": asyncItemsPath + [1, "status"], "value": "accepted"]
    ], base: 3, revision: 4)
  #expect(asyncMutationResult6)
  #expect(projection.record(at: Date()).state == .working)
  #expect(!String(describing: projection).contains("PRIVATE"))
  let asyncMutationResult7 = projection.acceptPatches(
    [
      ["op": "remove", "path": asyncItemsPath + [1]]
    ], base: 4, revision: 5)
  #expect(asyncMutationResult7)
  #expect(projection.record(at: Date()).state == .needsYou)
  let asyncMutationResult8 = projection.acceptPatches(
    [
      ["op": "remove", "path": asyncItemsPath + [0, "questions", 0]],
      [
        "op": "replace", "path": ["threadRuntimeStatus"],
        "value": ["type": "active", "activeFlags": ["waitingOnApproval"]],
      ],
    ], base: 5, revision: 6)
  #expect(asyncMutationResult8)
  #expect(projection.record(at: Date()).state == .needsYou)
  #expect(projection.record(at: Date()).reason == "Approval required")
}

@Test func desktopAsyncQuestionAnswersMatchEachExactQuestionAndClearOnLatestTurnCompletion() throws
{
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  var turn = asyncTurn(questionCount: 2)
  var items = try #require(turn["items"] as? [[String: Any]])
  items.append([
    "type": "userMessage", "id": "reply",
    "content": [["type": "text", "text": try asyncReply([0])]],
  ])
  turn["items"] = items
  let asyncMutationResult9 = projection.acceptSnapshot(canonicalAsyncState(turn), revision: 1)
  #expect(asyncMutationResult9)
  #expect(projection.record(at: Date()).state == .needsYou)
  let asyncMutationResult10 = projection.acceptPatches(
    [
      [
        "op": "replace", "path": asyncItemsPath + [1, "content", 0, "text"],
        "value": try asyncReply([0, 1]),
      ]
    ], base: 1, revision: 2)
  #expect(asyncMutationResult10)
  #expect(projection.record(at: Date()).state == .working)
  let asyncMutationResult11 = projection.acceptPatches(
    [
      ["op": "remove", "path": asyncItemsPath + [1]],
      [
        "op": "replace",
        "path": ["turnHistory", "history", "entitiesByKey", "tail:fixture", "status"],
        "value": "completed",
      ],
      ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]],
    ], base: 2, revision: 3)
  #expect(asyncMutationResult11)
  // The shipped sidebar only considers its latest in-progress turn.
  #expect(projection.record(at: Date()).state == .idle)
}

@Test func desktopAsyncLatestTurnOrderingAndLegacyTurnsMatchShippedPredicate() {
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let state: [String: Any] = [
    "id": "fixture", "threadRuntimeStatus": ["type": "active", "activeFlags": [] as [String]],
    "turns": [asyncTurn("older"), asyncTurn("newer", questionCount: 0)],
  ]
  let asyncMutationResult12 = projection.acceptSnapshot(state, revision: 1)
  #expect(asyncMutationResult12)
  #expect(projection.record(at: Date()).state == .working)
  let asyncMutationResult13 = projection.acceptPatches(
    [
      ["op": "remove", "path": ["turns", 1]]
    ], base: 1, revision: 2)
  #expect(asyncMutationResult13)
  #expect(projection.record(at: Date()).state == .needsYou)
  let asyncMutationResult14 = projection.acceptPatches(
    [
      ["op": "replace", "path": ["turns"], "value": [] as [Any]]
    ], base: 2, revision: 3)
  #expect(asyncMutationResult14)
  #expect(projection.record(at: Date()).state == .working)
}

@Test func desktopAsyncMultipartResponsesAndAcknowledgedSteeringAreRecognized() throws {
  var turn = asyncTurn()
  var items = try #require(turn["items"] as? [[String: Any]])
  let reply = try asyncReply()
  let split = reply.index(reply.startIndex, offsetBy: "<send_user_message_question_reply>".count)
  items.append([
    "type": "steeringUserMessage", "id": "reply", "status": "pending", "steerAcknowledged": true,
    "input": [
      ["type": "text", "text": String(reply[..<split])],
      ["type": "text", "text": String(reply[split...])],
    ],
  ])
  turn["items"] = items
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let asyncMutationResult15 = projection.acceptSnapshot(canonicalAsyncState(turn), revision: 1)
  #expect(asyncMutationResult15)
  #expect(projection.record(at: Date()).state == .working)
  #expect(!String(describing: projection).contains("PRIVATE"))
  // No body fragments are retained to guess the outcome of a multipart mutation.
  let asyncMutationResult16 = !projection.acceptPatches(
    [
      ["op": "replace", "path": asyncItemsPath + [1, "input", 0, "text"], "value": "other text"]
    ], base: 1, revision: 2)
  #expect(asyncMutationResult16)
  #expect(projection.record(at: Date()).state == .unknown)
  let asyncMutationResult17 = projection.acceptSnapshot(canonicalAsyncState(), revision: 3)
  #expect(asyncMutationResult17)
  #expect(projection.record(at: Date()).state == .needsYou)
}

@Test func desktopAsyncQuestionMetadataHasBoundsAndNeverRetainsToolBodies() {
  var turn = asyncTurn()
  turn["items"] = [
    ["type": "mcpToolCall", "id": "tool", "content": [["value": "PRIVATE_SECRET_BODY"]]],
    ["type": "agentMessage", "id": "question-item", "questions": [["title": "PRIVATE_QUESTION"]]],
  ]
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let asyncMutationResult18 = projection.acceptSnapshot(canonicalAsyncState(turn), revision: 1)
  #expect(asyncMutationResult18)
  #expect(!String(describing: projection).contains("PRIVATE"))
  let asyncMutationResult19 = !projection.acceptSnapshot(
    canonicalAsyncState(asyncTurn(questionCount: 33)), revision: 2)
  #expect(asyncMutationResult19)
  #expect(projection.record(at: Date()).state == .unknown)
}

@Test func desktopAsyncRepliesRequireExactCanonicalQuestionIDs() throws {
  var turn = asyncTurn()
  var items = try #require(turn["items"] as? [[String: Any]])
  items.append([
    "type": "userMessage", "id": "reply",
    "content": [["type": "text", "text": try asyncReply(noncanonical: true)]],
  ])
  turn["items"] = items
  var projection = CodexIPCProjection(id: "fixture", host: "local")
  let accepted = projection.acceptSnapshot(canonicalAsyncState(turn), revision: 1)
  #expect(accepted)
  #expect(projection.record(at: Date()).state == .needsYou)
}
