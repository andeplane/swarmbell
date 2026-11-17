import CSQLite
import Foundation

enum SQLValue {
  case text(String)
  case number(Double)
  case integer(Int)
  case data(Data)
  case null
}

/// SQLite is only accessed by HistoryStore's actor after initialization.
final class HistoryDatabase: @unchecked Sendable {
  private let handle: OpaquePointer
  init(url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
      ) == SQLITE_OK,
      let database
    else {
      if let database { sqlite3_close(database) }
      throw BeaconError("Could not open local measurement history")
    }
    handle = database
    sqlite3_busy_timeout(handle, 1_000)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA synchronous=NORMAL")
    try execute("PRAGMA foreign_keys=ON")
    try execute(
      """
      CREATE TABLE IF NOT EXISTS refresh_samples(
        id TEXT PRIMARY KEY, observed_at REAL NOT NULL UNIQUE, started_at REAL NOT NULL,
        duration_ms REAL NOT NULL, active INTEGER NOT NULL, working INTEGER NOT NULL,
        needs_you INTEGER NOT NULL, uncertain INTEGER NOT NULL, incomplete INTEGER NOT NULL)
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS provider_samples(
        sample_id TEXT NOT NULL REFERENCES refresh_samples(id), harness TEXT NOT NULL,
        duration_ms REAL, health TEXT NOT NULL, observes_attention INTEGER NOT NULL,
        active INTEGER NOT NULL, working INTEGER NOT NULL, needs_you INTEGER NOT NULL,
        uncertain INTEGER NOT NULL, PRIMARY KEY(sample_id,harness))
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS activity_minutes_v3(
        minute REAL NOT NULL,harness TEXT NOT NULL,working_seconds REAL NOT NULL,
        waiting_seconds REAL NOT NULL,available_seconds REAL NOT NULL,healthy_seconds REAL NOT NULL,
        peak_active INTEGER NOT NULL,PRIMARY KEY(minute,harness))
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS monitor_minutes_v3(
        minute REAL PRIMARY KEY,observed_seconds REAL NOT NULL,complete_seconds REAL NOT NULL,
        working_seconds REAL NOT NULL,waiting_seconds REAL NOT NULL,
        source_available_seconds REAL NOT NULL,peak_active INTEGER NOT NULL)
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS activity_intervals_v3(
        start_at REAL NOT NULL,end_at REAL NOT NULL,harness TEXT NOT NULL,
        working_count INTEGER NOT NULL,waiting_count INTEGER NOT NULL,
        available INTEGER NOT NULL,healthy INTEGER NOT NULL,PRIMARY KEY(start_at,end_at,harness))
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS monitor_intervals_v3(
        start_at REAL PRIMARY KEY,end_at REAL NOT NULL,observed INTEGER NOT NULL,complete INTEGER NOT NULL,
        working_count INTEGER NOT NULL,waiting_count INTEGER NOT NULL,available_count INTEGER NOT NULL)
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS reason_intervals_v3(
        start_at REAL NOT NULL,end_at REAL NOT NULL,harness TEXT NOT NULL,reason TEXT NOT NULL,
        waiting_count INTEGER NOT NULL,PRIMARY KEY(start_at,end_at,harness,reason))
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS reason_minutes_v3(
        minute REAL NOT NULL,harness TEXT NOT NULL,reason TEXT NOT NULL,waiting_seconds REAL NOT NULL,
        PRIMARY KEY(minute,harness,reason))
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS attention_episodes_v3(
        id TEXT PRIMARY KEY,session_key TEXT NOT NULL,harness TEXT NOT NULL,reason TEXT NOT NULL,
        started_at REAL NOT NULL,ended_at REAL,observed_wait_seconds REAL NOT NULL,
        left_censored INTEGER NOT NULL,right_censored INTEGER NOT NULL)
      """)
    try execute("CREATE INDEX IF NOT EXISTS episode_time_v3 ON attention_episodes_v3(started_at)")
    try execute(
      """
      CREATE TABLE IF NOT EXISTS completion_events_v3(
        session_key TEXT NOT NULL,harness TEXT NOT NULL,observed_at REAL NOT NULL,
        PRIMARY KEY(session_key,observed_at))
      """)
    try execute(
      "CREATE TABLE IF NOT EXISTS history_metadata(key TEXT PRIMARY KEY,value BLOB NOT NULL)")
    try execute("PRAGMA user_version=3")
  }
  deinit { sqlite3_close(handle) }
  private func prepared(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw BeaconError("Could not prepare local history query")
    }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let code: Int32
      switch value {
      case .text(let string): code = sqlite3_bind_text(statement, index, string, -1, transient)
      case .number(let number): code = sqlite3_bind_double(statement, index, number)
      case .integer(let integer): code = sqlite3_bind_int64(statement, index, Int64(integer))
      case .data(let data):
        code = data.withUnsafeBytes {
          sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient)
        }
      case .null: code = sqlite3_bind_null(statement, index)
      }
      guard code == SQLITE_OK else {
        sqlite3_finalize(statement)
        throw BeaconError("Could not bind local history value")
      }
    }
    return statement
  }
  @discardableResult func execute(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
    let statement = try prepared(sql, values)
    defer { sqlite3_finalize(statement) }
    var code = sqlite3_step(statement)
    while code == SQLITE_ROW { code = sqlite3_step(statement) }
    guard code == SQLITE_DONE else {
      throw BeaconError("Local history write failed (SQLite \(code))")
    }
    return Int(sqlite3_changes(handle))
  }
  func rows(_ sql: String, _ values: [SQLValue] = [], _ body: (OpaquePointer) throws -> Void) throws
  {
    let statement = try prepared(sql, values)
    defer { sqlite3_finalize(statement) }
    var code = sqlite3_step(statement)
    while code == SQLITE_ROW {
      try body(statement)
      code = sqlite3_step(statement)
    }
    guard code == SQLITE_DONE else {
      throw BeaconError("Local history read failed (SQLite \(code))")
    }
  }
}

