import AgentBeaconCore
import Charts
import SwiftUI

enum DashboardFormat {
  static func duration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0s" }
    if seconds < 60 { return "\(Int(seconds.rounded()))s" }
    if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
    return String(format: "%.1fh", seconds / 3600)
  }

  static func number(_ value: Double) -> String { String(format: "%.1f", value) }
  static func percent(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    let percent = max(0, min(1, value)) * 100
    if percent > 0, percent < 1 { return "<1%" }
    if percent >= 1, percent < 10 { return String(format: "%.1f%%", percent) }
    return "\(Int(percent.rounded()))%"
  }
  static func milliseconds(_ value: Double) -> String {
    value >= 1000 ? String(format: "%.2fs", value / 1000) : "\(Int(value.rounded()))ms"
  }

  static func date(
    _ date: Date, timeZone: TimeZone, includeDate: Bool = false, seconds: Bool = false
  ) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate(
      includeDate ? "MMMdHHmm" : seconds ? "HHmmss" : "HHmm")
    return formatter.string(from: date)
  }
}

extension Harness {
  var dashboardName: String {
    switch self {
    case .claudeCode: return "Claude Code"
    case .codex: return "Codex"
    case .cursor: return "Cursor"
    }
  }
}

enum DashboardHistogramMode: String, CaseIterable, Identifiable {
  case duration, concurrency
  var id: String { rawValue }
  var label: String { self == .duration ? "Agent time" : "Average active" }
}

struct DashboardLegend: View {
  var body: some View {
    HStack(spacing: 18) {
      entry("Working", color: .blue)
      entry("Needs you", color: .orange)
      entry("Active total", color: .secondary)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func entry(_ text: String, color: Color) -> some View {
    Label {
      Text(text)
    } icon: {
      Capsule().fill(color).frame(width: 16, height: 3)
    }
  }
}

@MainActor
struct DashboardTimeSeries: View {
  let points: [AnalyticsPoint]
  let timeZone: TimeZone
  @State private var selected: AnalyticsPoint?
  private var showPointMarkers: Bool { points.filter { $0.active != nil }.count <= 3 }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          DashboardLegend().fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 16)
          selectedValue
        }
        VStack(alignment: .leading, spacing: 8) {
          DashboardLegend()
          selectedValue
        }
      }
      Chart {
        ForEach(points) { point in
          if let working = point.working {
            LineMark(
              x: .value("Time", point.timestamp), y: .value("Working", working),
              series: .value("Segment", "working-\(point.segment)")
            )
            .foregroundStyle(Color.blue)
            .interpolationMethod(.stepEnd)
            if showPointMarkers {
              PointMark(x: .value("Time", point.timestamp), y: .value("Working", working))
                .foregroundStyle(Color.blue)
            }
          }
          if let waiting = point.needsYou {
            LineMark(
              x: .value("Time", point.timestamp), y: .value("Needs you", waiting),
              series: .value("Segment", "waiting-\(point.segment)")
            )
            .foregroundStyle(Color.orange)
            .interpolationMethod(.stepEnd)
            if showPointMarkers {
              PointMark(x: .value("Time", point.timestamp), y: .value("Needs you", waiting))
                .foregroundStyle(Color.orange)
            }
          }
          if let active = point.active {
            LineMark(
              x: .value("Time", point.timestamp), y: .value("Active", active),
              series: .value("Segment", "active-\(point.segment)")
            )
            .foregroundStyle(Color.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .interpolationMethod(.stepEnd)
            if showPointMarkers {
              PointMark(x: .value("Time", point.timestamp), y: .value("Active", active))
                .foregroundStyle(Color.secondary)
            }
          }
        }
        if let selected {
          RuleMark(x: .value("Selected time", selected.timestamp))
            .foregroundStyle(Color.secondary.opacity(0.4))
        }
      }
      .chartYScale(domain: 0...max(1, Double(points.map(\.peakActive).max() ?? 1)))
      .chartYAxisLabel("Average confirmed agents")
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 6)) { value in
          AxisGridLine()
          AxisTick()
          AxisValueLabel {
            if let date = value.as(Date.self) {
              Text(DashboardFormat.date(date, timeZone: timeZone, includeDate: true))
            }
          }
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geometry in
          Rectangle().fill(Color.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                if let date: Date = proxy.value(atX: x) {
                  selected = points.filter { $0.active != nil }.min {
                    abs($0.timestamp.timeIntervalSince(date))
                      < abs($1.timestamp.timeIntervalSince(date))
                  }
                }
              case .ended: selected = nil
              }
            }
        }
      }
      .frame(height: 230)
      .accessibilityLabel("Confirmed active, working, and needs-you agent counts over time")
      Text(
        "Values are duration-weighted bucket averages. Breaks mean no reliable observation; unavailable sources are not treated as idle."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var selectedValue: some View {
    if let selected {
      Text(selectionLabel(selected))
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private func selectionLabel(_ point: AnalyticsPoint) -> String {
    let time = DashboardFormat.date(point.timestamp, timeZone: timeZone, seconds: true)
    return
      "\(time) · \(DashboardFormat.number(point.active ?? 0)) active · \(DashboardFormat.number(point.needsYou ?? 0)) need you"
  }
}

struct DashboardHistogram: View {
  let bins: [AnalyticsBucket]
  let mode: DashboardHistogramMode
  let axis: String

  var body: some View {
    Chart {
      ForEach(bins) { bin in
        if bin.observedSeconds > 0 {
          if mode == .duration {
            BarMark(
              x: .value(axis, bin.label), y: .value("Agent minutes", bin.workingAgentSeconds / 60)
            )
            .foregroundStyle(Color.blue)
            .annotation(position: .overlay) { EmptyView() }
            BarMark(
              x: .value(axis, bin.label), y: .value("Agent minutes", bin.waitingAgentSeconds / 60)
            )
            .foregroundStyle(Color.orange)
          } else {
            BarMark(x: .value(axis, bin.label), y: .value("Average active", bin.meanActiveAgents))
              .foregroundStyle(Color.blue)
          }
        }
      }
    }
    .chartXScale(domain: bins.map(\.label))
    .chartYAxisLabel(mode == .duration ? "Agent minutes" : "Average active agents")
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: axis == "Hour" ? 8 : 7))
    }
    .frame(height: 180)
    .accessibilityLabel("\(axis) histogram, \(mode.label). Empty positions have no observations.")
  }
}

