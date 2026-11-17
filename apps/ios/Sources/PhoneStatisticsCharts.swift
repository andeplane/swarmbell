import Charts
import SwiftUI

enum PhoneHistogramMode: String, CaseIterable, Identifiable {
  case agentTime, averageActive
  var id: String { rawValue }
  var label: String { self == .agentTime ? "Agent time" : "Average active" }
}

struct PhoneStatisticsActivityChart: View {
  let points: [AnalyticsPoint]
  var body: some View {
    if points.contains(where: { $0.active != nil }) {
      Chart {
        ForEach(points) { point in
          if let value = point.working {
            LineMark(
              x: .value("Time", point.timestamp), y: .value("Agents", value),
              series: .value("Segment", "working-\(point.segment)")
            )
            .foregroundStyle(by: .value("State", "Working"))
            .interpolationMethod(.stepEnd)
            PointMark(x: .value("Time", point.timestamp), y: .value("Agents", value))
              .foregroundStyle(by: .value("State", "Working")).symbolSize(8)
          }
          if let value = point.needsYou {
            LineMark(
              x: .value("Time", point.timestamp), y: .value("Agents", value),
              series: .value("Segment", "waiting-\(point.segment)")
            )
            .foregroundStyle(by: .value("State", "Needs you"))
            .interpolationMethod(.stepEnd)
            PointMark(x: .value("Time", point.timestamp), y: .value("Agents", value))
              .foregroundStyle(by: .value("State", "Needs you")).symbolSize(8)
          }
          if let value = point.active {
            LineMark(
              x: .value("Time", point.timestamp), y: .value("Agents", value),
              series: .value("Segment", "active-\(point.segment)")
            )
            .foregroundStyle(by: .value("State", "Active total"))
            .lineStyle(StrokeStyle(dash: [4, 3])).interpolationMethod(.stepEnd)
            PointMark(x: .value("Time", point.timestamp), y: .value("Agents", value))
              .foregroundStyle(by: .value("State", "Active total")).symbolSize(8)
          }
        }
      }
      .chartForegroundStyleScale([
        "Working": Color.blue, "Needs you": .orange, "Active total": .secondary,
      ])
      .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
      .frame(height: 240).padding(.vertical, 8)
      .accessibilityLabel(
        "Measured concurrent agents over time. Working, needs you, and active total. Gaps are not observed."
      )
    } else {
      Text("Waiting for consecutive observations to establish activity intervals.")
        .foregroundStyle(.secondary).padding(.vertical, 16)
    }
  }
}

struct PhoneStatisticsHistogram: View {
  let title: String
  let bins: [AnalyticsBucket]
  let mode: PhoneHistogramMode
  let hourly: Bool
  private var hasObservations: Bool { bins.contains { $0.observedSeconds > 0 } }

