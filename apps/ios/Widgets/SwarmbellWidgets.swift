import SwiftUI
import WidgetKit

@main
struct SwarmbellWidgets: WidgetBundle {
  var body: some Widget { SwarmbellCountsWidget() }
}

struct SwarmbellCountsWidget: Widget {
  let kind = GlanceConstants.widgetKind

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: GlanceProvider()) { entry in
      GlanceWidgetContent(entry: entry)
    }
    .configurationDisplayName("Agent counts")
    .description("Last known active agents and agents needing your help, from your paired Mac.")
    .supportedFamilies([
      .systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline,
    ])
  }
}
