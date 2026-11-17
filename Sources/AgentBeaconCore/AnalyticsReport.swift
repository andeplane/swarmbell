import CSQLite
import Foundation

private struct AnalyticsAccumulator: Sendable {
  var observed = 0.0, work = 0.0, wait = 0.0, available = 0.0, healthy = 0.0, complete = 0.0
  var peak = 0, samples = 0, episodes = 0
  var mean: Double { observed > 0 ? (work + wait) / observed : 0 }
  mutating func add(_ other: Self, fraction: Double = 1) {
    observed += other.observed * fraction
    work += other.work * fraction
    wait += other.wait * fraction
    available += other.available * fraction
    healthy += other.healthy * fraction
    complete += other.complete * fraction
    peak = max(peak, other.peak)
  }
}

private func consumeAnalyticsRange(
  start: Double, stop: Double, item: AnalyticsAccumulator,
  total: inout AnalyticsAccumulator, hours: inout [AnalyticsAccumulator],
  weekdays: inout [AnalyticsAccumulator],
  heatmap: inout [AnalyticsAccumulator], chart: inout [AnalyticsAccumulator], calendar: Calendar,
  begin: Double, width: Double
) {
  guard stop > start else { return }
  total.add(item)
  var position = start
  while position < stop {
    let minuteEnd = min(stop, (floor(position / 60) + 1) * 60)
    let fraction = (minuteEnd - position) / (stop - start)
    let date = Date(timeIntervalSince1970: (position + minuteEnd) / 2)
    let hour = calendar.component(.hour, from: date)
    let weekday = (calendar.component(.weekday, from: date) + 5) % 7
    hours[hour].add(item, fraction: fraction)
    weekdays[weekday].add(item, fraction: fraction)
    heatmap[weekday * 24 + hour].add(item, fraction: fraction)
    var chartPosition = position
    while chartPosition < minuteEnd {
      let slot = min(chart.count - 1, max(0, Int((chartPosition - begin) / width)))
      let chartEnd = min(minuteEnd, begin + Double(slot + 1) * width)
      if chartEnd <= chartPosition { break }
      chart[slot].add(item, fraction: (chartEnd - chartPosition) / (stop - start))
      chartPosition = chartEnd
    }
    position = minuteEnd
  }
}

