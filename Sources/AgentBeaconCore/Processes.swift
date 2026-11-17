import Darwin
import Foundation

public struct CommandResult: Sendable {
  public var data: Data
  public var exitCode: Int32
  public init(data: Data, exitCode: Int32 = 0) {
    self.data = data
    self.exitCode = exitCode
  }
}

public protocol CommandRunning: Sendable {
  func run(executable: String, arguments: [String], timeout: TimeInterval) async throws
    -> CommandResult
}

public struct SystemCommandRunner: CommandRunning {
  public init() {}
  public func run(executable: String, arguments: [String], timeout: TimeInterval) async throws
    -> CommandResult
  {
    try await Task.detached(priority: .utility) {
      let pipe = try BoundedProcess(executable: executable, arguments: arguments, timeout: timeout)
      defer { pipe.close() }
      return try pipe.finish()
    }.value
  }
}

public enum Executables {
  /// GUI applications do not inherit the user's interactive-shell PATH.
  public static func find(_ name: String, override: String? = nil) -> String? {
    let fm = FileManager.default
    if let override { return fm.isExecutableFile(atPath: override) ? override : nil }
    let home = fm.homeDirectoryForCurrentUser.path
    let paths =
      ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
      + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return paths.map { "\($0)/\(name)" }.first { fm.isExecutableFile(atPath: $0) }
  }
}

/// Blocking work lives on utility tasks. Both streams are drained with bounded memory,
/// a monotonic deadline, and hard termination; a noisy or hung CLI cannot freeze the UI.
final class BoundedProcess {
  let process = Process()
  private let input = Pipe(), output = Pipe(), errors = Pipe()
  private let deadline: TimeInterval
  private var buffer = Data()
  private var discardedErrorBytes = 0
  private let limit = 4 * 1024 * 1024

  init(executable: String, arguments: [String], timeout: TimeInterval) throws {
    deadline = ProcessInfo.processInfo.systemUptime + timeout
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    // Avoid depending on the project containing this utility being trusted by a harness.
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    try process.run()
    for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
      let flags = fcntl(handle.fileDescriptor, F_GETFL)
      _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
  }

  func send(_ message: [String: Any]) throws {
    let bytes = try JSONSerialization.data(withJSONObject: message) + Data([10])
    try input.fileHandleForWriting.write(contentsOf: bytes)
  }

  private func drain() throws {
    for (handle, keep) in [
      (output.fileHandleForReading, true), (errors.fileHandleForReading, false),
    ] {
      var bytes = [UInt8](repeating: 0, count: 8192)
      // Bound each turn too: a continuously writing child must still hit its deadline.
      for _ in 0..<128 {
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count < 0 {
          if errno == EAGAIN || errno == EWOULDBLOCK { break }
          if errno == EINTR { continue }
          throw BeaconError("Unable to read harness output")
        }
        if count == 0 { break }
        if keep {
          buffer.append(contentsOf: bytes.prefix(count))
        } else {
          discardedErrorBytes += count
        }
        if buffer.count > limit || discardedErrorBytes > limit {
          throw BeaconError("Harness output exceeded the 4 MiB limit")
        }
      }
    }
  }

  private func tick() throws {
    if ProcessInfo.processInfo.systemUptime >= deadline {
      throw BeaconError("Harness query timed out")
    }
    try drain()
    usleep(5_000)
  }

  func response(id: Int) throws -> [String: Any] {
    while true {
      try drain()
      while let end = buffer.firstIndex(of: 10) {
        let line = Data(buffer[..<end])
        buffer.removeSubrange(...end)
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
          throw BeaconError("Invalid app-server response")
        }
        // Never answer server requests or approve anything on behalf of the user.
        guard object["id"] as? Int == id, object["method"] == nil else { continue }
        guard object["error"] == nil, let result = object["result"] as? [String: Any] else {
          throw BeaconError("App-server rejected a read-only status request")
        }
        return result
      }
      guard process.isRunning else { throw BeaconError("App-server connection closed") }
      try tick()
    }
  }

  func finish() throws -> CommandResult {
    try input.fileHandleForWriting.close()
    while process.isRunning { try tick() }
    process.waitUntilExit()
    try drain()
    return .init(data: buffer, exitCode: process.terminationStatus)
  }

  func close() {
    if process.isRunning {
      process.terminate()
      let grace = ProcessInfo.processInfo.systemUptime + 0.15
      while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(5_000) }
      if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
    for handle in [
      input.fileHandleForWriting, output.fileHandleForReading, errors.fileHandleForReading,
    ] {
      try? handle.close()
    }
  }
}
