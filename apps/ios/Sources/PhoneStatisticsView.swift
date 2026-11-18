import SwiftUI

enum PhoneStatisticsPeriod: String, CaseIterable, Identifiable {
  case day, week, month, custom
  var id: String { rawValue }
  var label: String {
    switch self {
    case .day: "Last 24 hours"
    case .week: "Last 7 days"
    case .month: "Last 30 days"
    case .custom: "Custom dates"
    }
  }
  var seconds: TimeInterval {
    switch self {
    case .day: 86_400
    case .week: 7 * 86_400
    case .month, .custom: 30 * 86_400
    }
  }
}

struct PhoneStatisticsView: View {
  @ObservedObject var model: SwarmbellPhoneModel
  @State private var period: PhoneStatisticsPeriod = .week
  @State private var harness: Harness?
  @State private var compare = false
  @State private var refreshRevision = 0
  @State private var customFrom = Date().addingTimeInterval(-7 * 86_400)
  @State private var customTo = Date()
  @State private var appliedFrom = Date().addingTimeInterval(-7 * 86_400)
  @State private var appliedTo = Date()
  @State private var customRevision = 0
  @State private var hasAppliedCustomRange = false
  @State private var histogramMode: PhoneHistogramMode = .agentTime
  @State private var hasSeenQuerySupport = false

  private var showsQueryControls: Bool {
    model.supportsAnalyticsQueries || hasSeenQuerySupport
      || (!model.isConnected && model.requestedReport != nil)
  }

  private var queryID: String {
    // Editing custom dates does not send a request until Apply is tapped.
    "\(period.rawValue)-\(harness?.rawValue ?? "all")-\(compare)-\(refreshRevision)-\(customRevision)-\(model.supportsAnalyticsQueries)-\(model.isConnected)"
  }

  private var displayedReport: AnalyticsReport? {
    if showsQueryControls { return model.requestedReport }
    return model.reports[period == .month ? "month" : "week"]
  }

  private var validCustomRange: Bool {
    let length = customTo.timeIntervalSince(customFrom)
    return length > 0 && length <= 366 * 86_400
      && customTo.timeIntervalSince1970 <= Date().timeIntervalSince1970
  }

  var body: some View {
    NavigationStack {
      List {
        filters
        connectionState
        if model.statisticsLoading {
          Section { ProgressView("Loading measured history…").frame(minHeight: 44) }
        }
        if let error = model.statisticsError, showsQueryControls {
          Section {
            Label("Statistics could not refresh", systemImage: "exclamationmark.triangle")
            Text(error).foregroundStyle(.secondary)
            Button("Try again") { refresh() }.frame(minHeight: 44)
              .disabled(!model.isConnected || !model.supportsAnalyticsQueries)
          }
        }
        if let report = displayedReport {
          PhoneStatisticsReportSections(
            report: report,
            comparison: compare && showsQueryControls ? model.comparisonReport : nil,
            histogramMode: $histogramMode)
        } else if !model.statisticsLoading {
          Section {
            ContentUnavailableView(
              "No statistics received", systemImage: "chart.bar.xaxis",
              description: Text(
                "Connect to your paired Mac while Swarmbell is running to receive measured history. Earlier activity is not backfilled."
              ))
          }
        }
      }
      .navigationTitle("Statistics")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
            .disabled(
              !model.isConnected || model.statisticsLoading || !model.supportsAnalyticsQueries)
        }
      }
      .task(id: queryID) { requestReport() }
      .onChange(of: model.supportsAnalyticsQueries, initial: true) { _, supported in
        if supported { hasSeenQuerySupport = true }
      }
      .onChange(of: model.receivedAt) { _, receivedAt in
        // Only decide an older Mac's capabilities after its first envelope arrives.
        // A connected TLS socket has not advertised any capabilities yet.
        guard receivedAt != nil, model.isConnected, !model.supportsAnalyticsQueries else { return }
        hasSeenQuerySupport = false
        if period == .day || period == .custom { period = .week }
        harness = nil
        compare = false
      }
    }
  }

  private var filters: some View {
    Section {
      Picker("Period", selection: $period) {
        ForEach(PhoneStatisticsPeriod.allCases) { item in
          if showsQueryControls || item == .week || item == .month {
            Text(item.label).tag(item)
          }
        }
      }.frame(minHeight: 44)
      if showsQueryControls {
        if period == .custom {
          DatePicker("From", selection: $customFrom, in: ...Date())
          DatePicker("To", selection: $customTo, in: ...Date())
          Button("Apply dates") {
            appliedFrom = customFrom
            appliedTo = customTo
            hasAppliedCustomRange = true
            customRevision += 1
          }
          .frame(minHeight: 44).disabled(!validCustomRange || !model.isConnected)
          if !validCustomRange {
            Text("Choose an end after the start, with a range of at most 366 days.")
              .font(.caption).foregroundStyle(.secondary)
          } else if !hasAppliedCustomRange || customFrom != appliedFrom || customTo != appliedTo {
            Text("Tap Apply dates to load this range.").font(.caption).foregroundStyle(.secondary)
          }
        }
        Picker("Harness", selection: $harness) {
          Text("All harnesses").tag(nil as Harness?)
          ForEach(Harness.allCases, id: \.self) { item in
            Text(item.phoneName).tag(Optional(item))
          }
        }.frame(minHeight: 44)
        Toggle("Compare with previous period", isOn: $compare).frame(minHeight: 44)
      }
    } header: {
      Text("Report range")
    } footer: {
      Text("Statistics are read-only. Agent time adds simultaneous agents together.")
    }
    .disabled(showsQueryControls && !model.isConnected)
  }

  private var connectionState: some View {
    Section {
      if !model.isConnected {
        Label("Mac disconnected · cached history", systemImage: "wifi.slash")
        Text("Displayed reports stay at their generated time until your Mac reconnects.")
          .font(.caption).foregroundStyle(.secondary)
      } else if !model.supportsAnalyticsQueries {
        Label("Standard reports from your Mac", systemImage: "desktopcomputer")
        Text(
          "This Mac shares 7-day and 30-day reports. Update Swarmbell on your Mac for custom dates, harness filters and comparisons."
        ).font(.caption).foregroundStyle(.secondary)
      }
      if let report = displayedReport {
        Text("Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.subheadline)
        Text(
          "\(report.from.formatted(date: .abbreviated, time: .shortened)) – \(report.to.formatted(date: .abbreviated, time: .shortened)) · \(report.timeZoneID)"
        ).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func requestReport() {
    guard model.supportsAnalyticsQueries, model.isConnected,
      period != .custom || hasAppliedCustomRange
    else { return }
    // Anchor presets when a request is sent, including after foreground reconnects.
    // This is not view state, so refreshing the anchor cannot trigger another query.
    let to = period == .custom ? appliedTo : Date()
    let from = period == .custom ? appliedFrom : to.addingTimeInterval(-period.seconds)
    model.loadStatistics(from: from, to: to, harness: harness, compare: compare)
  }

  private func refresh() {
    refreshRevision += 1
  }
}
