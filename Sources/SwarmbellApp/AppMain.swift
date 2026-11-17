import AppKit
import Combine
import SwiftUI

@main
enum SwarmbellApplication {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    let delegate = SwarmbellAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    withExtendedLifetime(delegate) {}
  }
}

@MainActor
final class SwarmbellAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  NSPopoverDelegate
{
  private let model = AppModel()
  private let shortcut = GlobalShortcut()
  private var switcher: QuickSwitcherController!
  private var statusItem: NSStatusItem!
  private let popover = NSPopover()
  private var dashboardWindow: NSWindow?
  private var settingsWindow: NSWindow?
  private var previousApplication: NSRunningApplication?
  private var statusSubscription: AnyCancellable?
  private var popoverGeometrySubscriptions: [AnyCancellable] = []
  private var constrainingPopover = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let identifier = Bundle.main.bundleIdentifier,
      let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
    {
      existing.activate(options: [])
      NSApp.terminate(nil)
      return
    }
    installMainMenu()
    switcher = QuickSwitcherController(model: model)
    switcher.openDashboard = { [weak self] in self?.showDashboard() }
    model.closeDashboardRequested = { [weak self] in self?.dashboardWindow?.performClose(nil) }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // Preserve the saved menu-bar position across the Swarmbell rebrand.
    statusItem.autosaveName = "AgentBeaconStatusItem"
    if let button = statusItem.button {
      button.image = NSImage(
        systemSymbolName: "bell",
        accessibilityDescription: "Swarmbell")
      button.image?.isTemplate = true
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(togglePopover)
    }
    popover.behavior = .transient
    popover.delegate = self
    popover.contentViewController = NSHostingController(
      rootView: MenuBarContent(
        model: model,
        openSwitcher: { [weak self] in self?.showSwitcherFromPopover() },
        openDashboard: { [weak self] in self?.showDashboard() },
        openSettings: { [weak self] in self?.showSettings() },
        close: { [weak self] in self?.popover.performClose(nil) }))
    statusSubscription = model.$snapshot.sink { [weak self] _ in
      Task { @MainActor in self?.updateStatusItem() }
    }
    shortcut.onTrigger = { [weak self] in
      self?.popover.performClose(nil)
      self?.switcher.toggle()
    }
    model.shortcutDidChange = { [weak self] in self?.registerShortcut() }
    registerShortcut()
    updateStatusItem()
    model.start()
    if CommandLine.arguments.contains("--show-dashboard") {
      showDashboard()
    } else if CommandLine.arguments.contains("--show-switcher") {
      switcher.show()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag && !popover.isShown { switcher?.show() }
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.stop()
    shortcut.unregister()
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
  }

