import SwiftUI

struct PhoneStatisticsReportSections: View {
  let report: AnalyticsReport
  let comparison: AnalyticsReport?
  @Binding var histogramMode: PhoneHistogramMode

  var body: some View {
    summary
    if let comparison { PhoneStatisticsComparison(report: report, previous: comparison) }
    Section {
      PhoneStatisticsActivityChart(points: report.timeSeries)
    } header: {
      Text("Agent activity")
    } footer: {
      Text(
        "Duration-weighted averages. Breaks are unobserved time; unavailable sources are never counted as idle."
      )
    }
    Section {
      Picker("Histogram measure", selection: $histogramMode) {
        ForEach(PhoneHistogramMode.allCases) { mode in Text(mode.label).tag(mode) }
      }.frame(minHeight: 44)
    } header: {
      Text("When your agents work")
    } footer: {
      Text("Aggregated across the selected period in \(report.timeZoneID).")
    }
    PhoneStatisticsHistogram(
      title: "Hour of day", bins: report.hourly, mode: histogramMode, hourly: true)
    PhoneStatisticsHistogram(
      title: "Day of week", bins: report.weekdays, mode: histogramMode, hourly: false)
    Section {
      PhoneStatisticsHeatmap(cells: report.weekdayHours)
    } header: {
      Text("Weekday and hour")
    } footer: {
      Text(
        "Swipe horizontally for every hour. Gray cells have no observations. Time zone: \(report.timeZoneID)."
      )
    }
    attention
    sources
    collection
    if !report.insights.isEmpty {
      Section("What to look at") {
        ForEach(Array(report.insights.enumerated()), id: \.offset) { _, insight in Text(insight) }
      }
    }
  }

  private var summary: some View {
    Section {
      PhoneStatisticsRow(
        "Average active",
        value: observed(PhoneStatisticsFormat.number(report.summary.meanActiveAgents)))
      PhoneStatisticsRow(
        "Peak active", value: observed(report.summary.peakActiveAgents.formatted()))
      PhoneStatisticsRow(
        "Working agent time",
        value: observed(PhoneStatisticsFormat.duration(report.summary.workingAgentSeconds)))
      PhoneStatisticsRow(
        "Waiting agent time",
        value: observed(PhoneStatisticsFormat.duration(report.summary.waitingAgentSeconds)))
      PhoneStatisticsRow(
        "Observed time", value: PhoneStatisticsFormat.duration(report.summary.observedSeconds))
      PhoneStatisticsRow(
        "Requested time", value: PhoneStatisticsFormat.duration(report.summary.requestedSeconds))
      PhoneStatisticsRow(
        "Period observed",
        value: PhoneStatisticsFormat.percent(
          report.summary.requestedSeconds > 0
            ? report.summary.observedSeconds / report.summary.requestedSeconds : 0))
      PhoneStatisticsRow(
        "Source availability",
        value: PhoneStatisticsFormat.percent(report.summary.sourceAvailabilityFraction))
      PhoneStatisticsRow(
        "Complete source coverage",
        value: PhoneStatisticsFormat.percent(report.summary.completeCoverageFraction))
      PhoneStatisticsRow("Refresh measurements", value: report.sampleCount.formatted())
    } header: {
      Text("Measured on your Mac")
    } footer: {
      Text(
        "Working and waiting are agent time. Observed time is wall-clock time with reliable measurements; simultaneous agents add together only in agent time. Source availability describes monitoring coverage, not productivity."
      )
    }
  }

  private var attention: some View {
    Section {
      PhoneStatisticsRow("Observed episodes", value: report.summary.attentionEpisodes.formatted())
      PhoneStatisticsRow(
        "Transitions back from waiting", value: report.summary.completedEpisodes.formatted())
      PhoneStatisticsRow(
        "Mean observed wait",
        value: report.summary.meanObservedWaitSeconds.map(PhoneStatisticsFormat.duration)
          ?? "Not enough observations")
      PhoneStatisticsRow(
        "95th percentile wait",
        value: report.summary.p95ObservedWaitSeconds.map(PhoneStatisticsFormat.duration)
          ?? "Not enough observations")
      if report.attentionReasons.isEmpty {
        Text("No confirmed attention episodes in this period.").foregroundStyle(.secondary)
      } else {
        ForEach(report.attentionReasons) { reason in
          VStack(alignment: .leading, spacing: 6) {
            Text(reason.reason)
            Text(
              "\(reason.episodes.formatted()) episodes · \(PhoneStatisticsFormat.duration(reason.waitingAgentSeconds)) waiting"
            )
            .font(.subheadline).foregroundStyle(.secondary)
          }.accessibilityElement(children: .combine)
        }
      }
    } header: {
      Text("Attention and interruptions")
    } footer: {
      Text(
        "Mean and p95 include only episodes whose start and resolution were both observed. Gaps never extend a wait. Episodes already open at the range boundary, still open, or interrupted by missing observations may be incomplete. These waits are not time you spent working."
      )
    }
  }

