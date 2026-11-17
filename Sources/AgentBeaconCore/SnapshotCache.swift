import Darwin
import Foundation

public enum SnapshotCacheError: Error, LocalizedError, Sendable {
  case unavailable, unsafePath, unsafeFile, alreadyOwned, invalidIdentity, invalidSnapshot
  case unsupportedVersion, oversized, ioFailure, sequenceExhausted

  public var errorDescription: String? {
    switch self {
    case .unavailable: "No current Agent Beacon snapshot is available."
    case .unsafePath: "The snapshot cache directory is not a private, owned real directory."
    case .unsafeFile: "A snapshot cache file is not a private, owned regular file."
    case .alreadyOwned: "Another writer already owns this snapshot cache."
    case .invalidIdentity: "The snapshot cache identity is missing, corrupt or inconsistent."
    case .invalidSnapshot: "The snapshot cache contains invalid observations or timestamps."
    case .unsupportedVersion: "The snapshot cache version is not supported."
    case .oversized: "The snapshot cache exceeds the supported size limit."
    case .ioFailure: "The snapshot cache could not be read or published safely."
    case .sequenceExhausted: "The snapshot cache sequence is exhausted; start a new writer run."
    }
  }
}

public struct SnapshotCacheEnvelope: Codable, Sendable {
  public var schemaVersion: Int = 1
  public var collectorId: UUID
  public var runId: UUID
  public var sequence: UInt64
  public var observedAt: Date
  public var publishedAt: Date
  public var expectedRefreshIntervalSeconds: Double
  public var snapshot: MonitorSnapshot
}

public enum SnapshotCacheAvailability: String, Codable, Sendable { case current, stale }

public struct SnapshotCacheReadResult: Codable, Sendable {
  public var availability: SnapshotCacheAvailability
  /// Age of the observation, not the publication or reader invocation.
  public var ageSeconds: Double
  public var envelope: SnapshotCacheEnvelope

  public func jsonData() throws -> Data { try CacheFiles.encoder().encode(self) }
}

/// The app's existing collector is the sole publisher. Initialization acquires a
/// lifetime exclusive lease; it does not publish or refresh any observation.
/// NSLock protects the sequence and descriptor operations across callers.
public final class SnapshotCacheWriter: @unchecked Sendable {
  public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(
      "Library/Application Support/AgentBeacon/snapshot-cache", isDirectory: true)
  public static let maximumPayloadBytes = 8 * 1_024 * 1_024
  public let collectorId: UUID
  public let runId: UUID
  private let directoryFD: Int32
  private let lockFD: Int32
  private let interval: Double
  private let mutex = NSLock()
  private var sequence: UInt64 = 0

  public init(
    directory: URL = SnapshotCacheWriter.defaultDirectory,
    expectedRefreshIntervalSeconds: Double = 5
  ) throws {
    guard expectedRefreshIntervalSeconds.isFinite,
      expectedRefreshIntervalSeconds > 0, expectedRefreshIntervalSeconds <= 300
    else { throw SnapshotCacheError.invalidSnapshot }
    let directoryFD = try CacheFiles.openDirectory(directory, create: true)
    var lease: Int32 = -1
    var accepted = false
    defer {
      if !accepted {
        if lease >= 0 { Darwin.close(lease) }
        Darwin.close(directoryFD)
      }
    }
    lease = openat(directoryFD, "writer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lease >= 0 else { throw SnapshotCacheError.unsafeFile }
    try CacheFiles.validateFile(lease)
    guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
      throw errno == EWOULDBLOCK ? SnapshotCacheError.alreadyOwned : .ioFailure
    }
    let identity: CacheFiles.Identity
    if let data = try CacheFiles.read(directoryFD, "identity.json", maximum: 1_024) {
      identity = try CacheFiles.decodeIdentity(data)
    } else {
      guard try !CacheFiles.exists(directoryFD, "current.json") else {
        throw SnapshotCacheError.invalidIdentity
      }
      identity = .init(schemaVersion: 1, collectorId: UUID())
      try CacheFiles.write(CacheFiles.encoder().encode(identity), directoryFD, "identity.json")
    }
    // Reject unsafe existing publication files before accepting ownership.
    _ = try CacheFiles.read(directoryFD, "current.json", maximum: Self.maximumPayloadBytes)
    self.directoryFD = directoryFD
    lockFD = lease
    collectorId = identity.collectorId
    runId = UUID()
    interval = expectedRefreshIntervalSeconds
    accepted = true
  }

  deinit {
    flock(lockFD, LOCK_UN)
    Darwin.close(lockFD)
    Darwin.close(directoryFD)
  }

