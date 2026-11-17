import Charts
import SwiftUI

struct PhoneStatisticsView: View {
  @ObservedObject var model: BeaconPhoneModel
  @State private var period = "week"
  var body: some View {
    NavigationStack {
      List {
        Section {
          Picker("Period", selection: $period) {
            Text("Last 7 days").tag("week")
            Text("Last 30 days").tag("month")
          }.pickerStyle(.segmented)
        }
        if let report = model.reports[period] {
          Section {
            LabeledContent(
              "Average active",
              value: report.summary.meanActiveAgents.formatted(
                .number.precision(.fractionLength(1))))
            LabeledContent(
              "Working agent time", value: duration(report.summary.workingAgentSeconds))
            LabeledContent(
              "Waiting agent time", value: duration(report.summary.waitingAgentSeconds))
            LabeledContent("Observed time", value: duration(report.summary.observedSeconds))
            Text("Agent time adds simultaneous agents together. Unobserved time remains a gap.")
              .font(.caption).foregroundStyle(.secondary)
          } header: {
            Text("Measured on your Mac")
          } footer: {
            Text(
              "Report updated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened)). \(report.sampleCount.formatted()) refreshes in the selected period."
            )
          }
          Section("Agent activity") {
            if report.timeSeries.contains(where: { $0.active != nil }) {
              Chart {
                ForEach(report.timeSeries) { point in
                  if let value = point.working {
                    LineMark(
                      x: .value("Time", point.timestamp), y: .value("Agents", value),
                      series: .value("Segment", "working-\(point.segment)")
                    )
                    .foregroundStyle(by: .value("State", "Working"))
                  }
                  if let value = point.needsYou {
                    LineMark(
                      x: .value("Time", point.timestamp), y: .value("Agents", value),
                      series: .value("Segment", "waiting-\(point.segment)")
                    )
                    .foregroundStyle(by: .value("State", "Needs you"))
                  }
                  if let value = point.active {
                    LineMark(
                      x: .value("Time", point.timestamp), y: .value("Agents", value),
                      series: .value("Segment", "active-\(point.segment)")
                    )
                    .foregroundStyle(by: .value("State", "Active total"))
                    .lineStyle(StrokeStyle(dash: [4, 3]))
                  }
                }
              }
              .chartForegroundStyleScale([
                "Working": Color.blue, "Needs you": .orange, "Active total": .secondary,
              ])
              .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
              .frame(height: 220).padding(.vertical, 8)
              .accessibilityLabel(
                "Confirmed agent activity over time. Blue is working; orange needs you; dashed is active total."
              )
            } else {
              Text("Waiting for consecutive observations.").foregroundStyle(.secondary)
            }
          }
          histogram("Hour of day", bins: report.hourly, timeZone: report.timeZoneID)
          histogram("Day of week", bins: report.weekdays, timeZone: report.timeZoneID)
          Section("Attention") {
            LabeledContent("Observed episodes", value: report.summary.attentionEpisodes.formatted())
            LabeledContent(
              "Completed episodes", value: report.summary.completedEpisodes.formatted())
            ForEach(report.attentionReasons) { reason in
              LabeledContent(reason.reason, value: duration(reason.waitingAgentSeconds))
            }
          }
          Section("Collection") {
            LabeledContent(
              "Average refresh",
              value:
                "\(report.refreshLatency.meanMilliseconds.formatted(.number.precision(.fractionLength(0)))) ms"
            )
            LabeledContent(
              "95th percentile",
              value:
                "\(report.refreshLatency.p95Milliseconds.formatted(.number.precision(.fractionLength(0)))) ms"
            )
            LabeledContent(
              "Source availability",
              value: report.summary.sourceAvailabilityFraction.formatted(
                .percent.precision(.fractionLength(1))))
            Text(
              "Coverage and refresh timings describe what the Mac could observe, not agent productivity."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          if !report.insights.isEmpty {
            Section("What to look at") {
              ForEach(report.insights, id: \.self) { Text($0).font(.subheadline) }
            }
          }
        } else {
          Section {
            ContentUnavailableView(
              "No statistics received", systemImage: "chart.bar.xaxis",
              description: Text(
                "Your paired Mac shares measured history while Agent Beacon is running. No sample history is added."
              ))
          }
        }
      }.navigationTitle("Statistics")
    }
  }

  private func histogram(_ title: String, bins: [AnalyticsBucket], timeZone: String) -> some View {
    Section {
      Chart {
        ForEach(bins) { bin in
          BarMark(
            x: .value(title, bin.label), y: .value("Agent minutes", bin.workingAgentSeconds / 60)
          )
          .foregroundStyle(by: .value("State", "Working"))
          BarMark(
            x: .value(title, bin.label), y: .value("Agent minutes", bin.waitingAgentSeconds / 60)
          )
          .foregroundStyle(by: .value("State", "Needs you"))
        }
      }
      .chartForegroundStyleScale(["Working": Color.blue, "Needs you": .orange])
      .chartXAxis {
        AxisMarks(values: bins.filter { title != "Hour of day" || $0.index % 3 == 0 }.map(\.label))
      }
      .frame(height: 180).padding(.vertical, 8)
      .accessibilityLabel("\(title) histogram of working and waiting agent minutes")
    } header: {
      Text(title)
    } footer: {
      Text(
        "Agent minutes across observed intervals in \(timeZone). Empty positions have no observations."
      )
    }
  }

  private func duration(_ seconds: Double) -> String {
    let minutes = Int(max(0, seconds) / 60)
    if seconds <= 0 { return "0m" }
    if minutes < 1 { return "<1m" }
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
  }
}
