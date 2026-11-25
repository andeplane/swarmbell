import Darwin
import Foundation

public struct ClaudeNavigationDestination: Sendable {
  public var navigation: Navigation
  public var title: String?
}

/// Resolves an already-running Claude Code process to the conversation which owns it
/// in Claude Desktop. The CLI UUID is not the Desktop's `local_` session identifier.
public actor ClaudeNavigationResolver {
  public static var defaultSessionsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
  }

  private let sessionsDirectory: URL
  private let desktopOwnerCheck: @Sendable (Int) -> Bool
  private var records: [URL: CachedRecord] = [:]
  private var lastScan: ContinuousClock.Instant?

  public init(
    sessionsDirectory: URL = ClaudeNavigationResolver.defaultSessionsDirectory,
    desktopOwnerCheck: @escaping @Sendable (Int) -> Bool = {
      ClaudeNavigationResolver.isDesktopManaged($0)
    }
  ) {
    self.sessionsDirectory = sessionsDirectory.standardizedFileURL
    self.desktopOwnerCheck = desktopOwnerCheck
  }

  /// Returns no target when the original UI cannot be proved. Callers must not
  /// replace this with launching Terminal or resuming an additional writer.
  public func resolve(sessionID: String, processID: Int?) -> Navigation? {
    resolveDestination(sessionID: sessionID, processID: processID)?.navigation
  }

  public func resolveDestination(sessionID: String, processID: Int?) -> ClaudeNavigationDestination?
  {
    guard UUID(uuidString: sessionID) != nil, let processID, processID > 1,
      desktopOwnerCheck(processID)
    else { return nil }
    refreshIndexIfNeeded()
    let matches = records.values.compactMap(\.metadata).filter {
      $0.cliSessionId == sessionID && $0.isArchived != true
    }
    guard matches.count == 1, let target = matches.first,
      let url = Self.desktopThreadURL(localSessionID: target.sessionId)
    else { return nil }
    let title = target.title.flatMap { value -> String? in
      let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : String(text.prefix(512))
    }
    return .init(
      navigation: .init(
        kind: .openDesktopThread,
        explanation:
          "Open the existing Claude Desktop conversation which owns this running session.",
        url: url.absoluteString), title: title)
  }

  /// Observed in Claude Desktop 5.11492.5: the handler looks up an existing local
  /// session and navigates to getSessionRoute(). It does not start/resume a turn.
  public nonisolated static func desktopThreadURL(localSessionID: String) -> URL? {
    guard localSessionID.hasPrefix("local_"),
      UUID(uuidString: String(localSessionID.dropFirst(6))) != nil
    else { return nil }
    var value = URLComponents()
    value.scheme = "claude"
    value.host = "code"
    value.path = "/continue"
    value.queryItems = [.init(name: "session", value: localSessionID)]
    return value.url
  }

  /// Uses PID/path/parent metadata only, never process arguments or environment.
  /// A Terminal-hosted CLI with a similarly named saved Desktop record is not a match.
  public nonisolated static func isDesktopManaged(_ processID: Int) -> Bool {
    isManaged(processID, appName: "Claude", bundleID: "com.anthropic.claudefordesktop")
  }

  nonisolated static func isManaged(_ processID: Int, appName: String, bundleID: String) -> Bool {
    guard processID > 1, processID <= Int(Int32.max) else { return false }
    var current = Int32(processID)
    var visited = Set<Int32>()
    for _ in 0..<12 {
      guard current > 1, visited.insert(current).inserted else { return false }
      var info = proc_bsdinfo()
      let expected = Int32(MemoryLayout.size(ofValue: info))
      guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, expected) == expected else {
        return false
      }
      var path = [CChar](repeating: 0, count: 4096)
      if proc_pidpath(current, &path, UInt32(path.count)) > 0 {
        let executable = String(
          decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if executable.hasSuffix("/\(appName).app/Contents/MacOS/\(appName)") {
          let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Info.plist")
          guard let data = try? Data(contentsOf: bundle),
            let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any]
          else { return false }
          return dictionary["CFBundleIdentifier"] as? String == bundleID
        }
      }
      current = Int32(info.pbi_ppid)
    }
    return false
  }

  private struct Metadata: Decodable {
    var sessionId: String
    var cliSessionId: String?
    var isArchived: Bool?
    var title: String?
  }
  private struct CachedRecord {
    var modifiedAt: Date?
    var size: Int
    var metadata: Metadata?
  }

  private func refreshIndexIfNeeded() {
    let now = ContinuousClock.now
    if let lastScan, lastScan.duration(to: now) < .seconds(2) { return }
    lastScan = now
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    guard
      let enumerator = manager.enumerator(
        at: sessionsDirectory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else {
      records.removeAll()
      return
    }
    var next: [URL: CachedRecord] = [:]
    var examined = 0
    for case let file as URL in enumerator {
      examined += 1
      // Refuse ambiguous partial discovery rather than selecting a possibly duplicate target.
      guard examined <= 20_000 else {
        records.removeAll()
        return
      }
      // The enumerator may return /private/var for a /var root, while Foundation
      // URL normalization preserves /var. Its structural depth is alias-independent.
      let depth = enumerator.level
      if depth > 3 {
        enumerator.skipDescendants()
        continue
      }
      guard depth == 3, file.pathExtension == "json",
        let url = Self.desktopThreadURL(
          localSessionID: file.deletingPathExtension().lastPathComponent),
        url.scheme == "claude",
        let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
        values.isSymbolicLink != true, let size = values.fileSize, size <= 1_048_576
      else { continue }
      if let cached = records[file], cached.metadata != nil,
        cached.modifiedAt == values.contentModificationDate,
        cached.size == size
      {
        next[file] = cached
        continue
      }
      let data = try? Data(contentsOf: file)
      let parsed = data.flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
      let verified = parsed.flatMap {
        $0.sessionId == file.deletingPathExtension().lastPathComponent ? $0 : nil
      }
      next[file] = .init(modifiedAt: values.contentModificationDate, size: size, metadata: verified)
    }
    records = next
  }
}