  @discardableResult
  public func publish(snapshot: MonitorSnapshot, at date: Date = Date()) throws
    -> SnapshotCacheEnvelope
  {
    mutex.lock()
    defer { mutex.unlock() }
    guard sequence < UInt64.max else { throw SnapshotCacheError.sequenceExhausted }
    let envelope = SnapshotCacheEnvelope(
      collectorId: collectorId, runId: runId, sequence: sequence + 1,
      observedAt: snapshot.generatedAt, publishedAt: date,
      expectedRefreshIntervalSeconds: interval, snapshot: snapshot)
    try CacheFiles.validateEnvelope(envelope)
    let data = try CacheFiles.encoder().encode(envelope)
    guard data.count <= Self.maximumPayloadBytes else { throw SnapshotCacheError.oversized }
    try CacheFiles.validateLease(directoryFD, lockFD)
    guard let identityData = try CacheFiles.read(directoryFD, "identity.json", maximum: 1_024),
      try CacheFiles.decodeIdentity(identityData).collectorId == collectorId
    else { throw SnapshotCacheError.invalidIdentity }
    // Rename may succeed before directory fsync fails. Consume the sequence before
    // publication so an uncertain write can never cause a visible sequence reuse.
    sequence = envelope.sequence
    try CacheFiles.write(data, directoryFD, "current.json")
    return envelope
  }
}

public enum SnapshotCacheReader {
  public static let defaultDirectory = SnapshotCacheWriter.defaultDirectory

  /// Opens existing files read-only. Never creates paths, obtains a writer lease,
  /// touches history/credentials or starts a collector.
  public static func read(
    directory: URL = defaultDirectory, now: Date = Date()
  ) throws -> SnapshotCacheReadResult {
    let fd = try CacheFiles.openDirectory(directory, create: false)
    defer { Darwin.close(fd) }
    guard
      let data = try CacheFiles.read(
        fd, "current.json", maximum: SnapshotCacheWriter.maximumPayloadBytes)
    else { throw SnapshotCacheError.unavailable }
    guard let identityData = try CacheFiles.read(fd, "identity.json", maximum: 1_024) else {
      throw SnapshotCacheError.invalidIdentity
    }
    let identity = try CacheFiles.decodeIdentity(identityData)
    let envelope: SnapshotCacheEnvelope
    do { envelope = try CacheFiles.decoder().decode(SnapshotCacheEnvelope.self, from: data) } catch
    { throw SnapshotCacheError.invalidSnapshot }
    try CacheFiles.validateEnvelope(envelope)
    guard envelope.collectorId == identity.collectorId else {
      throw SnapshotCacheError.invalidIdentity
    }
    let age = now.timeIntervalSince(envelope.observedAt)
    guard age.isFinite, age >= -30,
      envelope.publishedAt.timeIntervalSince(now) <= 30
    else { throw SnapshotCacheError.invalidSnapshot }
    return .init(
      availability: age > max(15, 3 * envelope.expectedRefreshIntervalSeconds) ? .stale : .current,
      ageSeconds: max(0, age), envelope: envelope)
  }
}

private enum CacheFiles {
  struct Identity: Codable {
    var schemaVersion: Int
    var collectorId: UUID
  }

  static func encoder() -> JSONEncoder {
    let value = JSONEncoder()
    value.outputFormatting = [.sortedKeys]
    value.dateEncodingStrategy = .custom { date, encoder in
      guard date.timeIntervalSince1970.isFinite else { throw SnapshotCacheError.invalidSnapshot }
      var container = encoder.singleValueContainer()
      let whole = floor(date.timeIntervalSince1970)
      let base = Date(timeIntervalSince1970: whole)
      let nanoseconds = Int64((date.timeIntervalSince(base) * 1_000_000_000).rounded())
      let carriedBase = nanoseconds == 1_000_000_000 ? base.addingTimeInterval(1) : base
      let fraction = nanoseconds == 1_000_000_000 ? 0 : nanoseconds
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      let prefix = formatter.string(from: carriedBase).dropLast()
      try container.encode(String(prefix) + String(format: ".%09lldZ", fraction))
    }
    return value
  }