private struct HistoryAgent: Codable {
  var key: String
  var harness: Harness
  var state: AgentState
  var reason: String?
  var current: Bool
  var child: Bool
}
private struct HistoryProvider: Codable {
  var harness: Harness
  var health: SourceHealth
  var attention: Bool
}
private struct HistoryFrame: Codable {
  var timestamp: Date
  var incomplete: Bool
  var agents: [HistoryAgent]
  var providers: [HistoryProvider]
  init(_ snapshot: MonitorSnapshot) {
    timestamp = snapshot.generatedAt
    incomplete = snapshot.counts.incomplete
    agents = snapshot.agents.map {
      .init(
        key: $0.id, harness: $0.harness, state: $0.state,
        reason: $0.reason, current: $0.freshness == .current && $0.state != .unknown,
        child: $0.isSubagent)
    }
    providers = snapshot.providers.map {
      .init(harness: $0.harness, health: $0.health, attention: $0.observesAttention)
    }
  }
}

public actor HistoryStore {
  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/AgentBeacon/history.sqlite")
  }
  let database: HistoryDatabase
  private var previous: HistoryFrame?
  public init(url: URL = HistoryStore.defaultURL) throws {
    database = try HistoryDatabase(url: url)
    var frame: HistoryFrame?
    try database.rows("SELECT value FROM history_metadata WHERE key='last_frame_v3'") { statement in
      let size = Int(sqlite3_column_bytes(statement, 0))
      if let bytes = sqlite3_column_blob(statement, 0) {
        frame = try JSONDecoder().decode(HistoryFrame.self, from: Data(bytes: bytes, count: size))
      }
    }
    previous = frame
  }

  public func record(_ snapshot: MonitorSnapshot, timing: RefreshTiming) throws {
    let timestamp = snapshot.generatedAt.timeIntervalSince1970
    guard timestamp.isFinite, timing.durationMilliseconds.isFinite,
      timing.durationMilliseconds >= 0,
      timing.providers.allSatisfy({
        $0.durationMilliseconds.isFinite && $0.durationMilliseconds >= 0
      })
    else {
      throw BeaconError("Invalid refresh measurement")
    }
    let frame = HistoryFrame(snapshot)
    try database.execute("BEGIN IMMEDIATE")
    do {
      let id = UUID().uuidString
      let changed = try database.execute(
        "INSERT OR IGNORE INTO refresh_samples VALUES(?,?,?,?,?,?,?,?,?)",
        [
          .text(id), .number(timestamp), .number(timing.startedAt.timeIntervalSince1970),
          .number(timing.durationMilliseconds),
          .integer(snapshot.counts.active), .integer(snapshot.counts.working),
          .integer(snapshot.counts.needsYou),
          .integer(snapshot.counts.uncertain), .integer(snapshot.counts.incomplete ? 1 : 0),
        ])
      if changed == 0 {
        try database.execute("COMMIT")
        return
      }
      // App and CLI can both collect: read the newest frame inside the write transaction
      // so independent HistoryStore instances cannot double-credit overlapping intervals.
      try database.rows("SELECT value FROM history_metadata WHERE key='last_frame_v3'") {
        statement in
        if let bytes = sqlite3_column_blob(statement, 0) {
          previous = try JSONDecoder().decode(
            HistoryFrame.self,
            from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
      }
      for source in snapshot.providers {
        let rows = snapshot.agents.filter { $0.harness == source.harness && !$0.isSubagent }
        let current = rows.filter { $0.freshness == .current }
        let duration = timing.providers.first { $0.harness == source.harness }?.durationMilliseconds
        try database.execute(
          "INSERT INTO provider_samples VALUES(?,?,?,?,?,?,?,?,?)",
          [
            .text(id), .text(source.harness.rawValue), duration.map(SQLValue.number) ?? .null,
            .text(source.health.rawValue),
            .integer(source.observesAttention ? 1 : 0),
            .integer(current.filter { $0.state.isActive }.count),
            .integer(current.filter { $0.state == .working }.count),
            .integer(current.filter { $0.state == .needsYou }.count),
            .integer(rows.filter { $0.freshness != .current || $0.state == .unknown }.count),
          ])
      }
      // Retain raw samples on a clock reversal, but do not invent a backwards duration.
      if previous == nil || frame.timestamp > previous!.timestamp {
        var hasTrustedBaseline = false
        try database.rows("SELECT value FROM history_metadata WHERE key='statistics_v3_started_at'")
        { _ in
          hasTrustedBaseline = true
        }
        if !hasTrustedBaseline {
          try database.execute(
            "INSERT INTO history_metadata VALUES('statistics_v3_started_at',?)",
            [
              .data(try JSONEncoder().encode(timestamp))
            ])
        }
        // Legacy prototype rollups used source-wide uncertainty and could split one
        // known waiter into hundreds of episodes. Keep them intact for inspection,
        // but start trusted version3 durations from this collector's first sample.
        try accumulate(from: hasTrustedBaseline ? previous : nil, to: frame)
        try database.execute(
          "INSERT OR REPLACE INTO history_metadata VALUES('last_frame_v3',?)",
          [
            .data(try JSONEncoder().encode(frame))
          ])
        try database.execute("COMMIT")
        previous = frame
      } else {
        try database.execute("COMMIT")
      }
    } catch {
      _ = try? database.execute("ROLLBACK")
      throw error
    }
  }

  private func accumulate(from before: HistoryFrame?, to after: HistoryFrame) throws {
    let duration = before.map { after.timestamp.timeIntervalSince($0.timestamp) } ?? 0
    let contiguous = duration > 0 && duration <= 15
    let left = Dictionary(
      (before?.agents ?? []).filter { !$0.child }.map { ($0.key, $0) },
      uniquingKeysWith: { a, _ in a })
    let right = Dictionary(
      after.agents.filter { !$0.child }.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    let oldSources = Dictionary(
      (before?.providers ?? []).map { ($0.harness, $0) }, uniquingKeysWith: { a, _ in a })
    let newSources = Dictionary(
      after.providers.map { ($0.harness, $0) }, uniquingKeysWith: { a, _ in a })
    func available(_ harness: Harness) -> Bool {
      contiguous && oldSources[harness]?.health != nil
        && oldSources[harness]?.health != .unavailable && newSources[harness]?.health != nil
        && newSources[harness]?.health != .unavailable
    }
    let usable = left.values.filter { old in
      old.current && right[old.key]?.current == true && available(old.harness)
    }
    if contiguous, let before {
      var start = before.timestamp.timeIntervalSince1970
      let end = after.timestamp.timeIntervalSince1970
      while start < end {
        let minute = floor(start / 60) * 60
        let stop = min(end, minute + 60)
        let seconds = stop - start
        var work = 0
        var wait = 0
        var sourceCount = 0
        for harness in Harness.allCases {
          let valid = available(harness)
          let rows = usable.filter { $0.harness == harness }
          let working = rows.filter { $0.state == .working }.count
          let waiting = rows.filter { $0.state == .needsYou }.count
          let healthy =
            valid && oldSources[harness]?.health == .healthy
            && newSources[harness]?.health == .healthy && oldSources[harness]?.attention == true
            && newSources[harness]?.attention == true
            && !left.values.contains(where: { $0.harness == harness && !$0.current })
            && !right.values.contains(where: { $0.harness == harness && !$0.current })
          if valid { sourceCount += 1 }
          work += working
          wait += waiting
          try database.execute(
            "INSERT OR IGNORE INTO activity_intervals_v3 VALUES(?,?,?,?,?,?,?)",
            [
              .number(before.timestamp.timeIntervalSince1970), .number(end),
              .text(harness.rawValue),
              .integer(working), .integer(waiting), .integer(valid ? 1 : 0),
              .integer(healthy ? 1 : 0),
            ])
          try database.execute(
            """
            INSERT INTO activity_minutes_v3 VALUES(?,?,?,?,?,?,?) ON CONFLICT(minute,harness) DO UPDATE SET
            working_seconds=working_seconds+excluded.working_seconds,waiting_seconds=waiting_seconds+excluded.waiting_seconds,
            available_seconds=available_seconds+excluded.available_seconds,healthy_seconds=healthy_seconds+excluded.healthy_seconds,
            peak_active=max(peak_active,excluded.peak_active)
            """,
            [
              .number(minute), .text(harness.rawValue), .number(Double(working) * seconds),
              .number(Double(waiting) * seconds),
              .number(valid ? seconds : 0), .number(healthy ? seconds : 0),
              .integer(working + waiting),
            ])
          let reasons = Dictionary(
            grouping: rows.filter { $0.state == .needsYou }, by: { $0.reason ?? "Input needed" })
          for (reason, agents) in reasons {
            try database.execute(
              "INSERT OR IGNORE INTO reason_intervals_v3 VALUES(?,?,?,?,?)",
              [
                .number(before.timestamp.timeIntervalSince1970), .number(end),
                .text(harness.rawValue), .text(reason), .integer(agents.count),
              ])
            try database.execute(
              """
              INSERT INTO reason_minutes_v3 VALUES(?,?,?,?) ON CONFLICT(minute,harness,reason) DO UPDATE SET
              waiting_seconds=waiting_seconds+excluded.waiting_seconds
              """,
              [
                .number(minute), .text(harness.rawValue), .text(reason),
                .number(Double(agents.count) * seconds),
              ])
          }
        }
        let fullyObserved =
          !before.incomplete && !after.incomplete && sourceCount == Harness.allCases.count
        try database.execute(
          "INSERT OR IGNORE INTO monitor_intervals_v3 VALUES(?,?,?,?,?,?,?)",
          [
            .number(before.timestamp.timeIntervalSince1970), .number(end),
            .integer(sourceCount > 0 ? 1 : 0),
            .integer(fullyObserved ? 1 : 0), .integer(work),
            .integer(wait), .integer(sourceCount),
          ])
        try database.execute(
          """
          INSERT INTO monitor_minutes_v3 VALUES(?,?,?,?,?,?,?) ON CONFLICT(minute) DO UPDATE SET
          observed_seconds=observed_seconds+excluded.observed_seconds,complete_seconds=complete_seconds+excluded.complete_seconds,
          working_seconds=working_seconds+excluded.working_seconds,waiting_seconds=waiting_seconds+excluded.waiting_seconds,
          source_available_seconds=source_available_seconds+excluded.source_available_seconds,peak_active=max(peak_active,excluded.peak_active)
          """,
          [
            .number(minute), .number(sourceCount > 0 ? seconds : 0),
            .number(fullyObserved ? seconds : 0),
            .number(Double(work) * seconds),
            .number(Double(wait) * seconds), .number(Double(sourceCount) * seconds),
            .integer(work + wait),
          ])
        start = stop
      }
    }
    try updateEpisodes(
      left: left, right: right, at: after.timestamp, duration: duration,
      contiguous: contiguous, available: available)
  }

  private func updateEpisodes(
    left: [String: HistoryAgent], right: [String: HistoryAgent], at: Date,
    duration: Double, contiguous: Bool, available: (Harness) -> Bool
  ) throws {
    var open: [(String, String, String)] = []
    try database.rows(
      "SELECT id,session_key,reason FROM attention_episodes_v3 WHERE ended_at IS NULL"
    ) { statement in
      open.append((Self.string(statement, 0), Self.string(statement, 1), Self.string(statement, 2)))
    }
    var continuing = Set<String>()
    for (id, key, reason) in open {
      let old = left[key]
      let new = right[key]
      let known =
        contiguous && old?.current == true && new?.current == true && available(new!.harness)
      if known, old?.state == .needsYou {
        try database.execute(
          "UPDATE attention_episodes_v3 SET observed_wait_seconds=observed_wait_seconds+? WHERE id=?",
          [.number(duration), .text(id)])
      }
      if known, new?.state == .needsYou, (new?.reason ?? "Input needed") == reason {
        continuing.insert(key)
      } else {
        try database.execute(
          "UPDATE attention_episodes_v3 SET ended_at=?,right_censored=? WHERE id=?",
          [
            .number(known ? at.timeIntervalSince1970 : at.timeIntervalSince1970 - max(0, duration)),
            .integer(known && new?.state != .needsYou ? 0 : 1), .text(id),
          ])
      }
    }
    for row in right.values where row.current {
      let old = left[row.key]
      let known = contiguous && old?.current == true && available(row.harness)
      if row.state == .needsYou && !continuing.contains(row.key) {
        try database.execute(
          "INSERT INTO attention_episodes_v3 VALUES(?,?,?,?,?,NULL,0,?,0)",
          [
            .text(UUID().uuidString), .text(row.key), .text(row.harness.rawValue),
            .text(row.reason ?? "Input needed"),
            .number(at.timeIntervalSince1970), .integer(known && old?.state != .needsYou ? 0 : 1),
          ])
      }
      if known, row.state == .finished, old?.state != .finished {
        try database.execute(
          "INSERT OR IGNORE INTO completion_events_v3 VALUES(?,?,?)",
          [.text(row.key), .text(row.harness.rawValue), .number(at.timeIntervalSince1970)])
      }
    }
  }

  static func string(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let text = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: text)
  }
}