  @objc private func togglePopover() {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      previousApplication = NSWorkspace.shared.frontmostApplication
      // Give AppKit the real width before it chooses which side of the anchor
      // can contain the popover. SwiftUI's first hosting size can be much smaller.
      if let view = popover.contentViewController?.view {
        view.setFrameSize(NSSize(width: 420, height: max(100, view.frame.height)))
        view.layoutSubtreeIfNeeded()
        let fittingHeight = view.fittingSize.height
        let maximumHeight = max(100, (statusItemScreen?.visibleFrame.height ?? 800) - 16)
        popover.contentSize = NSSize(
          width: 420, height: min(maximumHeight, max(100, fittingHeight)))
      }
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      // Focus the popover itself. Activating the entire app also raises its
      // existing Statistics window, which a menu-bar click must not do.
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  private var statusItemScreen: NSScreen? {
    guard let button = statusItem?.button, let window = button.window else { return nil }
    if let screen = window.screen { return screen }
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    return NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
  }

  func popoverDidShow(_ notification: Notification) {
    popoverGeometrySubscriptions.removeAll()
    guard let window = popover.contentViewController?.view.window else { return }
    // Intrinsic content changes (new rows or expanded groups) may happen after
    // AppKit's initial placement. Contain the actual window after those changes.
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      NotificationCenter.default.publisher(for: name, object: window)
        .sink { [weak self] _ in
          Task { @MainActor in self?.containPopover() }
        }
        .store(in: &popoverGeometrySubscriptions)
    }
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        Task { @MainActor in self?.containPopover() }
      }
      .store(in: &popoverGeometrySubscriptions)
    containPopover()
  }

  func popoverDidClose(_ notification: Notification) {
    popoverGeometrySubscriptions.removeAll()
  }

  private func containPopover() {
    guard !constrainingPopover, popover.isShown,
      let window = popover.contentViewController?.view.window,
      let screen = statusItemScreen
    else { return }
    let current = window.frame
    let contained = PopoverPlacement.containedFrame(current, in: screen.visibleFrame)
    guard
      abs(current.minX - contained.minX) > 0.5
        || abs(current.minY - contained.minY) > 0.5
        || abs(current.width - contained.width) > 0.5
        || abs(current.height - contained.height) > 0.5
    else { return }
    constrainingPopover = true
    defer { constrainingPopover = false }
    // This only moves/resizes the popover window. It neither activates the app
    // nor raises Statistics, Settings, or another user's application.
    window.setFrame(contained, display: true, animate: false)
  }

  private func installMainMenu() {
    let mainMenu = NSMenu()
    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu(title: "Swarmbell")
    applicationItem.submenu = applicationMenu
    mainMenu.addItem(applicationItem)

    let about = applicationMenu.addItem(
      withTitle: "About Swarmbell",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    about.target = NSApp
    applicationMenu.addItem(.separator())
    let agents = applicationMenu.addItem(
      withTitle: "Show Agent Menu", action: #selector(showAgentMenu(_:)), keyEquivalent: "m")
    agents.keyEquivalentModifierMask = [.command, .shift]
    agents.target = self
    let settings = applicationMenu.addItem(
      withTitle: "Settings…",
      action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",")
    settings.keyEquivalentModifierMask = .command
    settings.target = self
    let statistics = applicationMenu.addItem(
      withTitle: "Statistics…",
      action: #selector(openStatisticsFromMenu(_:)), keyEquivalent: "")
    statistics.target = self
    applicationMenu.addItem(.separator())
    let quit = applicationMenu.addItem(
      withTitle: "Quit Swarmbell",
      action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit.keyEquivalentModifierMask = .command
    quit.target = NSApp

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)
    let close = fileMenu.addItem(
      withTitle: "Close Window",
      action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    close.keyEquivalentModifierMask = .command
    close.target = nil

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowItem.submenu = windowMenu
    mainMenu.addItem(windowItem)
    let minimize = windowMenu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    minimize.keyEquivalentModifierMask = .command
    minimize.target = nil
    let zoom = windowMenu.addItem(
      withTitle: "Zoom",
      action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    zoom.target = nil
    NSApp.windowsMenu = windowMenu
    NSApp.mainMenu = mainMenu
  }

  @objc private func openSettingsFromMenu(_ sender: Any?) { showSettings() }
  @objc private func showAgentMenu(_ sender: Any?) {
    switcher?.hide(restoreFocus: false)
    if !popover.isShown { togglePopover() }
  }
  @objc private func openStatisticsFromMenu(_ sender: Any?) { showDashboard() }

  private func updateStatusItem() {
    guard let button = statusItem?.button else { return }
    guard let counts = model.snapshot?.counts else {
      button.title = " …"
      button.toolTip = "Swarmbell — checking your agents"
      button.setAccessibilityLabel("Swarmbell, checking your agents")
      return
    }
    let active = " \(counts.active)"
    let title = NSMutableAttributedString(
      string: active,
      attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.labelColor,
      ])
    title.append(
      NSAttributedString(
        string: "  \(counts.needsYou)",
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
          .foregroundColor: counts.needsYou > 0
            ? NSColor.systemOrange : NSColor.secondaryLabelColor,
        ]))
    button.attributedTitle = title
    let text =
      "Swarmbell: \(counts.active) confirmed active, \(counts.needsYou) need you"
      + (counts.incomplete ? ". Partial source coverage; actual activity may be higher." : ".")
    button.toolTip = text
    button.setAccessibilityLabel(text)
  }

  private func registerShortcut() { model.shortcutMessage = shortcut.register(model.shortcut) }

  private func showSwitcherFromPopover() {
    popover.performClose(nil)
    switcher.show(previousApplication: previousApplication)
  }

  private func showDashboard() {
    switcher?.hide(restoreFocus: false)
    popover.performClose(nil)
    if dashboardWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1080, height: 820),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "Swarmbell — Statistics"
      window.contentMinSize = NSSize(width: 900, height: 650)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.contentView = NSHostingView(rootView: DashboardView(model: model))
      window.center()
      dashboardWindow = window
    }
    model.dashboardVisible = true
    NSApp.activate(ignoringOtherApps: true)
    dashboardWindow?.makeKeyAndOrderFront(nil)
    Task { await model.refreshAnalytics() }
  }

  private func showSettings() {
    popover.performClose(nil)
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "Swarmbell Settings"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: SwarmbellSettingsView(model: model))
      window.center()
      settingsWindow = window
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    if let window = notification.object as? NSWindow, window === dashboardWindow {
      model.dashboardVisible = false
    }
  }
}