  static func decoder() -> JSONDecoder {
    let value = JSONDecoder()
    value.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      if text.hasSuffix("Z"), let dot = text.lastIndex(of: ".") {
        let fraction = text[text.index(after: dot)..<text.index(before: text.endIndex)]
        guard (1...9).contains(fraction.count),
          fraction.allSatisfy({ $0.isASCII && $0.isNumber }),
          let nanoseconds = UInt32(fraction),
          let base = formatter.date(from: String(text[..<dot]) + "Z")
        else { throw SnapshotCacheError.invalidSnapshot }
        return base.addingTimeInterval(Double(nanoseconds) / pow(10, Double(fraction.count)))
      }
      guard let date = formatter.date(from: text) else { throw SnapshotCacheError.invalidSnapshot }
      return date
    }
    return value
  }

  static func decodeIdentity(_ data: Data) throws -> Identity {
    guard let value = try? decoder().decode(Identity.self, from: data), value.schemaVersion == 1
    else {
      throw SnapshotCacheError.invalidIdentity
    }
    return value
  }

  static func validateEnvelope(_ value: SnapshotCacheEnvelope) throws {
    guard value.schemaVersion == 1, value.snapshot.schemaVersion == 1 else {
      throw SnapshotCacheError.unsupportedVersion
    }
    guard value.sequence > 0, value.expectedRefreshIntervalSeconds.isFinite,
      value.expectedRefreshIntervalSeconds > 0, value.expectedRefreshIntervalSeconds <= 300,
      value.observedAt.timeIntervalSince1970.isFinite,
      value.publishedAt.timeIntervalSince1970.isFinite,
      value.observedAt == value.snapshot.generatedAt,
      value.observedAt.timeIntervalSince(value.publishedAt) <= 30
    else { throw SnapshotCacheError.invalidSnapshot }
  }

  static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
      throw SnapshotCacheError.unsafePath
    }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw SnapshotCacheError.ioFailure }
    do {
      for component in url.pathComponents where component != "/" {
        var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0, errno == ENOENT, create {
          guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else {
            throw SnapshotCacheError.ioFailure
          }
          next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard next >= 0 else {
          throw errno == ENOENT ? SnapshotCacheError.unavailable : .unsafePath
        }
        Darwin.close(fd)
        fd = next
      }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
        info.st_mode & 0o7777 == 0o700,
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
      else { throw SnapshotCacheError.unsafePath }
      return fd
    } catch {
      Darwin.close(fd)
      throw error
    }
  }

  static func validateFile(_ fd: Int32, allowUnlinked: Bool = false) throws {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
      info.st_nlink == 1 || (allowUnlinked && info.st_nlink == 0),
      info.st_mode & 0o7777 == 0o600,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else { throw SnapshotCacheError.unsafeFile }
  }

  static func validateLease(_ directory: Int32, _ lease: Int32) throws {
    try validateFile(lease)
    var held = stat()
    var named = stat()
    guard fstat(lease, &held) == 0,
      fstatat(directory, "writer.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
      held.st_dev == named.st_dev, held.st_ino == named.st_ino
    else { throw SnapshotCacheError.unsafeFile }
  }

  static func exists(_ directory: Int32, _ name: String) throws -> Bool {
    var info = stat()
    if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
    guard errno == ENOENT else { throw SnapshotCacheError.ioFailure }
    return false
  }

  static func read(_ directory: Int32, _ name: String, maximum: Int) throws -> Data? {
    let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ENOENT { return nil }
      throw SnapshotCacheError.unsafeFile
    }
    defer { Darwin.close(fd) }
    // Atomic replacement can unlink the old inode after this reader opens it.
    // That already-open private inode remains a valid snapshot; hard links do not.
    try validateFile(fd, allowUnlinked: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_size >= 0 else { throw SnapshotCacheError.ioFailure }
    guard info.st_size <= maximum else { throw SnapshotCacheError.oversized }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = Darwin.read(fd, &buffer, min(buffer.count, maximum + 1 - data.count))
      if count < 0 {
        if errno == EINTR { continue }
        throw SnapshotCacheError.ioFailure
      }
      if count == 0 { return data }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= maximum else { throw SnapshotCacheError.oversized }
    }
  }

  static func write(_ data: Data, _ directory: Int32, _ name: String) throws {
    // Validate any destination before replacing it; never repair unsafe state silently.
    _ = try read(directory, name, maximum: SnapshotCacheWriter.maximumPayloadBytes)
    let temporary = ".snapshot-\(UUID().uuidString).tmp"
    let fd = openat(
      directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SnapshotCacheError.ioFailure }
    defer {
      Darwin.close(fd)
      unlinkat(directory, temporary, 0)
    }
    try validateFile(fd)
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw SnapshotCacheError.ioFailure }
        offset += count
      }
    }
    guard fsync(fd) == 0,
      renameat(directory, temporary, directory, name) == 0,
      fsync(directory) == 0
    else { throw SnapshotCacheError.ioFailure }
  }
}
