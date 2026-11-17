import AppKit
import Foundation
import SwarmbellCore

@MainActor
enum AgentNavigation {
  static func copyID(_ agent: AgentRecord, model: AppModel) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(agent.sessionID, forType: .string)
    model.navigationMessage = "Copied \(agent.harness.displayName) session ID."
  }

  static func revealProject(_ agent: AgentRecord) {
    guard let workspace = agent.workspace else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace)])
  }

  @discardableResult
  static func openApplication(_ agent: AgentRecord, model: AppModel) -> Bool {
    if let url = desktopURL(for: agent) {
      if NSWorkspace.shared.open(url) {
        model.navigationMessage = nil
        return true
      }
      copyID(agent, model: model)
      model.navigationMessage =
        "Could not open the selected \(agent.harness.displayName) conversation. Its session ID was copied."
      return false
    }
    copyID(agent, model: model)
    model.navigationMessage =
      "An exact conversation link is not available for this session. Its ID was copied."
    return false
  }

  private static func desktopURL(for agent: AgentRecord) -> URL? {
    guard agent.navigation.kind == .openDesktopThread else { return nil }
    switch agent.harness {
    case .codex:
      return CodexDesktopProvider.threadURL(sessionID: agent.sessionID, host: agent.host)
    case .claudeCode:
      guard let value = agent.navigation.url, let parts = URLComponents(string: value),
        parts.scheme == "claude", parts.host == "code", parts.path == "/continue",
        parts.queryItems?.count == 1, parts.queryItems?.first?.name == "session",
        let id = parts.queryItems?.first?.value,
        let expected = ClaudeNavigationResolver.desktopThreadURL(localSessionID: id),
        expected.absoluteString == value
      else { return nil }
      return expected
    case .cursor:
      return nil
    }
  }
}
