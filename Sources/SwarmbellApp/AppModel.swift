import AppKit
import Combine
import Foundation
import SwarmbellCore

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var snapshot: MonitorSnapshot?
  @Published private(set) var isRefreshing = false
  @Published var analyticsReport: AnalyticsReport?
  @Published var dashboardRange: DashboardRange = .week
  @Published var dashboardHarness: Harness?
  @Published var dashboardCustomFrom = Date().addingTimeInterval(-7 * 86_400)
  @Published var dashboardCustomTo = Date()
  @Published var analyticsError: String?
  @Published var isLoadingAnalytics = false
  @Published var shortcutMessage: String?
  @Published var navigationMessage: String?
  @Published var dashboardVisible = false
  @Published private(set) var isUpdatingCursorObserver = false
  @Published private(set) var cursorSetupMessage: String?
  @Published private(set) var cursorSetupError: String?
  @Published private(set) var cursorSetupBackupURL: URL?
  @Published var shortcut: ShortcutChoice {
    didSet {
      UserDefaults.standard.set(shortcut.rawValue, forKey: "globalShortcut")
      shortcutDidChange?()
    }
  }

  let historyStore: HistoryStore?
  let companion = CompanionSharing()
  var shortcutDidChange: (() -> Void)?
  var closeDashboardRequested: (() -> Void)?
  private let monitor: AgentMonitor
  private let snapshotCache = SnapshotCachePublisher()
  private(set) var snapshotCacheError: String?
  private var pollingTask: Task<Void, Never>?
  private var analyticsRequest = 0
  private var lastAnalyticsRefresh = Date.distantPast

  init() {
    let store: HistoryStore?
    var historyIssue: String?
    do {
      store = try HistoryStore()
    } catch {
      store = nil
      historyIssue = "History could not be opened: \(error.localizedDescription)"
    }
    historyStore = store
    shortcut =
      ShortcutChoice(rawValue: UserDefaults.standard.string(forKey: "globalShortcut") ?? "")
      ?? .controlOptionSpace
    monitor = AgentMonitor(
      providers: [
        ClaudeProvider(), CodexDesktopProvider(fallback: CodexProvider.local()), CursorProvider(),
      ], history: store)
    analyticsError = historyIssue
  }

  func start() {
    guard pollingTask == nil else { return }
    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        let start = ContinuousClock.now
        await self?.refresh()
        do { try await ContinuousClock().sleep(until: start.advanced(by: .seconds(5))) } catch {
          return
        }
      }
    }
  }

  func stop() {
    pollingTask?.cancel()
    pollingTask = nil
    companion.stop()
    Task { await snapshotCache.stop() }
  }

  func installCursorObserver() async {
    guard !isUpdatingCursorObserver else { return }
    guard let executable = Bundle.main.executableURL else {
      cursorSetupError = "The app's bundled observer helper could not be located."
      return
    }
    let helper = executable.deletingLastPathComponent().appendingPathComponent("swarmbell")
    isUpdatingCursorObserver = true
    cursorSetupMessage = nil
    cursorSetupError = nil
    cursorSetupBackupURL = nil
    defer { isUpdatingCursorObserver = false }
    do {
      let result = try await Task.detached(priority: .utility) {
        try CursorHookInstaller.install(executableURL: helper)
      }.value
      cursorSetupBackupURL = result.backupURL
      cursorSetupMessage =
        result.changed
        ? "Installed \(result.installedHookCount) passive Cursor observers. Existing hooks were preserved."
        : "The Cursor observer is already up to date."
      await refresh()
    } catch {
      cursorSetupError = "The Cursor observer could not be installed: \(error.localizedDescription)"
    }
  }

  func removeCursorObserver() async {
    guard !isUpdatingCursorObserver else { return }
    isUpdatingCursorObserver = true
    cursorSetupMessage = nil
    cursorSetupError = nil
    cursorSetupBackupURL = nil
    defer { isUpdatingCursorObserver = false }
    do {
      let result = try await Task.detached(priority: .utility) {
        try CursorHookInstaller.uninstall()
      }.value
      cursorSetupBackupURL = result.backupURL
      cursorSetupMessage =
        result.changed
        ? "Removed Swarmbell's Cursor observers. Other hooks were preserved."
        : "No Swarmbell Cursor observers were installed."
      await refresh()
    } catch {
      cursorSetupError = "The Cursor observer could not be removed: \(error.localizedDescription)"
    }
  }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    snapshot = await monitor.refresh()
    guard !Task.isCancelled else { return }
    if let snapshot { snapshotCacheError = await snapshotCache.publish(snapshot) }
    if let snapshot { await companion.publish(snapshot, history: historyStore) }
    if dashboardVisible && Date().timeIntervalSince(lastAnalyticsRefresh) >= 30 {
      await refreshAnalytics()
    }
  }

  func refreshAnalytics() async {
    guard let historyStore else { return }
    analyticsRequest += 1
    let request = analyticsRequest
    isLoadingAnalytics = true
    let to = dashboardRange == .custom ? dashboardCustomTo : Date()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Oslo") ?? .current
    let from =
      dashboardRange == .custom
      ? dashboardCustomFrom
      : calendar.date(byAdding: .day, value: -dashboardRange.days, to: to) ?? to
    guard from < to else {
      analyticsError = "Choose an end date after the start date."
      isLoadingAnalytics = false
      return
    }
    do {
      let report = try await historyStore.report(
        from: from, to: to,
        timeZone: calendar.timeZone, harness: dashboardHarness)
      guard request == analyticsRequest else { return }
      analyticsReport = report
      analyticsError = nil
      lastAnalyticsRefresh = Date()
    } catch {
      guard request == analyticsRequest else { return }
      analyticsError = "Statistics could not be loaded: \(error.localizedDescription)"
    }
    if request == analyticsRequest { isLoadingAnalytics = false }
  }

  var agents: [AgentRecord] { snapshot?.agents.filter { !$0.isSubagent } ?? [] }
  var attention: [AgentRecord] {
    agents.filter { $0.state == .needsYou && $0.freshness == .current }
  }
  var working: [AgentRecord] { agents.filter { $0.state == .working && $0.freshness == .current } }
  var other: [AgentRecord] { agents.filter { !($0.state.isActive && $0.freshness == .current) } }
  var sourceIssues: [ProviderStatus] { snapshot?.providers.filter { $0.health != .healthy } ?? [] }
  var countsDescription: String {
    guard let counts = snapshot?.counts else { return "Checking your agents…" }
    return "\(counts.active) active · \(counts.needsYou) need you"
  }
}

