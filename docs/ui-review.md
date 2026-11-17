# Native UI and session-navigation review

The user's reported issues are treated as acceptance failures, not cosmetic notes.

| Report | Cause | Fix and acceptance |
|---|---|---|
| Histogram label splits into many tiny lines | Native picker label competes with segmented control inside a fixed narrow frame | Hide the redundant native label, preserve accessibility text, and allocate the control its intrinsic width. Inspect actual default and compact windows. |
| Harness selection is truncated | Picker width includes both native label and selection | Stack a caption above a fully allocated picker; verify All harnesses and Claude Code at supported widths. |
| Other cramped text | Four summaries and two histograms remain side by side at every width | Adaptive summaries, histograms, custom-date controls, hover labels, long agent rows and backup display. |
| Claude row opens an empty Terminal | Interactive CLI was incorrectly assumed to be Terminal-hosted; current sessions are owned by Claude Desktop | Verify live process ancestry, resolve the CLI UUID through Desktop metadata, and navigate to the existing Desktop conversation. Never launch a blank Terminal as fallback. |
| Navigation failure is invisible | Popover/panel closes before activation result | Close only on accepted exact-thread activation. Keep unsupported/failed actions open with visible feedback and an explicit copy-ID action. |
| Menu bar click brings Statistics forward | App-wide activation raises the existing main window while presenting the popover | Focus only the status popover. Statistics opens only through its explicit action. |
| Statistics cannot be closed | Missing standard Close Window command; system sharing overlay can cover native traffic lights | Standard File → Close Window (Command-W), plus an explicit Close control in the dashboard. Closing preserves background collection. |
| Working agents hidden below the first row | A scroll view had no intrinsic height and its maximum-height constraint allowed it to collapse | Measure content, header and footer; give the viewport an explicit height capped at 460pt and the opening display's available height. Expanded groups scroll within that bound. |

## Verification matrix

- Default 1080×820 and compact 900×650: readable header controls, summaries, custom dates, chart legends, histogram/heatmap selectors and lower diagnostics.
- All harnesses, Claude Code, day/week/month and custom date filters; useful empty/error states and no stale filters applied to unlabeled old data.
- Menu bar opens the menu alone, including when Statistics already exists in the background.
- Close Statistics with the visible button and Command-W; ensure collection continues and a subsequent status click does not reopen Statistics.
- Global shortcut opens the switcher; search, selection, Return and Escape work.
- Click the Claude session that previously launched Terminal and verify the actual Desktop conversation/title. Test a Codex row independently.
- Unsupported routes provide visible, truthful feedback and do not launch an unrelated application.

The final native checks are recorded in validation.md. No web detector is treated as evidence for native SwiftUI layout.
