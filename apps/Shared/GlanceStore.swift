import Foundation

/// Counts only, shared with extensions on this device. WatchConnectivity bridges devices.
struct GlanceStore: Sendable {
  static let shared = GlanceStore()
  private let directory: URL?

  enum StoreError: Error {
    case containerUnavailable, invalidFile
  }

  init(directory: URL? = Self.defaultDirectory) {
    self.directory = directory
  }

  static var defaultDirectory: URL? {
    #if os(iOS) || os(watchOS)
      FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: GlanceConstants.appGroup)?
        .appendingPathComponent("Library/SwarmbellGlance", isDirectory: true)
    #else
      nil
    #endif
  }

  private var fileURL: URL? { directory?.appendingPathComponent("counts-v1.json") }

  func load() -> GlanceSnapshot? {
    guard let fileURL,
      let values = try? fileURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]),
      values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= GlanceSnapshot.maximumEncodedBytes,
      let data = try? Data(contentsOf: fileURL)
    else { return nil }
    return try? GlanceSnapshot.decode(data)
  }

  /// Rejects invalid or older observations without replacing the last good file.
  @discardableResult
  func save(_ snapshot: GlanceSnapshot) throws -> Bool {
    try snapshot.validate()
    guard let directory, let fileURL else { throw StoreError.containerUnavailable }
    if let previous = load() {
      guard snapshot.observedAt >= previous.observedAt else { return false }
      if snapshot.observedAt == previous.observedAt {
        guard snapshot.receivedAt >= previous.receivedAt, snapshot != previous else { return false }
      }
    }
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if manager.fileExists(atPath: fileURL.path) {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw StoreError.invalidFile
      }
    }
    let data = try snapshot.encodedData()
    #if os(iOS) || os(watchOS)
      // Deliberately readable after first unlock so Lock Screen counts can update.
      // No credentials or conversation content are stored in this file.
      try data.write(
        to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: fileURL, options: .atomic)
    #endif
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    return true
  }

  func clear() throws {
    guard let fileURL else { throw StoreError.containerUnavailable }
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }
}
