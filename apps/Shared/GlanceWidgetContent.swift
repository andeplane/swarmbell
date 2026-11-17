import SwiftUI
import WidgetKit

struct GlanceEntry: TimelineEntry {
  let date: Date
  let snapshot: GlanceSnapshot?
}

/// Extensions read the local aggregate cache; only the companion app contacts the Mac.
struct GlanceProvider: TimelineProvider {
  func placeholder(in context: Context) -> GlanceEntry {
    GlanceEntry(date: Date(), snapshot: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
    completion(GlanceEntry(date: Date(), snapshot: GlanceStore.shared.load()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
    let now = Date()
    let entry = GlanceEntry(date: now, snapshot: GlanceStore.shared.load())
    // WidgetKit schedules the actual refresh. Never imply five-second widget polling.
    completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
  }
}

struct GlanceWidgetContent: View {
  let entry: GlanceEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    Group {
      switch family {
      case .accessoryCircular:
        circular
      case .accessoryRectangular:
        rectangular
      case .accessoryInline:
        inline
      #if os(iOS)
        case .systemMedium:
          home(isMedium: true)
        case .systemSmall:
          home(isMedium: false)
      #endif
      default:
        rectangular
      }
    }
    .widgetURL(GlanceConstants.appURL)
    .containerBackground(.fill.tertiary, for: .widget)
  }

  private func number(_ value: Int?) -> String { value.map(String.init) ?? "–" }

  private var circular: some View {
    VStack(spacing: 1) {
      HStack(spacing: 5) {
        compactCount(entry.snapshot?.active, label: "Active", color: .blue)
        compactCount(entry.snapshot?.needsYou, label: "You", color: .orange)
      }
      Text(entry.snapshot == nil ? "No data" : "Last known")
        .font(.system(size: 8, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }

  private func compactCount(_ value: Int?, label: String, color: Color) -> some View {
    VStack(spacing: 0) {
      Text(number(value))
        .font(.system(.title3, design: .rounded, weight: .semibold))
        .monospacedDigit()
        .minimumScaleFactor(0.5)
        .lineLimit(1)
        .foregroundStyle(color)
        .widgetAccentable()
        .privacySensitive()
      Text(label).font(.system(size: 8, weight: .bold))
    }
  }

  private var rectangular: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        accessoryCount(entry.snapshot?.active, label: "Active", color: .blue)
        accessoryCount(entry.snapshot?.needsYou, label: "Needs you", color: .orange)
      }
      if let snapshot = entry.snapshot {
        HStack(spacing: 3) {
          Text("Last known ·")
          Text(snapshot.observedAt, style: .relative)
          if snapshot.incomplete { Image(systemName: "exclamationmark.triangle") }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      } else {
        Text("Open Swarmbell to sync").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }

  private func accessoryCount(_ value: Int?, label: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(number(value))
        .font(.system(.title2, design: .rounded, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(color)
        .widgetAccentable()
        .privacySensitive()
        .lineLimit(1)
        .minimumScaleFactor(0.5)
      Text(label).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var inline: some View {
    if let snapshot = entry.snapshot {
      Text("Last known: \(snapshot.active) active · \(snapshot.needsYou) need you")
        .privacySensitive()
        .accessibilityLabel(accessibilitySummary)
    } else {
      Text("Swarmbell: open to sync")
    }
  }

  #if os(iOS)
    private func home(isMedium: Bool) -> some View {
      VStack(alignment: .leading, spacing: isMedium ? 12 : 10) {
        HStack {
          Text("Swarmbell").font(.subheadline.weight(.semibold))
          Spacer(minLength: 0)
          if entry.snapshot?.incomplete == true {
            Image(systemName: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Partial coverage")
          }
        }
        HStack(alignment: .firstTextBaseline, spacing: isMedium ? 32 : 12) {
          homeCount(entry.snapshot?.active, label: "Active", color: .blue)
          homeCount(entry.snapshot?.needsYou, label: "Needs you", color: .orange)
        }
        Spacer(minLength: 0)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.snapshot == nil ? "No agent data" : "Last known counts")
            .font(.caption.weight(.medium))
          if let snapshot = entry.snapshot {
            HStack(spacing: 3) {
              Text("Updated")
              Text(snapshot.observedAt, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          } else {
            Text("Open the app to sync").font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
    }

    private func homeCount(_ value: Int?, label: String, color: Color) -> some View {
      VStack(alignment: .leading, spacing: 1) {
        Text(number(value))
          .font(.system(.largeTitle, design: .rounded, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(color)
          .widgetAccentable()
          .privacySensitive()
          .lineLimit(1)
          .minimumScaleFactor(0.5)
        Text(label).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(label): \(value.map(String.init) ?? "unavailable"), last known")
    }
  #endif

  private var accessibilitySummary: String {
    guard let snapshot = entry.snapshot else {
      return "Swarmbell. Counts unavailable. Open the app to sync."
    }
    let coverage = snapshot.incomplete ? " Partial coverage." : ""
    return
      "Last known counts: \(snapshot.active) active agents, \(snapshot.needsYou) need you. Updated \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened)).\(coverage)"
  }
}
