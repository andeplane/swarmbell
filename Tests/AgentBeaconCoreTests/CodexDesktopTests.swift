import Foundation
import Testing

@testable import AgentBeaconCore

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
  let id = "01a1df68-9ae6-7a63-8b90-78e39a64445b"
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
