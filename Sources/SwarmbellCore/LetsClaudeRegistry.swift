import Darwin
import Foundation

/// Lets gives its Claude SDK processes a separate config directory per profile.
/// Read only the PID registration files. Profile settings, keys and transcripts
/// are outside the observer's scope.
struct LetsClaudeRegistry: Sendable {
  let root: URL
  let ownsProcess: @Sendable (Int, String) -> Bool

  init(
    root: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".lets/agents/claude", isDirectory: true),
    ownsProcess: @escaping @Sendable (Int, String) -> Bool = Self.isLiveLetsProcess
  ) {
    self.root = root
    self.ownsProcess = ownsProcess
  }

  func read() -> (sessions: [ClaudeProvider.Session], incomplete: Bool) {
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    let decoder = JSONDecoder()
    var sessions: [ClaudeProvider.Session] = []
    var incomplete = false
    do {
      let profiles = try manager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
      incomplete = profiles.count > 32
      for profile in profiles.prefix(32) {
        guard profile.lastPathComponent.hasPrefix("cred"),
          let values = try? profile.resourceValues(forKeys: keys),
          values.isDirectory == true, values.isSymbolicLink != true
        else { continue }
        let directory = profile.appendingPathComponent("sessions", isDirectory: true)
        do {
          let values = try directory.resourceValues(forKeys: keys)
          guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
          let files = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
          if files.count > 512 { incomplete = true }
          for file in files.prefix(512) {
            guard file.pathExtension == "json",
              let pid = Int(file.deletingPathExtension().lastPathComponent),
              let values = try? file.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 16_384,
              let handle = try? FileHandle(forReadingFrom: file)
            else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 16_385), data.count <= 16_384,
              let session = try? decoder.decode(ClaudeProvider.Session.self, from: data),
              session.pid == pid, session.pidDomain == "darwin", session.entrypoint == "sdk-cli",
              let id = session.sessionId, UUID(uuidString: id) != nil,
              let start = session.procStart, ownsProcess(pid, start)
            else { continue }
            sessions.append(session)
          }
        } catch let error as CocoaError
          where error.code == .fileReadNoSuchFile
          || error.code == .fileNoSuchFile
        {
          continue
        } catch {
          incomplete = true
        }
      }
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile
      || error.code == .fileNoSuchFile
    {
      // Lets has not created a Claude profile.
    } catch {
      incomplete = true
    }
    return (sessions, incomplete)
  }

  private static func isLiveLetsProcess(_ pid: Int, _ start: String) -> Bool {
    guard pid > 1, pid <= Int(Int32.max) else { return false }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size,
      info.pbi_status != SZOMB
    else { return false }
    // Claude 2.1.296 persists the Darwin process start time in UTC, to the second.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    guard formatter.date(from: start)?.timeIntervalSince1970 == Double(info.pbi_start_tvsec)
    else { return false }
    return ClaudeNavigationResolver.isManaged(pid, appName: "Lets", bundleID: "dev.lets")
  }
}
