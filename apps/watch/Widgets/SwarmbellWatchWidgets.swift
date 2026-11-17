import SwiftUI
import WidgetKit

@main
struct SwarmbellWatchWidgets: WidgetBundle {
  var body: some Widget { SwarmbellWatchCountsWidget() }
}

struct SwarmbellWatchCountsWidget: Widget {
  let kind = GlanceConstants.widgetKind

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: GlanceProvider()) { entry in
      GlanceWidgetContent(entry: entry)
    }
    .configurationDisplayName("Agent counts")
    .description("Last known active agents and agents needing your help, synced from your iPhone.")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}
