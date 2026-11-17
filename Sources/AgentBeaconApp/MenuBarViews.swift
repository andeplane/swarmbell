import AgentBeaconCore
import AppKit
import SwiftUI

@MainActor
struct MenuBarContent: View {
  @ObservedObject var model: AppModel
  @State private var measuredHeights: [MenuMeasuredRegion: CGFloat] = [:]
  @State private var availableScreenHeight: CGFloat = 800
  var openSwitcher: () -> Void
  var openDashboard: () -> Void
  var openSettings: () -> Void
  var close: () -> Void

  private var scrollHeight: CGFloat {
    let chrome = (measuredHeights[.header] ?? 72) + (measuredHeights[.footer] ?? 82)
    // Leave space for the popover arrow and dividers on the display that opened it.
    let limit = max(100, min(460, availableScreenHeight - chrome - 32))
    return min(limit, max(100, ceil(measuredHeights[.content] ?? 340)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Agent Beacon").font(.headline)
          Text(model.countsDescription).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          Task { await model.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(model.isRefreshing)
        .help("Refresh all sources")
        .accessibilityLabel("Refresh all sources")
      }
      .padding(16)
      .measureMenuHeight(.header)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if model.snapshot == nil {
            ProgressView("Checking your agents…").padding(.vertical, 20)
          } else {
            if !model.attention.isEmpty { section("Needs you", agents: model.attention) }
            if !model.working.isEmpty { section("Working", agents: model.working) }
            if model.attention.isEmpty && model.working.isEmpty {
              Label(
                "No confirmed active agents",
                systemImage: model.snapshot?.counts.incomplete == true
                  ? "questionmark.circle" : "pause.circle"
              )
              .foregroundStyle(.secondary).padding(.vertical, 12)
            }
            if !model.other.isEmpty {
              DisclosureGroup("Idle, finished & uncertain (\(model.other.count))") {
                ForEach(model.other.prefix(30)) { row in rowButton(row) }
              }
              .font(.subheadline)
              .padding(.top, 8)
            }
            sourceCoverage
          }
        }
        .padding(12)
        .fixedSize(horizontal: false, vertical: true)
        .measureMenuHeight(.content)
      }
      .frame(height: scrollHeight)
      Divider()
      VStack(spacing: 8) {
        Button(action: openSwitcher) {
          HStack {
            Text("Show all agents")
            Spacer()
            Text(model.shortcut.label).foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }.buttonStyle(.plain)
        HStack {
          Button("Statistics…", action: openDashboard)
          Spacer()
          Button {
            openSettings()
          } label: {
            Image(systemName: "gearshape")
          }
          .help("Settings").accessibilityLabel("Settings")
          Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
      }
      .padding(14)
      .measureMenuHeight(.footer)
    }
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
    .onPreferenceChange(MenuHeightsPreferenceKey.self) { heights in
      Task { @MainActor in
        if measuredHeights != heights { measuredHeights = heights }
      }
    }
    .onAppear(perform: updateAvailableScreenHeight)
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
    ) { _ in
      updateAvailableScreenHeight()
    }
  }

  private func updateAvailableScreenHeight() {
    let location = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    availableScreenHeight = screen?.visibleFrame.height ?? 800
  }

  private func section(_ title: String, agents: [AgentRecord]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(title) (\(agents.count))").font(.subheadline.weight(.semibold)).foregroundStyle(
        .secondary
      )
      .padding(.horizontal, 5).padding(.top, title == "Needs you" ? 0 : 10)
      ForEach(agents) { row in rowButton(row) }
    }
  }

  private func rowButton(_ agent: AgentRecord) -> some View {
    Button {
      if AgentNavigation.openApplication(agent, model: model) { close() }
    } label: {
      AgentRow(agent: agent)
    }
    .buttonStyle(AgentRowButtonStyle())
    .accessibilityHint(Text(agent.navigationActionLabel))
    .help(
      "\(agent.title)\n\(agent.harness.displayName) · \(agent.projectName)\n\(agent.navigationActionLabel)\n\(agent.navigation.explanation)"
    )
    .contextMenu {
      Button(agent.navigationActionLabel) {
        if AgentNavigation.openApplication(agent, model: model) { close() }
      }
      Button("Copy session ID") { AgentNavigation.copyID(agent, model: model) }
      if agent.workspace != nil {
        Button("Reveal project in Finder") { AgentNavigation.revealProject(agent) }
      }
    }
  }

  @ViewBuilder private var sourceCoverage: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !model.sourceIssues.isEmpty {
        Divider().padding(.vertical, 4)
        DisclosureGroup {
          ForEach(model.snapshot?.providers ?? [], id: \.harness) { source in
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Image(
                  systemName: source.health == .healthy
                    ? "checkmark.circle.fill" : "exclamationmark.triangle"
                )
                .foregroundStyle(source.health == .healthy ? Color.secondary : Color.orange)
                Text(source.harness.displayName).fontWeight(.medium)
              }
              Text(source.message).font(.caption).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
            }.padding(.vertical, 4)
          }
        } label: {
          Label(
            "Limited coverage in \(model.sourceIssues.count) sources",
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let error = model.snapshot?.historyError ?? model.analyticsError {
        Label(error, systemImage: "externaldrive.badge.exclamationmark").font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let message = model.navigationMessage {
        Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }
    }
  }
}

