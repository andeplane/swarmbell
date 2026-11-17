import AgentBeaconCore
import AppKit
import Combine
import SwiftUI

@MainActor
private final class SwitcherPanel: NSPanel {
  var escape: (() -> Void)?
  var move: ((Int) -> Void)?
  var activate: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown
      && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    {
      switch event.keyCode {
      case 53:
        escape?()
        return
      case 125:
        move?(1)
        return
      case 126:
        move?(-1)
        return
      case 36, 76:
        activate?()
        return
      default: break
      }
    }
    super.sendEvent(event)
  }
}

@MainActor
final class QuickSwitcherController: NSObject, ObservableObject, NSWindowDelegate {
  @Published var query = "" { didSet { ensureSelection() } }
  @Published var selectedID: String?
  let model: AppModel
  var openDashboard: (() -> Void)?
  private var panel: SwitcherPanel!
  private var previousApp: NSRunningApplication?
  private var sink: AnyCancellable?
  var isVisible: Bool { panel?.isVisible == true }
  var rows: [AgentRecord] {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return model.agents
    }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.agents.filter {
      [$0.title, $0.projectName, $0.harness.displayName, $0.stateDescription].contains {
        $0.localizedCaseInsensitiveContains(needle)
      }
    }
  }

  init(model: AppModel) {
    self.model = model
    super.init()
    panel = SwitcherPanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.delegate = self
    panel.contentView = NSHostingView(rootView: QuickSwitcherView(controller: self, model: model))
    panel.escape = { [weak self] in self?.hide() }
    panel.move = { [weak self] in self?.moveSelection($0) }
    panel.activate = { [weak self] in self?.activateSelection() }
    sink = model.$snapshot.sink { [weak self] _ in
      Task { @MainActor in self?.ensureSelection() }
    }
  }

  func toggle() { isVisible ? hide() : show() }
  func show(previousApplication: NSRunningApplication? = nil) {
    model.navigationMessage = nil
    if !isVisible { previousApp = previousApplication ?? NSWorkspace.shared.frontmostApplication }
    query = ""
    ensureSelection()
    if let screen = NSScreen.screens.first(where: {
      NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
    }) ?? NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(
        NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + 80))
    }
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    NotificationCenter.default.post(name: .beaconFocusSearch, object: nil)
  }

  func hide(restoreFocus: Bool = true) {
    panel.orderOut(nil)
    if restoreFocus, let previousApp,
      previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      previousApp.activate(options: [])
    }
    previousApp = nil
  }

  func showDashboard() {
    hide(restoreFocus: false)
    openDashboard?()
  }

  func windowDidResignKey(_ notification: Notification) {
    if isVisible { hide(restoreFocus: false) }
  }

  func ensureSelection() {
    if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) {
      selectedID = rows.first?.id
    }
  }
  func moveSelection(_ delta: Int) {
    let rows = rows
    guard !rows.isEmpty else { return }
    let index = rows.firstIndex(where: { $0.id == selectedID }) ?? 0
    selectedID = rows[max(0, min(rows.count - 1, index + delta))].id
  }
  func activateSelection() {
    guard let row = rows.first(where: { $0.id == selectedID }) else { return }
    if AgentNavigation.openApplication(row, model: model) { hide(restoreFocus: false) }
  }
}

extension Notification.Name {
  static let beaconFocusSearch = Notification.Name("AgentBeaconFocusSearch")
}

private struct QuickSwitcherView: View {
  @ObservedObject var controller: QuickSwitcherController
  @ObservedObject var model: AppModel
  @FocusState private var searchFocused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
        TextField("Search agents or projects…", text: $controller.query)
          .textFieldStyle(.plain).font(.title2).focused($searchFocused)
      }.padding(22)
      HStack {
        Text(model.countsDescription)
        Spacer()
        if model.snapshot?.counts.incomplete == true {
          Label("Partial coverage", systemImage: "exclamationmark.triangle")
        }
      }.font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 14)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 3) {
            if controller.rows.isEmpty {
              ContentUnavailableText(
                title: controller.query.isEmpty ? "No sessions observed" : "No matching agents",
                detail: controller.query.isEmpty
                  ? "Source setup and coverage are available from the menu bar."
                  : "Try a project, harness or task name.")
            }
            ForEach(Array(controller.rows.enumerated()), id: \.element.id) { index, agent in
              if index == 0 || group(controller.rows[index - 1]) != group(agent) {
                Text(group(agent)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                  .padding(.horizontal, 10).padding(.top, index == 0 ? 6 : 16).padding(.bottom, 3)
              }
              Button {
                controller.selectedID = agent.id
                controller.activateSelection()
              } label: {
                AgentRow(agent: agent, selected: controller.selectedID == agent.id)
              }
              .buttonStyle(.plain)
              .background(
                controller.selectedID == agent.id ? Color.accentColor : .clear,
                in: RoundedRectangle(cornerRadius: 8)
              )
              .id(agent.id)
              .contextMenu {
                Button("Copy session ID") { AgentNavigation.copyID(agent, model: model) }
                if agent.workspace != nil {
                  Button("Reveal project in Finder") { AgentNavigation.revealProject(agent) }
                }
              }
            }
          }.padding(12)
        }
        .onChange(of: controller.selectedID) { id in if let id { proxy.scrollTo(id) } }
      }
      Spacer(minLength: 0)
      Divider()
      if let message = model.navigationMessage {
        Label(message, systemImage: "info.circle")
          .font(.callout).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 16).padding(.vertical, 10)
          .accessibilityLabel(message)
      }
      HStack(spacing: 18) {
        Label(
          controller.rows.first(where: { $0.id == controller.selectedID })?.navigationActionLabel
            ?? "Open selection", systemImage: "return")
        Label("Navigate", systemImage: "arrow.up.arrow.down")
        Spacer()
        Button(action: controller.showDashboard) {
          Label("Statistics", systemImage: "chart.bar.xaxis")
        }
        .buttonStyle(.borderless)
        .help("Open the statistics dashboard")
        Text("esc  Close")
      }.font(.caption).foregroundStyle(.secondary).padding(16)
    }
    .frame(width: 760, height: 580)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    .onAppear { searchFocused = true }
    .onReceive(NotificationCenter.default.publisher(for: .beaconFocusSearch)) { _ in
      searchFocused = true
    }
  }

  private func group(_ agent: AgentRecord) -> String {
    if agent.freshness != .current || agent.state == .unknown { return "Uncertain" }
    switch agent.state {
    case .needsYou: return "Needs you"
    case .working: return "Working"
    case .idle: return "Idle"
    case .failed: return "Failed"
    case .finished, .stopped: return "Recently finished"
    case .unknown: return "Uncertain"
    }
  }
}

private struct ContentUnavailableText: View {
  let title: String
  let detail: String
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.headline)
      Text(detail).font(.subheadline).foregroundStyle(.secondary)
    }.padding(20)
  }
}
