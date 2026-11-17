import Foundation

/// The native app calls this after its existing refresh. Filesystem work stays
/// off the main actor, and callers cannot turn a cache read into collection.
public actor SnapshotCachePublisher {
  private let directory: URL
  private var writer: SnapshotCacheWriter?

  public init(directory: URL = SnapshotCacheWriter.defaultDirectory) {
    self.directory = directory
  }

  /// A failure never changes the source snapshot or restarts a collector.
  public func publish(_ snapshot: MonitorSnapshot, at date: Date = Date()) -> String? {
    do {
      if writer == nil { writer = try SnapshotCacheWriter(directory: directory) }
      _ = try writer?.publish(snapshot: snapshot, at: date)
      return nil
    } catch {
      return "Current snapshot cache could not be published: \(error.localizedDescription)"
    }
  }

  public func stop() { writer = nil }
}