private enum DashboardHeatmapMode: String, CaseIterable, Identifiable {
  case active, waiting
  var id: String { rawValue }
  var label: String { self == .active ? "Active agents" : "Needs you" }
}

struct DashboardHeatmap: View {
  let cells: [AnalyticsHeatmapCell]
  @State private var mode: DashboardHeatmapMode = .waiting
  private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

  private var peak: Double { max(1, cells.map(value).max() ?? 1) }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Picker("Heatmap measure", selection: $mode) {
        ForEach(DashboardHeatmapMode.allCases) { item in Text(item.label).tag(item) }
      }
      .labelsHidden()
      .accessibilityLabel("Heatmap measure")
      .pickerStyle(.segmented).frame(width: 250)
      .fixedSize(horizontal: true, vertical: false)
      Grid(horizontalSpacing: 4, verticalSpacing: 4) {
        GridRow {
          Text("").frame(width: 32)
          ForEach(0..<24, id: \.self) { hour in
            Text(hour.isMultiple(of: 3) ? String(format: "%02d", hour) : "")
              .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
          }
        }
        ForEach(1...7, id: \.self) { weekday in
          GridRow {
            Text(days[weekday - 1]).font(.caption).foregroundStyle(.secondary).frame(
              width: 32, alignment: .leading)
            ForEach(0..<24, id: \.self) { hour in
              heatmapCell(weekday: weekday, hour: hour)
            }
          }
        }
      }
      Text(
        "Stronger color means more concurrent \(mode == .active ? "active agents" : "agents waiting on you"). Gray cells have no observations."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func heatmapCell(weekday: Int, hour: Int) -> some View {
    let cell = cells.first { $0.weekday == weekday && $0.hour == hour }
    let observed = (cell?.observedSeconds ?? 0) > 0
    let amount = cell.map(value) ?? 0
    let shade = observed ? max(0.10, min(1, amount / peak)) : 0
    let color: Color =
      observed
      ? (mode == .active ? Color.blue : Color.orange).opacity(shade)
      : Color(nsColor: .quaternaryLabelColor).opacity(0.45)
    let label =
      "\(days[weekday - 1]) \(String(format: "%02d:00", hour)) — "
      + (observed
        ? "\(DashboardFormat.number(amount)) average \(mode == .active ? "active" : "waiting"), \(DashboardFormat.duration(cell?.observedSeconds ?? 0)) observed"
        : "not observed")
    return RoundedRectangle(cornerRadius: 2).fill(color).frame(minWidth: 12, maxWidth: .infinity)
      .frame(height: 19)
      .help(label).accessibilityLabel(label)
  }

  private func value(_ cell: AnalyticsHeatmapCell) -> Double {
    mode == .active
      ? cell.meanActiveAgents
      : cell.observedSeconds > 0 ? cell.waitingAgentSeconds / cell.observedSeconds : 0
  }
}

struct DashboardMetric: View {
  let label: String
  let value: String
  let detail: String
  var tint: Color = .primary

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(value).font(.system(size: 27, weight: .semibold, design: .rounded))
        .monospacedDigit().foregroundStyle(tint)
        .fixedSize(horizontal: true, vertical: false)
      Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

struct DashboardSection<Content: View>: View {
  let title: String
  let detail: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title3.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