  private var sources: some View {
    Section {
      if report.harnesses.isEmpty {
        Text("No source observations in this range.").foregroundStyle(.secondary)
      }
      ForEach(report.harnesses) { source in
        DisclosureGroup(source.harness.phoneName) {
          PhoneStatisticsRow(
            "Working agent time",
            value: source.availableSeconds > 0
              ? PhoneStatisticsFormat.duration(source.workingAgentSeconds) : "Not observed")
          PhoneStatisticsRow(
            "Waiting agent time",
            value: source.availableSeconds > 0
              ? PhoneStatisticsFormat.duration(source.waitingAgentSeconds) : "Not observed")
          PhoneStatisticsRow(
            "Available time", value: PhoneStatisticsFormat.duration(source.availableSeconds))
          PhoneStatisticsRow(
            "Healthy time", value: PhoneStatisticsFormat.duration(source.healthySeconds))
          PhoneStatisticsRow(
            "Average active",
            value: source.availableSeconds > 0
              ? PhoneStatisticsFormat.number(source.meanActiveAgents) : "Not observed")
          PhoneStatisticsRow(
            "Peak active",
            value: source.availableSeconds > 0
              ? source.peakActiveAgents.formatted() : "Not observed")
          PhoneStatisticsRow("Attention episodes", value: source.attentionEpisodes.formatted())
          if let latency = report.providerLatencies.first(where: { $0.harness == source.harness }) {
            PhoneStatisticsLatencyRows(latency: latency.latency)
          }
        }.padding(.vertical, 6)
      }
    } header: {
      Text("By harness")
    } footer: {
      Text(
        "Availability and refresh timing help distinguish agent behavior from monitoring problems.")
    }
  }

  private var collection: some View {
    Section {
      PhoneStatisticsLatencyRows(latency: report.refreshLatency)
      ForEach(
        report.providerLatencies.filter { timing in
          !report.harnesses.contains { $0.harness == timing.harness }
        }
      ) { timing in
        DisclosureGroup("\(timing.harness.phoneName) refresh timing") {
          PhoneStatisticsLatencyRows(latency: timing.latency)
        }.padding(.vertical, 6)
      }
    } header: {
      Text("Collection timing")
    } footer: {
      Text(
        "Each history refresh is measured on your Mac. Monitoring starts when Swarmbell runs; no sample history is generated."
      )
    }
  }

  private func observed(_ value: String) -> String {
    report.summary.observedSeconds > 0 ? value : "Not observed"
  }
}

struct PhoneStatisticsLatencyRows: View {
  let latency: LatencySummary
  var body: some View {
    PhoneStatisticsRow("Timed refreshes", value: latency.sampleCount.formatted())
    PhoneStatisticsRow("Mean refresh", value: timing(latency.meanMilliseconds))
    PhoneStatisticsRow("Median refresh", value: timing(latency.p50Milliseconds))
    PhoneStatisticsRow("95th percentile refresh", value: timing(latency.p95Milliseconds))
    PhoneStatisticsRow("Longest refresh", value: timing(latency.maxMilliseconds))
  }
  private func timing(_ value: Double) -> String {
    latency.sampleCount > 0 ? PhoneStatisticsFormat.milliseconds(value) : "Not measured"
  }
}

struct PhoneStatisticsComparison: View {
  let report: AnalyticsReport
  let previous: AnalyticsReport
  var body: some View {
    Section {
      PhoneStatisticsRow(
        "Average active change",
        value: change(
          report.summary.meanActiveAgents, previous.summary.meanActiveAgents, time: false))
      PhoneStatisticsRow(
        "Working agent time change",
        value: change(
          report.summary.workingAgentSeconds, previous.summary.workingAgentSeconds, time: true))
      PhoneStatisticsRow(
        "Waiting agent time change",
        value: change(
          report.summary.waitingAgentSeconds, previous.summary.waitingAgentSeconds, time: true))
      PhoneStatisticsRow(
        "Observed time change",
        value: change(report.summary.observedSeconds, previous.summary.observedSeconds, time: true))
      PhoneStatisticsRow(
        "Previous period observed",
        value: PhoneStatisticsFormat.duration(previous.summary.observedSeconds))
      PhoneStatisticsRow(
        "Previous source availability",
        value: PhoneStatisticsFormat.percent(previous.summary.sourceAvailabilityFraction))
    } header: {
      Text("Compared with previous period")
    } footer: {
      Text(
        "\(previous.from.formatted(date: .abbreviated, time: .shortened)) – \(previous.to.formatted(date: .abbreviated, time: .shortened)). Same duration and harness filter. Gaps and coverage differences affect comparisons."
      )
    }
  }
  private func change(_ current: Double, _ old: Double, time: Bool) -> String {
    guard report.summary.observedSeconds > 0, previous.summary.observedSeconds > 0 else {
      return "Not enough observations"
    }
    let delta = current - old
    let sign = delta > 0 ? "+" : delta < 0 ? "−" : ""
    return sign
      + (time
        ? PhoneStatisticsFormat.duration(abs(delta)) : PhoneStatisticsFormat.number(abs(delta)))
  }
}

struct PhoneStatisticsRow: View {
  let title: String
  let value: String
  @Environment(\.dynamicTypeSize) private var typeSize
  init(_ title: String, value: String) {
    self.title = title
    self.value = value
  }
  var body: some View {
    LabeledContent {
      Text(value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
    } label: {
      Text(title).fixedSize(horizontal: false, vertical: true)
    }
    .labeledContentStyle(PhoneStatisticsRowStyle(stacked: typeSize.isAccessibilitySize))
    .accessibilityElement(children: .combine)
  }
}

private struct PhoneStatisticsRowStyle: LabeledContentStyle {
  let stacked: Bool
  func makeBody(configuration: Configuration) -> some View {
    if stacked {
      VStack(alignment: .leading, spacing: 5) {
        configuration.label
        configuration.content.foregroundStyle(.secondary)
      }
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
          configuration.label.fixedSize()
          Spacer(minLength: 8)
          configuration.content.foregroundStyle(.secondary).fixedSize()
        }
        VStack(alignment: .leading, spacing: 5) {
          configuration.label
          configuration.content.foregroundStyle(.secondary)
        }
      }
    }
  }
}

enum PhoneStatisticsFormat {
  static func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
  }
  static func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(1)))
  }
  static func milliseconds(_ value: Double) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0)))) ms"
  }
  static func duration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0m" }
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "<1m" }
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
  }
}