  var body: some View {
    Section {
      if hasObservations {
        Chart {
          ForEach(bins.filter { $0.observedSeconds > 0 }) { bin in
            if mode == .agentTime {
              BarMark(
                x: .value(title, bin.index),
                y: .value("Agent hours", bin.workingAgentSeconds / 3600)
              )
              .foregroundStyle(by: .value("State", "Working"))
              BarMark(
                x: .value(title, bin.index),
                y: .value("Agent hours", bin.waitingAgentSeconds / 3600)
              )
              .foregroundStyle(by: .value("State", "Needs you"))
            } else {
              BarMark(
                x: .value(title, bin.index), y: .value("Average active", bin.meanActiveAgents)
              )
              .foregroundStyle(Color.blue)
            }
          }
        }
        .chartForegroundStyleScale(["Working": Color.blue, "Needs you": .orange])
        .chartXScale(domain: hourly ? -0.5...23.5 : 0.5...7.5)
        .chartXAxis {
          AxisMarks(values: bins.filter { !hourly || $0.index.isMultiple(of: 4) }.map(\.index)) {
            value in
            AxisGridLine()
            AxisValueLabel {
              if let index = value.as(Int.self), let bin = bins.first(where: { $0.index == index })
              {
                Text(hourly ? String(format: "%02d", index) : String(bin.label.prefix(3)))
              }
            }
          }
        }
        .chartYAxisLabel(mode == .agentTime ? "Agent hours" : "Average active")
        .frame(height: 210).padding(.vertical, 8)
        .accessibilityLabel("\(title), \(mode.label). Empty positions have no observations.")
        DisclosureGroup("Measured values") {
          ForEach(bins) { bin in
            VStack(alignment: .leading, spacing: 4) {
              Text(bin.label)
              if bin.observedSeconds > 0 {
                Text(
                  "\(PhoneStatisticsFormat.duration(bin.workingAgentSeconds)) working · \(PhoneStatisticsFormat.duration(bin.waitingAgentSeconds)) waiting · \(PhoneStatisticsFormat.number(bin.meanActiveAgents)) average active"
                )
                .font(.subheadline).foregroundStyle(.secondary)
                Text(
                  "\(PhoneStatisticsFormat.duration(bin.observedSeconds)) observed · \(bin.peakActiveAgents) peak · \(bin.attentionEpisodes) attention episodes"
                )
                .font(.caption).foregroundStyle(.secondary)
              } else {
                Text("Not observed").foregroundStyle(.secondary)
              }
            }.padding(.vertical, 4).accessibilityElement(children: .combine)
          }
        }.padding(.vertical, 6)
      } else {
        Text("No observed intervals in this range.").foregroundStyle(.secondary)
      }
    } header: {
      Text(title)
    }
  }
}

private enum PhoneHeatmapMode: String, CaseIterable, Identifiable {
  case waiting, active
  var id: String { rawValue }
  var label: String { self == .waiting ? "Needs you" : "Active agents" }
}

struct PhoneStatisticsHeatmap: View {
  let cells: [AnalyticsHeatmapCell]
  @State private var mode: PhoneHeatmapMode = .waiting
  private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  private var peak: Double { max(1, cells.map(value).max() ?? 1) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker("Heatmap measure", selection: $mode) {
        ForEach(PhoneHeatmapMode.allCases) { item in Text(item.label).tag(item) }
      }.frame(minHeight: 44)
      if cells.contains(where: { $0.observedSeconds > 0 }) {
        ScrollView(.horizontal) {
          Grid(horizontalSpacing: 4, verticalSpacing: 6) {
            GridRow {
              Text("").frame(width: 40)
              ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d", hour)).font(.caption.monospacedDigit())
                  .frame(width: 26).accessibilityHidden(true)
              }
            }
            ForEach(1...7, id: \.self) { day in
              GridRow {
                Text(days[day - 1]).font(.caption).frame(width: 40, alignment: .leading)
                  .accessibilityHidden(true)
                ForEach(0..<24, id: \.self) { hour in heatmapCell(day: day, hour: hour) }
              }
            }
          }.padding(.bottom, 8)
        }
        Text(
          "Stronger color means more concurrent \(mode == .waiting ? "agents waiting on you" : "active agents")."
        )
        .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("No observed intervals in this range.").foregroundStyle(.secondary)
      }
    }
  }

  private func value(_ cell: AnalyticsHeatmapCell) -> Double {
    mode == .active
      ? cell.meanActiveAgents
      : cell.observedSeconds > 0 ? cell.waitingAgentSeconds / cell.observedSeconds : 0
  }

  private func heatmapCell(day: Int, hour: Int) -> some View {
    let cell = cells.first { $0.weekday == day && $0.hour == hour }
    let observed = (cell?.observedSeconds ?? 0) > 0
    let amount = cell.map(value) ?? 0
    let color =
      observed
      ? (mode == .waiting ? Color.orange : Color.blue).opacity(max(0.1, min(1, amount / peak)))
      : Color(uiColor: .tertiarySystemFill)
    let label =
      "\(days[day - 1]) \(String(format: "%02d:00", hour)): "
      + (observed
        ? "\(PhoneStatisticsFormat.number(amount)) average \(mode == .waiting ? "waiting" : "active"), \(PhoneStatisticsFormat.duration(cell?.observedSeconds ?? 0)) observed"
        : "not observed")
    return RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 26, height: 26)
      .accessibilityLabel(label)
  }
}
