import Foundation

/// Memory-plugin implementation sessions are not user coding conversations.
/// Match the known private working directory, never a title or harness alone.
public enum InternalSessions {
  public static let memoryObserverDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude-mem/observer-sessions", isDirectory: true)

  public static func isMemoryObserver(
    workspace: String?, root: URL = memoryObserverDirectory
  ) -> Bool {
    guard let workspace, workspace.hasPrefix("/"), !workspace.contains("\0") else {
      return false
    }
    let base = root.standardizedFileURL.pathComponents
    let candidate = URL(fileURLWithPath: workspace).standardizedFileURL.pathComponents
    guard candidate.starts(with: base) else { return false }
    if candidate.count == base.count { return true }
    let session = candidate[base.count]
    return !session.isEmpty && session.allSatisfy { $0.isASCII && $0.isNumber }
  }
}