extension HistoryStore {
  public func report(
    from: Date, to: Date, timeZone: TimeZone = TimeZone(identifier: "Europe/Oslo")!,
    harness: Harness? = nil
  ) throws -> AnalyticsReport {
    let begin = from.timeIntervalSince1970
    let end = to.timeIntervalSince1970
    guard begin.isFinite, end.isFinite, end > begin else {
      throw BeaconError("History range must have a start before its end")
    }
    let requested = end - begin
    let width = max(60, ceil(requested / (720 * 60)) * 60)
    let count = min(721, Int(ceil(requested / width)))
    var chart = [AnalyticsAccumulator](repeating: .init(), count: count)
    var hours = [AnalyticsAccumulator](repeating: .init(), count: 24)
    var weekdays = [AnalyticsAccumulator](repeating: .init(), count: 7)
    var heatmap = [AnalyticsAccumulator](repeating: .init(), count: 168)
    var total = AnalyticsAccumulator()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let sourceCount = harness == nil ? Double(Harness.allCases.count) : 1.0
    let interiorStart = ceil(begin / 60) * 60
    let interiorEnd = floor(end / 60) * 60
    let edges: [(Double, Double)]
    if interiorStart < interiorEnd {
      edges = [(begin, min(end, interiorStart)), (max(begin, interiorEnd), end)].filter {
        $0.1 > $0.0
      }
    } else {
      edges = [(begin, end)]
    }
    let sql: String
    var values: [SQLValue] = [.number(interiorStart), .number(interiorEnd)]
    if let harness {
      sql =
        "SELECT minute,available_seconds,healthy_seconds,working_seconds,waiting_seconds,available_seconds,peak_active FROM activity_minutes_v3 WHERE minute>=? AND minute<? AND harness=? ORDER BY minute"
      values.append(.text(harness.rawValue))
    } else {
      sql =
        "SELECT minute,observed_seconds,complete_seconds,working_seconds,waiting_seconds,source_available_seconds,peak_active FROM monitor_minutes_v3 WHERE minute>=? AND minute<? ORDER BY minute"
    }
    try database.rows(sql, values) { statement in
      let minute = sqlite3_column_double(statement, 0)
      let item = AnalyticsAccumulator(
        observed: sqlite3_column_double(statement, 1),
        work: sqlite3_column_double(statement, 3), wait: sqlite3_column_double(statement, 4),
        available: sqlite3_column_double(statement, 5),
        complete: sqlite3_column_double(statement, 2),
        peak: Int(sqlite3_column_int(statement, 6)))
      consumeAnalyticsRange(
        start: minute, stop: minute + 60, item: item, total: &total, hours: &hours,
        weekdays: &weekdays, heatmap: &heatmap, chart: &chart, calendar: calendar, begin: begin,
        width: width)
    }
    for (edgeStart, edgeEnd) in edges {
      let edgeSQL: String
      var edgeValues: [SQLValue] = [.number(edgeStart - 15), .number(edgeStart), .number(edgeEnd)]
      if let harness {
        edgeSQL =
          "SELECT start_at,end_at,available,healthy,working_count,waiting_count,available,working_count+waiting_count FROM activity_intervals_v3 WHERE start_at>=? AND end_at>? AND start_at<? AND harness=?"
        edgeValues.append(.text(harness.rawValue))
      } else {
        edgeSQL =
          "SELECT start_at,end_at,observed,complete,working_count,waiting_count,available_count,working_count+waiting_count FROM monitor_intervals_v3 WHERE start_at>=? AND end_at>? AND start_at<?"
      }
      try database.rows(edgeSQL, edgeValues) { statement in
        let start = max(edgeStart, sqlite3_column_double(statement, 0))
        let stop = min(edgeEnd, sqlite3_column_double(statement, 1))
        let seconds = max(0, stop - start)
        let item = AnalyticsAccumulator(
          observed: sqlite3_column_double(statement, 2) * seconds,
          work: sqlite3_column_double(statement, 4) * seconds,
          wait: sqlite3_column_double(statement, 5) * seconds,
          available: sqlite3_column_double(statement, 6) * seconds,
          complete: sqlite3_column_double(statement, 3) * seconds,
          peak: Int(sqlite3_column_int(statement, 7)))
        consumeAnalyticsRange(
          start: start, stop: stop, item: item, total: &total, hours: &hours,
          weekdays: &weekdays, heatmap: &heatmap, chart: &chart, calendar: calendar, begin: begin,
          width: width)
      }
    }
    let sampleTable =
      harness == nil
      ? "refresh_samples r" : "refresh_samples r JOIN provider_samples p ON p.sample_id=r.id"
    let sampleFilter =
      "r.observed_at>=? AND r.observed_at<?" + (harness == nil ? "" : " AND p.harness=?")
    let metric = harness == nil ? "r.active" : "p.active"
    var sampleValues: [SQLValue] = [.number(begin), .number(end)]
    if let harness { sampleValues.append(.text(harness.rawValue)) }
    var sampleCount = 0
    var peak = 0
    try database.rows(
      "SELECT COUNT(*),COALESCE(MAX(\(metric)),0) FROM \(sampleTable) WHERE \(sampleFilter)",
      sampleValues
    ) { statement in
      sampleCount = Int(sqlite3_column_int64(statement, 0))
      peak = Int(sqlite3_column_int(statement, 1))
    }
    try database.rows(
      "SELECT CAST((r.observed_at-?)/? AS INTEGER),COUNT(*),MAX(\(metric)) FROM \(sampleTable) WHERE \(sampleFilter) GROUP BY 1",
      [.number(begin), .number(width)] + sampleValues
    ) { statement in
      let index = Int(sqlite3_column_int(statement, 0))
      if chart.indices.contains(index) {
        chart[index].samples = Int(sqlite3_column_int(statement, 1))
        chart[index].peak = max(chart[index].peak, Int(sqlite3_column_int(statement, 2)))
      }
    }
    var byHarness: [Harness: AnalyticsAccumulator] = [:]
    try database.rows(
      "SELECT minute,harness,working_seconds,waiting_seconds,available_seconds,healthy_seconds,peak_active FROM activity_minutes_v3 WHERE minute>=? AND minute<?",
      [.number(interiorStart), .number(interiorEnd)]
    ) { statement in
      guard let source = Harness(rawValue: Self.string(statement, 1)),
        harness == nil || harness == source
      else { return }
      let item = AnalyticsAccumulator(
        observed: sqlite3_column_double(statement, 4), work: sqlite3_column_double(statement, 2),
        wait: sqlite3_column_double(statement, 3), available: sqlite3_column_double(statement, 4),
        healthy: sqlite3_column_double(statement, 5), peak: Int(sqlite3_column_int(statement, 6)))
      var accumulator = byHarness[source] ?? .init()
      accumulator.add(item)
      byHarness[source] = accumulator
    }
    for (edgeStart, edgeEnd) in edges {
      try database.rows(
        "SELECT start_at,end_at,harness,working_count,waiting_count,available,healthy FROM activity_intervals_v3 WHERE start_at>=? AND end_at>? AND start_at<?",
        [.number(edgeStart - 15), .number(edgeStart), .number(edgeEnd)]
      ) { statement in
        guard let source = Harness(rawValue: Self.string(statement, 2)),
          harness == nil || source == harness
        else { return }
        let seconds = max(
          0,
          min(edgeEnd, sqlite3_column_double(statement, 1))
            - max(edgeStart, sqlite3_column_double(statement, 0)))
        let item = AnalyticsAccumulator(
          observed: sqlite3_column_double(statement, 5) * seconds,
          work: sqlite3_column_double(statement, 3) * seconds,
          wait: sqlite3_column_double(statement, 4) * seconds,
          available: sqlite3_column_double(statement, 5) * seconds,
          healthy: sqlite3_column_double(statement, 6) * seconds,
          peak: Int(sqlite3_column_int(statement, 3) + sqlite3_column_int(statement, 4)))
        var accumulator = byHarness[source] ?? .init()
        accumulator.add(item)
        byHarness[source] = accumulator
      }
    }
    var reasons: [String: (Int, Double)] = [:]
    var episodeCount = 0
    var waitTotal = 0.0
    var waitCount = 0
    let episodeFilter = "started_at>=? AND started_at<?" + (harness == nil ? "" : " AND harness=?")
    try database.rows(
      "SELECT harness,reason,started_at FROM attention_episodes_v3 WHERE \(episodeFilter)",
      sampleValues
    ) { statement in
      guard let source = Harness(rawValue: Self.string(statement, 0)) else { return }
      let reason = Self.string(statement, 1)
      let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
      let hour = calendar.component(.hour, from: date)
      let weekday = (calendar.component(.weekday, from: date) + 5) % 7
      hours[hour].episodes += 1
      weekdays[weekday].episodes += 1
      heatmap[weekday * 24 + hour].episodes += 1
      var sourceStats = byHarness[source] ?? .init()
      sourceStats.episodes += 1
      byHarness[source] = sourceStats
      let prior = reasons[reason] ?? (0, 0)
      reasons[reason] = (prior.0 + 1, prior.1)
      episodeCount += 1
    }
    var reasonValues: [SQLValue] = [.number(interiorStart), .number(interiorEnd)]
    var reasonFilter = "minute>=? AND minute<?"
    if let harness {
      reasonFilter += " AND harness=?"
      reasonValues.append(.text(harness.rawValue))
    }
    try database.rows(
      "SELECT minute,reason,waiting_seconds FROM reason_minutes_v3 WHERE \(reasonFilter)",
      reasonValues
    ) { statement in
      let reason = Self.string(statement, 1)
      let prior = reasons[Self.string(statement, 1)] ?? (0, 0)
      reasons[reason] = (prior.0, prior.1 + sqlite3_column_double(statement, 2))
    }
    for (edgeStart, edgeEnd) in edges {
      var edgeValues: [SQLValue] = [.number(edgeStart - 15), .number(edgeStart), .number(edgeEnd)]
      let filter =
        "start_at>=? AND end_at>? AND start_at<?" + (harness == nil ? "" : " AND harness=?")
      if let harness { edgeValues.append(.text(harness.rawValue)) }
      try database.rows(
        "SELECT start_at,end_at,reason,waiting_count FROM reason_intervals_v3 WHERE \(filter)",
        edgeValues
      ) { statement in
        let seconds = max(
          0,
          min(edgeEnd, sqlite3_column_double(statement, 1))
            - max(edgeStart, sqlite3_column_double(statement, 0)))
        let reason = Self.string(statement, 2)
        let prior = reasons[reason] ?? (0, 0)
        reasons[reason] = (prior.0, prior.1 + seconds * sqlite3_column_double(statement, 3))
      }
    }
    let resolvedFilter =
      "ended_at>=? AND ended_at<? AND left_censored=0 AND right_censored=0"
      + (harness == nil ? "" : " AND harness=?")
    try database.rows(
      "SELECT COUNT(*),COALESCE(SUM(observed_wait_seconds),0) FROM attention_episodes_v3 WHERE \(resolvedFilter)",
      sampleValues
    ) { statement in
      waitCount = Int(sqlite3_column_int64(statement, 0))
      waitTotal = sqlite3_column_double(statement, 1)
    }
    var waitP95: Double?
    if waitCount > 0 {
      try database.rows(
        "SELECT observed_wait_seconds FROM attention_episodes_v3 WHERE \(resolvedFilter) ORDER BY observed_wait_seconds LIMIT 1 OFFSET ?",
        sampleValues + [.integer(max(0, Int(ceil(Double(waitCount) * 0.95)) - 1))]
      ) { statement in waitP95 = sqlite3_column_double(statement, 0) }
    }
    var completions = 0
    try database.rows(
      "SELECT COUNT(*) FROM attention_episodes_v3 WHERE ended_at>=? AND ended_at<? AND right_censored=0"
        + (harness == nil ? "" : " AND harness=?"), sampleValues
    ) {
      completions = Int(sqlite3_column_int64($0, 0))
    }
    let latency = try latencySummary(from: begin, to: end, harness: nil)
    let providerLatencies = try Harness.allCases.filter { harness == nil || $0 == harness }.map {
      ProviderLatencySummary(
        harness: $0, latency: try latencySummary(from: begin, to: end, harness: $0))
    }
    var segment = 0
    var gap = true
    let points = chart.enumerated().map { index, item -> AnalyticsPoint in
      if item.observed > 0 && gap { segment += 1 }
      gap = item.observed <= 0
      let length = min(width, end - (begin + Double(index) * width))
      return .init(
        timestamp: from.addingTimeInterval(Double(index) * width),
        active: item.observed > 0 ? item.mean : nil,
        working: item.observed > 0 ? item.work / item.observed : nil,
        needsYou: item.observed > 0 ? item.wait / item.observed : nil,
        peakActive: item.peak, observedSeconds: item.observed,
        sourceAvailabilityFraction: min(1, item.available / (length * sourceCount)),
        sampleCount: item.samples, segment: segment)
    }
    func bucket(_ pair: (Int, AnalyticsAccumulator), weekday: Bool) -> AnalyticsBucket {
      let (index, item) = pair
      let labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
      return .init(
        index: weekday ? index + 1 : index,
        label: weekday ? labels[index] : String(format: "%02d", index),
        workingAgentSeconds: item.work, waitingAgentSeconds: item.wait,
        observedSeconds: item.observed,
        meanActiveAgents: item.mean, peakActiveAgents: item.peak, attentionEpisodes: item.episodes)
    }
    let availability = min(1, total.available / (requested * sourceCount))
    var insights: [String] = []
    var trustedStart: Double?
    try database.rows("SELECT value FROM history_metadata WHERE key='statistics_v3_started_at'") {
      statement in
      if let bytes = sqlite3_column_blob(statement, 0) {
        trustedStart = try JSONDecoder().decode(
          Double.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
      }
    }
    if let trustedStart, begin < trustedStart {
      var earlierSamples = 0
      try database.rows(
        "SELECT COUNT(*) FROM refresh_samples WHERE observed_at>=? AND observed_at<?",
        [.number(begin), .number(min(end, trustedStart))]
      ) { earlierSamples = Int(sqlite3_column_int64($0, 0)) }
      if earlierSamples > 0 {
        insights.append(
          "Earlier prototype duration and attention estimates were excluded. Their raw refresh counts and latency measurements are preserved; trusted activity history starts with the corrected collector."
        )
      }
    }
    if trustedStart == nil && sampleCount > 0 {
      insights.append(
        "Earlier prototype activity estimates are excluded. Trusted activity statistics will start when the corrected collector records new observations; raw refresh and latency history is retained."
      )
    }
    if sampleCount == 0 {
      insights.append(
        "No refresh measurements in this range yet. Leave Agent Beacon running to build history.")
    }
    if total.observed > 0 && total.work + total.wait > 0 {
      let waiting = total.wait / (total.work + total.wait)
      insights.append(
        String(
          format: "%.0f%% of observed active agent-time was spent waiting for you.", waiting * 100))
    }
    if total.complete < requested * 0.95 {
      insights.append(
        "Source coverage is incomplete. Missing periods are excluded from activity averages, not counted as zero."
      )
    }
    if let worst = providerLatencies.filter({ $0.latency.sampleCount > 0 }).max(by: {
      $0.latency.p95Milliseconds < $1.latency.p95Milliseconds
    }) {
      insights.append(
        String(
          format: "Slowest source at p95: %@ (%.0f ms).", worst.harness.rawValue,
          worst.latency.p95Milliseconds))
    }
    insights.append(
      "Durations use adjacent observations no more than 15 seconds apart. Range edges use exact interval clipping; interior minute rollups keep long reports efficient. Wait duration is an observed estimate, not a precise response timer."
    )
    insights.append(
      "Wait averages include only episodes whose start and resolution were both observed. Already-waiting sessions and outages have censored duration estimates."
    )
    return .init(
      from: from, to: to, generatedAt: Date(), timeZoneID: timeZone.identifier,
      sampleCount: sampleCount,
      summary: .init(
        observedSeconds: total.observed, requestedSeconds: requested,
        workingAgentSeconds: total.work,
        waitingAgentSeconds: total.wait, meanActiveAgents: total.mean,
        sourceAvailabilityFraction: availability,
        completeCoverageFraction: min(1, total.complete / requested),
        peakActiveAgents: max(peak, total.peak),
        attentionEpisodes: episodeCount, completedEpisodes: completions,
        meanObservedWaitSeconds: waitCount > 0 ? waitTotal / Double(waitCount) : nil,
        p95ObservedWaitSeconds: waitP95),
      timeSeries: points, hourly: hours.enumerated().map { bucket($0, weekday: false) },
      weekdays: weekdays.enumerated().map { bucket($0, weekday: true) },
      weekdayHours: heatmap.enumerated().map { index, item in
        .init(
          weekday: index / 24 + 1, hour: index % 24,
          observedSeconds: item.observed, workingAgentSeconds: item.work,
          waitingAgentSeconds: item.wait, meanActiveAgents: item.mean)
      },
      harnesses: Harness.allCases.filter { harness == nil || $0 == harness }.map { source in
        let item = byHarness[source] ?? .init()
        return .init(
          harness: source, workingAgentSeconds: item.work, waitingAgentSeconds: item.wait,
          availableSeconds: item.available, healthySeconds: item.healthy,
          meanActiveAgents: item.mean,
          peakActiveAgents: item.peak, attentionEpisodes: item.episodes)
      },
      attentionReasons: reasons.map {
        .init(reason: $0.key, episodes: $0.value.0, waitingAgentSeconds: $0.value.1)
      }
      .sorted { $0.waitingAgentSeconds > $1.waitingAgentSeconds },
      refreshLatency: latency, providerLatencies: providerLatencies, insights: insights)
  }

  private func latencySummary(from: Double, to: Double, harness: Harness?) throws -> LatencySummary
  {
    let table =
      harness == nil
      ? "refresh_samples r" : "refresh_samples r JOIN provider_samples p ON p.sample_id=r.id"
    let field = harness == nil ? "r.duration_ms" : "p.duration_ms"
    let filter =
      "r.observed_at>=? AND r.observed_at<? AND \(field) IS NOT NULL"
      + (harness == nil ? "" : " AND p.harness=?")
    var values: [SQLValue] = [.number(from), .number(to)]
    if let harness { values.append(.text(harness.rawValue)) }
    var count = 0
    var mean = 0.0
    var maximum = 0.0
    var p50 = 0.0
    var p95 = 0.0
    try database.rows(
      "SELECT COUNT(*),COALESCE(AVG(\(field)),0),COALESCE(MAX(\(field)),0) FROM \(table) WHERE \(filter)",
      values
    ) {
      count = Int(sqlite3_column_int64($0, 0))
      mean = sqlite3_column_double($0, 1)
      maximum = sqlite3_column_double($0, 2)
    }
    if count > 0 {
      for percentile in [0.5, 0.95] {
        try database.rows(
          "SELECT \(field) FROM \(table) WHERE \(filter) ORDER BY \(field) LIMIT 1 OFFSET ?",
          values + [.integer(max(0, Int(ceil(Double(count) * percentile)) - 1))]
        ) {
          if percentile == 0.5 {
            p50 = sqlite3_column_double($0, 0)
          } else {
            p95 = sqlite3_column_double($0, 0)
          }
        }
      }
    }
    return .init(
      sampleCount: count, meanMilliseconds: mean, p50Milliseconds: p50, p95Milliseconds: p95,
      maxMilliseconds: maximum)
  }
}