extension Harness {
  var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    case .cursor: "Cursor"
    }
  }
  var symbol: String {
    switch self {
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .claudeCode: "asterisk"
    case .cursor: "cursorarrow"
    }
  }
  var applicationBundleID: String {
    switch self {
    case .codex: "com.openai.codex"
    case .claudeCode: "com.anthropic.claudefordesktop"
    case .cursor: "com.todesktop.230313mzl4w4u92"
    }
  }
}

extension AgentRecord {
  var tokenUsageDescription: String {
    guard let usage, let total = usage.totalTokens, total >= 0 else { return "— tokens" }
    let number = Double(total).formatted(
      .number.notation(.compactName).precision(.fractionLength(0...1)))
    let scope =
      usage.scope == .contextWindow ? " context" : usage.scope == .lastTurn ? " last turn" : ""
    return "\(number)\(scope) tokens"
  }

  var tokenUsageHelp: String {
    guard let usage, let total = usage.totalTokens, total >= 0 else {
      return "Token usage is unavailable from this session's source."
    }
    let scope =
      usage.scope == .session
      ? "Session total" : usage.scope == .lastTurn ? "Last turn" : "Context window"
    var text = "\(scope): \(total.formatted()) source-reported tokens."
    if let input = usage.inputTokens { text += " Input: \(input.formatted())." }
    if let output = usage.outputTokens { text += " Output: \(output.formatted())." }
    if let cached = usage.cachedInputTokens {
      text += " Cached input: \(cached.formatted()) (included in input)."
    }
    text += " This is not a dollar charge; actual billed cost is unavailable."
    return text
  }

  var navigationActionLabel: String {
    navigation.kind == .openDesktopThread ? "Open thread" : "Copy session ID"
  }
  var projectName: String {
    guard let workspace else { return harness.displayName }
    return URL(fileURLWithPath: workspace).lastPathComponent
  }
  var stateDescription: String {
    if freshness != .current {
      return freshness == .stale ? "Status is stale" : "Session not found"
    }
    switch state {
    case .working: return "Working"
    case .needsYou: return reason?.capitalized ?? "Needs you"
    case .idle: return "Idle"
    case .finished: return "Finished"
    case .failed: return "Failed"
    case .stopped: return "Stopped"
    case .unknown: return "Status unknown"
    }
  }
}
