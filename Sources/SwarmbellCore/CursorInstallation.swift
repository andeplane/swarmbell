import CoreFoundation
import Darwin
import Foundation

public struct CursorInstallationResult: Sendable {
  public var configurationURL: URL
  public var eventDirectory: URL
  public var backupURL: URL?
  public var changed: Bool
  public var installedHookCount: Int
}

/// Installs only passive lifecycle observers. Existing Cursor/plugin hooks are
/// preserved in their original array order, including their unknown fields.
public enum CursorHookInstaller {
  public static let markerFileName = ".observer-ready"
  // Stable ownership and locking let upgrades replace only our existing hooks.
  public static let ownershipFlag = "--agent-beacon-observer"
  public static var defaultConfigurationURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/hooks.json")
  }
  public static var defaultBackupDirectoryURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/AgentBeacon/cursor-hook-backups")
  }

  public static func install(
    executableURL: URL,
    configurationURL: URL? = nil,
    eventDirectory: URL = CursorSpool.defaultDirectory,
    backupDirectoryURL: URL? = nil
  ) throws -> CursorInstallationResult {
    let configuration = (configurationURL ?? defaultConfigurationURL).standardizedFileURL
    let executable = executableURL.standardizedFileURL
    try validateLocalURL(configuration)
    try validateLocalURL(executable)
    try validateLocalURL(eventDirectory)
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw SwarmbellError("The bundled Cursor observer helper is missing or is not executable")
    }
    let lock = try ConfigurationLock(configuration: configuration)
    defer { lock.unlock() }
    let original = try Configuration.read(configuration)
    var hooks = original.hooks
    removeOwnedHooks(from: &hooks)
    for event in CursorEvent.observedHooks {
      let command =
        shellQuote(executable.path) + " --cursor-hook --hook-event "
        + shellQuote(event) + " --cursor-events " + shellQuote(eventDirectory.path)
        + " " + ownershipFlag
      hooks[event, default: []].append(["command": command])
    }
    var root = original.root
    root["hooks"] = hooks
    let changed = !NSDictionary(dictionary: root).isEqual(to: original.root)
    var backup: URL?
    if changed {
      backup = try original.backup(to: backupDirectoryURL ?? defaultBackupDirectoryURL)
      try atomicWrite(
        try serialized(root), to: configuration, permissions: original.permissions,
        expected: original.bytes)
    }
    try writeReadyMarker(
      configuration: configuration, executable: executable,
      eventDirectory: eventDirectory)
    return .init(
      configurationURL: configuration, eventDirectory: eventDirectory,
      backupURL: backup, changed: changed, installedHookCount: CursorEvent.observedHooks.count)
  }

  /// Removes only commands carrying this installer's ownership marker. It never
  /// restores a whole backup over changes made later by Cursor or other plugins.
  public static func uninstall(
    configurationURL: URL? = nil,
    eventDirectory: URL = CursorSpool.defaultDirectory,
    backupDirectoryURL: URL? = nil
  ) throws -> CursorInstallationResult {
    let configuration = (configurationURL ?? defaultConfigurationURL).standardizedFileURL
    try validateLocalURL(configuration)
    try validateLocalURL(eventDirectory)
    let lock = try ConfigurationLock(configuration: configuration)
    defer { lock.unlock() }
    let original = try Configuration.read(configuration)
    var hooks = original.hooks
    removeOwnedHooks(from: &hooks)
    var root = original.root
    if root["hooks"] != nil { root["hooks"] = hooks }
    let changed = !NSDictionary(dictionary: root).isEqual(to: original.root)
    var backup: URL?
    if changed {
      backup = try original.backup(to: backupDirectoryURL ?? defaultBackupDirectoryURL)
      try atomicWrite(
        try serialized(root), to: configuration, permissions: original.permissions,
        expected: original.bytes)
    }
    let removedMarker = try removeReadyMarker(
      configuration: configuration,
      eventDirectory: eventDirectory)
    return .init(
      configurationURL: configuration, eventDirectory: eventDirectory,
      backupURL: backup, changed: changed || removedMarker, installedHookCount: 0)
  }

  private static func owns(_ entry: [String: Any]) -> Bool {
    guard let command = entry["command"] as? String else { return false }
    return command.hasSuffix(" " + ownershipFlag) && command.contains(" --cursor-hook ")
  }

  private static func removeOwnedHooks(from hooks: inout [String: [[String: Any]]]) {
    for event in Array(hooks.keys) {
      let entries = hooks[event] ?? []
      let retained = entries.filter { !owns($0) }
      if retained.count == entries.count { continue }
      if retained.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = retained }
    }
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func validateLocalURL(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\n"),
      !url.path.utf8.contains(0)
    else {
      throw SwarmbellError("Cursor observer paths must be absolute local paths without newlines")
    }
  }

  private static func serialized(_ root: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
      + Data([10])
  }

  private struct Configuration {
    var root: [String: Any]
    var hooks: [String: [[String: Any]]]
    var bytes: Data?
    var permissions: Int

    static func read(_ url: URL) throws -> Self {
      let manager = FileManager.default
      var metadata = stat()
      let status = Darwin.lstat(url.path, &metadata)
      if status != 0, errno == ENOENT {
        return .init(root: ["version": 1], hooks: [:], bytes: nil, permissions: 0o600)
      }
      guard status == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw SwarmbellError(
          "Cursor hooks must be a regular JSON file; symbolic links are not replaced")
      }
      let attributes = try manager.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576
      else { throw SwarmbellError("Cursor hooks must be a regular JSON file no larger than 1 MiB") }
      let bytes = try Data(contentsOf: url)
      guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        let version = root["version"] as? NSNumber,
        CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1
      else {
        throw SwarmbellError(
          "Cursor hooks are malformed or use an unsupported configuration version")
      }
      var hooks: [String: [[String: Any]]] = [:]
      if let value = root["hooks"] {
        guard let object = value as? [String: Any] else {
          throw SwarmbellError("Cursor hooks must be an object containing event arrays")
        }
        for (event, entries) in object {
          guard let array = entries as? [[String: Any]] else {
            throw SwarmbellError("Cursor's existing hook entry for \(event) is malformed")
          }
          hooks[event] = array
        }
      }
      return .init(
        root: root, hooks: hooks, bytes: bytes,
        permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600)
    }

    func backup(to directory: URL) throws -> URL? {
      guard let bytes else { return nil }
      try validateLocalURL(directory)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let file = directory.appendingPathComponent("hooks-\(UUID().uuidString).json")
      try atomicWrite(bytes, to: file, permissions: 0o600, expected: nil)
      return file
    }
  }

  private struct ReadyMarker: Codable {
    var owner = "local.agentbeacon.mac"
    var configurationPath: String
    var executablePath: String
  }

  private static func writeReadyMarker(configuration: URL, executable: URL, eventDirectory: URL)
    throws
  {
    let manager = FileManager.default
    try manager.createDirectory(
      at: eventDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let file = eventDirectory.appendingPathComponent(markerFileName)
    let marker = ReadyMarker(configurationPath: configuration.path, executablePath: executable.path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let encoded = try encoder.encode(marker)
    let previous = try manager.fileExists(atPath: file.path) ? Data(contentsOf: file) : nil
    if previous == encoded { return }
    try atomicWrite(encoded, to: file, permissions: 0o600, expected: previous)
  }

  private static func removeReadyMarker(configuration: URL, eventDirectory: URL) throws -> Bool {
    let file = eventDirectory.appendingPathComponent(markerFileName)
    guard FileManager.default.fileExists(atPath: file.path),
      let marker = try? JSONDecoder().decode(ReadyMarker.self, from: Data(contentsOf: file)),
      marker.owner == "local.agentbeacon.mac", marker.configurationPath == configuration.path
    else { return false }
    try FileManager.default.removeItem(at: file)
    return true
  }

  private static func atomicWrite(
    _ bytes: Data, to destination: URL, permissions: Int,
    expected: Data?
  ) throws {
    let manager = FileManager.default
    let directory = destination.deletingLastPathComponent()
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".swarmbell-\(UUID().uuidString).tmp")
    guard
      manager.createFile(
        atPath: temporary.path, contents: nil,
        attributes: [.posixPermissions: permissions])
    else { throw SwarmbellError("Could not prepare an atomic Cursor configuration write") }
    defer { try? manager.removeItem(at: temporary) }
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      try handle.write(contentsOf: bytes)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    let current =
      try manager.fileExists(atPath: destination.path) ? Data(contentsOf: destination) : nil
    guard current == expected else {
      throw SwarmbellError(
        "Cursor hooks changed during setup; retry without overwriting the new changes")
    }
    guard Darwin.rename(temporary.path, destination.path) == 0 else {
      throw SwarmbellError("Could not atomically replace Cursor observer configuration")
    }
  }

  /// Serializes Swarmbell's own setup calls. A final byte comparison additionally
  /// detects another editor's changes made while the backup/new file was prepared.
  private final class ConfigurationLock {
    private var descriptor: Int32
    init(configuration: URL) throws {
      let directory = configuration.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      descriptor = Darwin.open(
        directory.appendingPathComponent(".agent-beacon-hooks.lock").path,
        O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
      guard descriptor >= 0 else { throw SwarmbellError("Could not lock Cursor observer setup") }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        Darwin.close(descriptor)
        descriptor = -1
        throw SwarmbellError("Another Cursor observer setup is in progress; try again shortly")
      }
    }
    func unlock() {
      if descriptor >= 0 {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
      }
    }
    deinit { unlock() }
  }
}
