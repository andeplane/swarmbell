import SwarmbellCore
import SwiftUI

enum DashboardRange: String, CaseIterable, Identifiable {
  case day, week, month, custom
  var id: String { rawValue }
  var days: Int { self == .day ? 1 : self == .week ? 7 : 30 }
  var label: String {
    switch self {
    case .day: "Last 24 hours"
    case .week: "Last 7 days"
    case .month: "Last 30 days"
    case .custom: "Custom dates"
    }
  }
}

@MainActor
struct DashboardView: View {
  @ObservedObject var model: AppModel
  @State private var histogramMode: DashboardHistogramMode = .duration
  @State private var comparePrevious = false
  @State private var previous: AnalyticsReport?

  private var queryID: String {
    "\(model.dashboardRange.rawValue)-\(model.dashboardHarness?.rawValue ?? "all")-\(comparePrevious)-\(model.dashboardCustomFrom.timeIntervalSince1970)-\(model.dashboardCustomTo.timeIntervalSince1970)"
  }
  private var report: AnalyticsReport? { model.analyticsReport }
  private var timeZone: TimeZone {
    TimeZone(identifier: report?.timeZoneID ?? "Europe/Oslo") ?? .current
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      if model.dashboardRange == .custom {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .bottom, spacing: 20) {
            customFromDate
            customToDate
            Text("Europe/Oslo").font(.caption).foregroundStyle(.secondary)
              .padding(.bottom, 4)
          }
          VStack(alignment: .leading, spacing: 14) {
            customFromDate
            customToDate
            Text("Europe/Oslo").font(.caption).foregroundStyle(.secondary)
          }
        }
        .environment(\.timeZone, TimeZone(identifier: "Europe/Oslo") ?? .current)
        .padding(.horizontal, 26).padding(.bottom, 14)
      }
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          coverage
          if let message = model.snapshot?.historyError {
            Label(
              "Refresh history could not be saved: \(message)",
              systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.subheadline).foregroundStyle(.orange).textSelection(.enabled)
          }
          if let message = model.analyticsError {
            Label(message, systemImage: "exclamationmark.triangle")
              .font(.subheadline).foregroundStyle(.orange).textSelection(.enabled)
          }
          if let report, report.sampleCount > 0 {
            summary(report)
            Divider()
            DashboardSection(
              title: "Agent activity",
              detail: "A time series of confirmed work and attention across your selected sources."
            ) {
              if report.timeSeries.contains(where: { $0.active != nil }) {
                DashboardTimeSeries(points: report.timeSeries, timeZone: timeZone)
              } else {
                waitingForIntervals
              }
            }
            Divider()
            histograms(report)
            Divider()
            DashboardSection(
              title: "Patterns across the week",
              detail:
                "Average concurrency for each observed weekday and hour, in \(report.timeZoneID)."
            ) {
              DashboardHeatmap(cells: report.weekdayHours)
            }
            Divider()
            attention(report)
            Divider()
            sources(report)
            if !report.insights.isEmpty {
              Divider()
              DashboardSection(
                title: "What to look at",
                detail:
                  "Observations from the measured period, with no productivity or cost assumptions."
              ) {
                ForEach(Array(report.insights.enumerated()), id: \.offset) { _, insight in
                  Label(insight, systemImage: "arrow.up.right.circle")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
              }
            }
            footer(report)
          } else {
            emptyHistory
          }
        }
        .padding(26)
        .frame(maxWidth: 1280, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 900, minHeight: 640)
    .task(id: queryID) {
      await model.refreshAnalytics()
      await refreshComparison()
    }
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 24) {
        headerTitle
        Spacer(minLength: 24)
        filters
      }
      VStack(alignment: .leading, spacing: 18) {
        headerTitle
        filters
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 26)
    .padding(.vertical, 20)
  }

  private var headerTitle: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Agent statistics").font(.title2.weight(.semibold))
      Text("Every refresh, kept on this Mac.").font(.subheadline).foregroundStyle(.secondary)
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var filters: some View {
    HStack(alignment: .bottom, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Harness").font(.caption).foregroundStyle(.secondary)
        Picker("Harness", selection: $model.dashboardHarness) {
          Text("All harnesses").tag(Optional<Harness>.none)
          ForEach(Harness.allCases, id: \.rawValue) { harness in
            Text(harness.dashboardName).tag(Optional(harness))
          }
        }
        .labelsHidden()
        .accessibilityLabel("Filter by harness")
        .help("Filter statistics by harness")
        .frame(width: 170)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Period").font(.caption).foregroundStyle(.secondary)
        Picker("Period", selection: $model.dashboardRange) {
          ForEach(DashboardRange.allCases) { range in Text(range.label).tag(range) }
        }
        .labelsHidden()
        .accessibilityLabel("Statistics period")
        .help("Choose the period to analyze")
        .frame(width: 170)
      }
      Button {
        Task {
          await model.refreshAnalytics()
          await refreshComparison()
        }
      } label: {
        if model.isLoadingAnalytics {
          ProgressView().controlSize(.small).frame(width: 16, height: 16)
        } else {
          Image(systemName: "arrow.clockwise")
        }
      }
      .help("Refresh statistics")
      .accessibilityLabel("Refresh statistics")
      .disabled(model.isLoadingAnalytics)
      Button {
        model.closeDashboardRequested?()
      } label: {
        Label("Close", systemImage: "xmark")
      }
      .help("Close Statistics; agent monitoring continues")
      .accessibilityLabel("Close Statistics")
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var customFromDate: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("From").font(.caption).foregroundStyle(.secondary)
      DatePicker("From", selection: $model.dashboardCustomFrom)
        .labelsHidden().accessibilityLabel("Range start")
    }.fixedSize(horizontal: true, vertical: false)
  }

  private var customToDate: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("To").font(.caption).foregroundStyle(.secondary)
      DatePicker("To", selection: $model.dashboardCustomTo)
        .labelsHidden().accessibilityLabel("Range end")
    }.fixedSize(horizontal: true, vertical: false)
  }

  private var coverage: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(
        systemName: model.snapshot?.counts.incomplete == false
          ? "checkmark.circle" : "exclamationmark.circle"
      )
      .foregroundStyle(model.snapshot?.counts.incomplete == false ? Color.green : .orange)
      .font(.title3)
      VStack(alignment: .leading, spacing: 4) {
        Text(coverageTitle).font(.subheadline.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
        Text(
          "Offline and unobserved sources remain gaps. Idle is measured separately from working and waiting."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      if let snapshot = model.snapshot {
        Text(
          "\(snapshot.counts.active) active · \(snapshot.counts.needsYou) need you"
        )
        .font(.subheadline.monospacedDigit()).fixedSize(horizontal: true, vertical: false)
      }
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
  }

  private var coverageTitle: String {
    guard let snapshot = model.snapshot else { return "Waiting for the first refresh" }
    let connected = snapshot.providers.filter { $0.health != .unavailable }.count
    return snapshot.counts.incomplete
      ? "Partial coverage · \(connected) of \(snapshot.providers.count) harnesses reporting"
      : "All harnesses reporting"
  }

  private func summary(_ report: AnalyticsReport) -> some View {
    VStack(alignment: .leading, spacing: 15) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 25) { summaryMetrics(report) }
        LazyVGrid(
          columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading,
          spacing: 22
        ) { summaryMetrics(report) }
      }
      Toggle("Compare with the previous period of the same length", isOn: $comparePrevious)
        .toggleStyle(.checkbox).font(.caption)
        .fixedSize(horizontal: false, vertical: true)
      if comparePrevious {
        if let previous, previous.sampleCount > 1, previous.summary.observedSeconds > 0 {
          comparison(report, previous: previous)
        } else {
          Text("There are no usable observations in the previous period yet.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private func summaryMetrics(_ report: AnalyticsReport) -> some View {
    DashboardMetric(
      label: "Average active",
      value: report.summary.observedSeconds > 0
        ? DashboardFormat.number(report.summary.meanActiveAgents) : "—",
      detail: "\(report.summary.peakActiveAgents) peak across observed intervals"
    )
    .frame(minWidth: 200, alignment: .leading)
    DashboardMetric(
      label: "Working time",
      value: report.summary.observedSeconds > 0
        ? DashboardFormat.duration(report.summary.workingAgentSeconds) : "—",
      detail: "Agent time; simultaneous agents add together", tint: .blue
    )
    .frame(minWidth: 200, alignment: .leading)
    DashboardMetric(
      label: "Waiting on you",
      value: report.summary.observedSeconds > 0
        ? DashboardFormat.duration(report.summary.waitingAgentSeconds) : "—",
      detail: "\(report.summary.attentionEpisodes) observed attention episodes", tint: .orange
    )
    .frame(minWidth: 200, alignment: .leading)
    DashboardMetric(
      label: "Observed time", value: DashboardFormat.duration(report.summary.observedSeconds),
      detail:
        "\(report.sampleCount.formatted()) refreshes · \(DashboardFormat.percent(report.summary.requestedSeconds > 0 ? report.summary.observedSeconds / report.summary.requestedSeconds : 0)) of selected period covered"
    ).frame(minWidth: 200, alignment: .leading)
  }

  private func comparison(_ report: AnalyticsReport, previous: AnalyticsReport) -> some View {
    let delta = report.summary.meanActiveAgents - previous.summary.meanActiveAgents
    return Text(
      "Average active: \(delta >= 0 ? "+" : "")\(DashboardFormat.number(delta)) vs. previous period. Previous observed time: \(DashboardFormat.duration(previous.summary.observedSeconds)); compare coverage before interpreting a change."
    )
    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }

  private func histograms(_ report: AnalyticsReport) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("When your agents work").font(.title3.weight(.semibold))
        Spacer()
        Picker("Histogram measure", selection: $histogramMode) {
          ForEach(DashboardHistogramMode.allCases) { mode in Text(mode.label).tag(mode) }
        }
        .labelsHidden()
        .accessibilityLabel("Histogram measure")
        .pickerStyle(.segmented).frame(width: 250)
        .fixedSize(horizontal: true, vertical: false)
      }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 30) {
          hourlyHistogram(report).frame(minWidth: 430)
          weekdayHistogram(report).frame(minWidth: 430)
        }
        VStack(alignment: .leading, spacing: 26) {
          hourlyHistogram(report)
          weekdayHistogram(report)
        }
      }
      Text(
        histogramMode == .duration
          ? "Blue is working time; orange is waiting on you. Empty positions have no observations. Totals grow with coverage and the number of concurrent agents."
          : "Duration-weighted averages make differently observed hours easier to compare. Empty positions have no observations."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func hourlyHistogram(_ report: AnalyticsReport) -> some View {
    DashboardSection(title: "Hour of day", detail: "All observed days in \(report.timeZoneID).") {
      DashboardHistogram(bins: report.hourly, mode: histogramMode, axis: "Hour")
    }
  }

  private func weekdayHistogram(_ report: AnalyticsReport) -> some View {
    DashboardSection(title: "Day of week", detail: "Monday to Sunday, across the selected period.")
    {
      DashboardHistogram(bins: report.weekdays, mode: histogramMode, axis: "Weekday")
    }
  }

  private func attention(_ report: AnalyticsReport) -> some View {
    DashboardSection(
      title: "Attention and interruptions",
      detail:
        "Observed waits describe the time an agent was blocked, not how long you personally spent responding."
    ) {
      HStack(alignment: .top, spacing: 25) {
        DashboardMetric(
          label: "Attention episodes", value: report.summary.attentionEpisodes.formatted(),
          detail: "\(report.summary.completedEpisodes) observed transitions back from waiting")
        DashboardMetric(
          label: "Mean observed wait",
          value: report.summary.meanObservedWaitSeconds.map(DashboardFormat.duration) ?? "—",
          detail: "Uses observed wait intervals only")
        DashboardMetric(
          label: "95th percentile wait",
          value: report.summary.p95ObservedWaitSeconds.map(DashboardFormat.duration) ?? "—",
          detail: "Gaps do not extend a wait")
      }
      if report.attentionReasons.isEmpty {
        Text("No confirmed attention episodes in this period.").font(.subheadline).foregroundStyle(
          .secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(report.attentionReasons) { reason in
            HStack {
              Text(reason.reason).lineLimit(2).layoutPriority(1)
              Spacer()
              Text("\(reason.episodes) episodes").foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
              Text(DashboardFormat.duration(reason.waitingAgentSeconds)).monospacedDigit().frame(
                width: 65, alignment: .trailing)
            }
            .font(.subheadline).padding(.vertical, 8)
            Divider()
          }
        }
      }
    }
  }

  private func sources(_ report: AnalyticsReport) -> some View {
    DashboardSection(
      title: "Sources and refreshes",
      detail: "Availability and latency help distinguish agent behavior from monitoring problems."
    ) {
      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
        GridRow {
          Text("Harness")
          Text("Working")
          Text("Needs you")
          Text("Observed")
          Text("Refresh p95")
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        ForEach(report.harnesses) { source in
          GridRow {
            Text(source.harness.dashboardName).fontWeight(.medium)
            Text(
              source.availableSeconds > 0
                ? DashboardFormat.duration(source.workingAgentSeconds) : "—")
            Text(
              source.availableSeconds > 0
                ? DashboardFormat.duration(source.waitingAgentSeconds) : "—")
            Text(
              source.availableSeconds > 0
                ? DashboardFormat.duration(source.availableSeconds) : "Not observed")
            Text(
              report.providerLatencies.first(where: { $0.harness == source.harness })
                .map { DashboardFormat.milliseconds($0.latency.p95Milliseconds) } ?? "—")
          }
          .font(.subheadline.monospacedDigit())
        }
      }
      HStack(spacing: 24) {
        Text("Refresh mean \(DashboardFormat.milliseconds(report.refreshLatency.meanMilliseconds))")
        Text("p95 \(DashboardFormat.milliseconds(report.refreshLatency.p95Milliseconds))")
        Text("Max \(DashboardFormat.milliseconds(report.refreshLatency.maxMilliseconds))")
      }
      .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
  }

  private func footer(_ report: AnalyticsReport) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(
        "\(DashboardFormat.date(report.from, timeZone: timeZone, includeDate: true)) – \(DashboardFormat.date(report.to, timeZone: timeZone, includeDate: true)) · \(report.timeZoneID)"
      )
      Text(
        "Each successful history write stores a refresh measurement locally. Monitoring begins when Swarmbell runs; earlier days are not backfilled."
      )
    }
    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var emptyHistory: some View {
    VStack(alignment: .leading, spacing: 13) {
      Image(systemName: "chart.xyaxis.line").font(.system(size: 34)).foregroundStyle(.secondary)
      Text("Your history starts here").font(.title2.weight(.semibold))
      Text(
        "Leave Swarmbell running. Every refresh becomes a local measurement, and these charts will fill with your actual activity."
      )
      .font(.body).foregroundStyle(.secondary).frame(maxWidth: 540, alignment: .leading)
      Text(
        "No sample history is generated. Missing hours and unavailable harnesses stay unobserved."
      )
      .font(.subheadline).foregroundStyle(.secondary)
    }
    .padding(.vertical, 60).frame(maxWidth: .infinity, alignment: .leading)
  }

  private var waitingForIntervals: some View {
    Text(
      "The first measurements are saved. A few more refreshes will establish observed intervals and a time series."
    )
    .font(.subheadline).foregroundStyle(.secondary).frame(height: 160, alignment: .center)
    .frame(maxWidth: .infinity)
  }

  private func refreshComparison() async {
    guard comparePrevious, let report = model.analyticsReport, let store = model.historyStore else {
      previous = nil
      return
    }
    let interval = report.to.timeIntervalSince(report.from)
    previous = try? await store.report(
      from: report.from.addingTimeInterval(-interval), to: report.from,
      timeZone: timeZone, harness: model.dashboardHarness)
  }
}
