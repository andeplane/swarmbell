# Native design direction

The first concept informed the native menu bar, quick-switcher and statistics surfaces, now implemented at the user's request.

## Menu bar

One compact monochrome symbol, confirmed active count, and a needs-you count. Amber draws attention when an agent needs the user. Numbers must also have accessible text labels. A compact popover groups needs-you rows above working rows, with a harness icon, title, project, state reason, and age. The footer opens the larger panel.

Partial coverage must be visible in the menu bar and list. A known count is a lower bound when any harness is unavailable or only partially observed. Unknown states must be visible without increasing the needs-you count.

## Quick switcher

A native floating panel with a search field and one unified list across all harnesses. Needs you comes first, then working, with recently finished below. Keyboard focus starts in search; arrows move selection, Return opens the exact selected conversation, and Escape closes and restores the previous app's focus.

Proposed shortcut: Control–Option–Space. Keep it configurable and detect conflicts. Do not commandeer Spotlight's Command–Space as a default.

## Visual treatment

Native dark/light materials, system typography, subtle separators, compact rows, and restrained selection color. Installed app icons provide source identity with SF-symbol fallbacks; color alone never communicates state. Respect reduced motion and increased contrast. No decorative cards or permanent Dock window are needed for this utility.

## Statistics

A scrollable native dashboard uses Swift Charts for activity, hourly and weekday histograms, and a weekday/hour heatmap. Controls select24hours,7days,30days,custom dates and a harness. Missing observations remain explicit; no data is generated to fill empty history. Labels distinguish agent-time, observed waiting, source coverage and collection latency. Both absolute agent-time and duration-weighted average concurrency are available for pattern comparisons. Small nonzero coverage is shown as below1%, never rounded to a misleading zero. Source/persistence errors remain visible independently of activity counts.

## Concept limitations

The generated board's labels, counts, project names, logos, and date are illustrative. Its example count is not reconciled to the displayed rows; production counts must follow the exact definitions in README.md. Replace approximate generated logos with suitable app assets when implementing. The attached screenshot supplies environmental context only.