private enum MenuMeasuredRegion: Hashable, Sendable {
  case header, content, footer
}

private struct MenuHeightsPreferenceKey: PreferenceKey {
  static let defaultValue: [MenuMeasuredRegion: CGFloat] = [:]
  static func reduce(
    value: inout [MenuMeasuredRegion: CGFloat], nextValue: () -> [MenuMeasuredRegion: CGFloat]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

extension View {
  fileprivate func measureMenuHeight(_ region: MenuMeasuredRegion) -> some View {
    background(
      GeometryReader { geometry in
        Color.clear.preference(
          key: MenuHeightsPreferenceKey.self, value: [region: geometry.size.height])
      })
  }
}

struct AgentRow: View {
  let agent: AgentRecord
  var selected = false
  var body: some View {
    HStack(spacing: 10) {
      Circle().fill(dotColor).frame(width: 6, height: 6).accessibilityHidden(true)
      HarnessIcon(harness: agent.harness).frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 3) {
        Text(agent.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Text("\(agent.harness.displayName) · \(agent.projectName)")
          .font(.caption).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
      }.layoutPriority(1)
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 3) {
        Text(agent.stateDescription).font(.caption).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Text(agent.changedAt, style: .relative).font(.caption2).foregroundStyle(
          selected ? .primary : .secondary)
        Text(agent.tokenUsageDescription)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(selected ? .primary : .secondary)
          .lineLimit(1)
          .help(agent.tokenUsageHelp)
          .accessibilityLabel(agent.tokenUsageHelp)
      }.frame(minWidth: 65, maxWidth: 115, alignment: .trailing)
      Image(
        systemName: agent.navigation.kind == .openDesktopThread
          ? "arrow.up.forward.app" : "doc.on.doc"
      )
      .font(.caption2)
      .foregroundStyle(selected ? Color.white : Color.secondary)
      .accessibilityLabel(agent.navigationActionLabel)
    }
    .foregroundStyle(selected ? Color.white : Color.primary)
    .padding(.horizontal, 8).padding(.vertical, 9)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
  private var dotColor: Color {
    if agent.freshness != .current { return .secondary }
    return agent.state == .needsYou ? .orange : (agent.state == .failed ? .red : .secondary)
  }
}

struct HarnessIcon: View {
  let harness: Harness
  var body: some View {
    Group {
      if let image = HarnessImageCache.image(for: harness) {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(systemName: harness.symbol).font(.system(size: 20, weight: .medium)).frame(
          maxWidth: .infinity, maxHeight: .infinity)
      }
    }.accessibilityLabel(harness.displayName)
  }
}

@MainActor
private enum HarnessImageCache {
  private static var icons: [Harness: NSImage] = [:]
  private static var checked = Set<Harness>()
  static func image(for harness: Harness) -> NSImage? {
    if checked.contains(harness) { return icons[harness] }
    checked.insert(harness)
    if let app = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: harness.applicationBundleID)
    {
      icons[harness] = NSWorkspace.shared.icon(forFile: app.path)
    }
    return icons[harness]
  }
}

struct AgentRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.background(
      configuration.isPressed ? Color.primary.opacity(0.09) : .clear,
      in: RoundedRectangle(cornerRadius: 7))
  }
}

struct BeaconSettingsView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    Form {
      CompanionSettingsSection(sharing: model.companion)
      Section("Quick switcher") {
        Picker("Global shortcut", selection: $model.shortcut) {
          ForEach(ShortcutChoice.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize(horizontal: true, vertical: false)
        if let message = model.shortcutMessage {
          Text(message).font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(
          "Opens the searchable agent list from any app. Spotlight’s Command–Space is left available."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Monitoring & history") {
        LabeledContent("Refresh interval", value: "5 seconds")
        LabeledContent(
          "History", value: model.historyStore == nil ? "Unavailable" : "Recorded locally")
        Text(
          "Every refresh records counts, source coverage and timings. Missing coverage is shown as unknown in statistics."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Cursor lifecycle observer") {
        Text(
          "Record work starting and stopping in Cursor. Native approval and question detection is still unavailable."
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Install observer") { Task { await model.installCursorObserver() } }
            .help(
              "Install or update Agent Beacon's passive lifecycle hooks, preserving existing hooks")
          Button("Remove observer") { Task { await model.removeCursorObserver() } }
          if model.isUpdatingCursorObserver { ProgressView().controlSize(.small) }
        }
        .disabled(model.isUpdatingCursorObserver)
        if let message = model.cursorSetupMessage {
          Text(message).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let error = model.cursorSetupError {
          Text(error).font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let backup = model.cursorSetupBackupURL {
          VStack(alignment: .leading, spacing: 4) {
            Text("Backup saved").font(.caption).foregroundStyle(.secondary)
            Text(backup.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle).help(backup.path)
              .textSelection(.enabled)
            Button("Reveal backup in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([backup])
            }.font(.caption)
          }
        }
      }
      Section("Opening sessions") {
        Text(
          "Selecting a session opens its original conversation when an exact route is available. Otherwise, Agent Beacon explains the available action. Busy conversations are never resumed automatically."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped).padding(8).frame(width: 500, height: 380)
  }
}
