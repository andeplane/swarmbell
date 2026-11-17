import SwiftUI

@main
struct SwarmbellWatchApp: App {
  @StateObject private var receiver = WatchReceiver.shared
  @Environment(\.scenePhase) private var scenePhase

  init() {
    // Install the receiver for background launches as well as foreground views.
    WatchReceiver.shared.activate()
  }

  var body: some Scene {
    WindowGroup {
      WatchCountsView(receiver: receiver)
        .task { receiver.activate() }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active {
            receiver.readReceivedContext()
            receiver.requestLatest()
          }
        }
    }
    .backgroundTask(.watchConnectivity) {
      await WatchReceiver.shared.readReceivedContext()
    }
  }
}

private struct WatchCountsView: View {
  @ObservedObject var receiver: WatchReceiver

  var body: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: 5)) { context in
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if let snapshot = receiver.snapshot {
              counts(snapshot)
              freshness(snapshot, at: context.date)
              if snapshot.incomplete {
                Label("Partial coverage", systemImage: "exclamationmark.triangle")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              if receiver.syncUnavailable {
                Text("Sync unavailable. Showing the last received counts.")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            } else {
              HStack(alignment: .firstTextBaseline) {
                count(nil, label: "Active", color: .blue)
                count(nil, label: "Needs you", color: .orange)
              }
              Text("Open Swarmbell on your iPhone to sync agent counts.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 4)
        }
        .navigationTitle("Swarmbell")
      }
    }
  }

  private func counts(_ snapshot: GlanceSnapshot) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      count(snapshot.active, label: "Active", color: .blue)
      count(snapshot.needsYou, label: "Needs you", color: .orange)
    }
  }

  private func count(_ value: Int?, label: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value.map(String.init) ?? "–")
        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
        .foregroundStyle(color)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .privacySensitive()
      Text(label).font(.caption).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(label): \(value.map(String.init) ?? "unavailable")")
  }

  private func freshness(_ snapshot: GlanceSnapshot, at now: Date) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      if snapshot.isCurrent(at: now) {
        Text("\(snapshot.working) working")
          .font(.footnote)
      } else {
        Text("Last known counts")
          .font(.footnote.weight(.medium))
        if snapshot.connection != .connected {
          Text("Mac disconnected").font(.caption2).foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 3) {
        Text("Updated")
        Text(snapshot.observedAt, style: .relative)
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }
}
