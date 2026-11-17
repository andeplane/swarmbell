import AgentBeaconCore
import Foundation

@main
struct AgentBeaconCLI {
  static func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
      }
      return args[index + 1]
    }
    // This branch intentionally precedes all collector, history and hook setup.
    // Invalid combinations fail here rather than falling through to collection.
    if args.contains("--read-current") {
      let directory: URL
      if args == ["--read-current"] {
        directory = SnapshotCacheReader.defaultDirectory
      } else if args.count == 3, args[0] == "--read-current", args[1] == "--cache-directory",
        !args[2].isEmpty, !args[2].hasPrefix("--")
      {
        directory = URL(fileURLWithPath: args[2], isDirectory: true)
      } else if args.count == 3, args[0] == "--cache-directory", args[2] == "--read-current",
        !args[1].isEmpty, !args[1].hasPrefix("--")
      {
        directory = URL(fileURLWithPath: args[1], isDirectory: true)
      } else {
        fail(
          "Use --read-current alone or with --cache-directory PATH; collection and setup flags cannot be combined with it"
        )
      }
      do {
        let result = try SnapshotCacheReader.read(directory: directory)
        print(String(decoding: try result.jsonData(), as: UTF8.self))
      } catch {
        fail("Current snapshot unavailable: \(error.localizedDescription)")
      }
      return
    }
    let eventDirectory =
      value("--cursor-events").map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? CursorSpool.defaultDirectory

    if args.contains("--cursor-hook") {
      // Observer failures must not interfere with Cursor's work. Never print incoming text.
      let input = FileHandle.standardInput.readData(ofLength: 1_048_577)
      let event = try? CursorEvent.fromHook(input)
      if let event { try? CursorSpool.write(event, to: eventDirectory) }
      let eventName = event?.name ?? value("--hook-event")
      print(eventName == "beforeSubmitPrompt" ? "{\"continue\":true}" : "{}")
      return
    }
    if args.contains("--cursor-config") {
      do {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let data = try CursorSpool.configuration(executable: executable, directory: eventDirectory)
        print(String(decoding: data, as: UTF8.self))
      } catch { fail(error.localizedDescription) }
      return
    }
    if args.contains("--install-cursor-observer") || args.contains("--remove-cursor-observer") {
      guard
        !(args.contains("--install-cursor-observer") && args.contains("--remove-cursor-observer"))
      else {
        fail("Choose either install or remove for the Cursor observer")
      }
      do {
        let result: CursorInstallationResult
        if args.contains("--install-cursor-observer") {
          result = try CursorHookInstaller.install(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            eventDirectory: eventDirectory)
        } else {
          result = try CursorHookInstaller.uninstall(eventDirectory: eventDirectory)
        }
        let data = try JSONSerialization.data(
          withJSONObject: [
            "changed": result.changed,
            "installedHookCount": result.installedHookCount,
            "configurationPath": result.configurationURL.path,
            "backupPath": result.backupURL?.path ?? "",
          ], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
      } catch { fail("Cursor observer setup failed: \(error.localizedDescription)") }
      return
    }
    if args.contains("--help") {
      print(
        """
        Agent Beacon — local macOS monitoring and history
        Usage: agent-beacon [--watch] [--samples N] [--include-subagents]
                            [--claude PATH] [--codex PATH] [--codex-socket PATH]
                            [--cursor-events DIRECTORY] [--history PATH | --no-history]
                            [--no-codex-desktop]
               agent-beacon --stats [--days 7] [--timezone Europe/Oslo] [--harness claudeCode]
               agent-beacon --read-current [--cache-directory PATH]
               agent-beacon --cursor-config    Print a config fragment; installs nothing
               agent-beacon --cursor-hook      Read one Cursor hook payload from stdin
               agent-beacon --install-cursor-observer  Merge lifecycle hooks; keeps a backup
               agent-beacon --remove-cursor-observer   Remove only Agent Beacon's hooks

        Default: one JSON snapshot. --watch: one JSON line every five seconds.
        Each refresh is timed and saved locally. --stats reads the saved history.
        --read-current reads only the running app's last published snapshot.
        It never polls providers, starts the app, or opens history. Stale data is labeled stale.
        Active = working + needsYou. Incomplete counts must be displayed as partial.
        Thread navigation is described as data; no sessions are opened or resumed.
        """)
      return
    }
    let allowed = Set([
      "--watch", "--samples", "--include-subagents", "--claude", "--codex", "--codex-socket",
      "--cursor-events", "--history", "--no-history", "--stats", "--days", "--timezone",
      "--harness",
      "--no-codex-desktop",
    ])
    let valued = Set([
      "--samples", "--claude", "--codex", "--codex-socket", "--cursor-events", "--history",
      "--days", "--timezone", "--harness",
    ])
    var index = 0
    while index < args.count {
      let arg = args[index]
      guard allowed.contains(arg) else { fail("Unknown argument: \(arg)") }
      if valued.contains(arg) {
        guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
          fail("Missing value for \(arg)")
        }
        index += 1
      }
      index += 1
    }
    let samples: Int?
    if let raw = value("--samples") {
      guard let number = Int(raw), number > 0 else { fail("--samples must be a positive integer") }
      samples = number
    } else {
      samples = nil
    }
    if args.contains("--no-history"), value("--history") != nil || args.contains("--stats") {
      fail("--no-history cannot be combined with --history or --stats")
    }
    let history: HistoryStore?
    if args.contains("--no-history") {
      history = nil
    } else {
      do {
        history = try HistoryStore(
          url: value("--history").map { URL(fileURLWithPath: $0) } ?? HistoryStore.defaultURL)
      } catch {
        fail("Could not open local measurement history: \(error.localizedDescription)")
      }
    }
    if args.contains("--stats"), let history {
      let days: Int
      if let raw = value("--days") {
        guard let parsed = Int(raw) else { fail("--days must be a whole number") }
        days = parsed
      } else {
        days = 7
      }
      guard days > 0, days <= 3660 else { fail("--days must be between 1 and 3660") }
      guard let zone = TimeZone(identifier: value("--timezone") ?? "Europe/Oslo") else {
        fail("Invalid timezone identifier")
      }
      let harness: Harness?
      if let name = value("--harness") {
        guard let parsed = Harness(rawValue: name) else {
          fail("Unknown harness; use codex, claudeCode, or cursor")
        }
        harness = parsed
      } else {
        harness = nil
      }
      let to = Date()
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = zone
      guard let from = calendar.date(byAdding: .day, value: -days, to: to) else {
        fail("Invalid date range")
      }
      do {
        let report = try await history.report(from: from, to: to, timeZone: zone, harness: harness)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
      } catch { fail("Could not query local history: \(error.localizedDescription)") }
      return
    }
    let sharedCodex = CodexProvider.local(
      executableOverride: value("--codex"), socketOverride: value("--codex-socket"))
    let codex: any AgentProvider =
      args.contains("--no-codex-desktop") || value("--codex-socket") != nil
        || value("--codex") != nil
      ? sharedCodex : CodexDesktopProvider(fallback: sharedCodex)
    let monitor = AgentMonitor(
      providers: [
        ClaudeProvider(executable: Executables.find("claude", override: value("--claude"))),
        codex,
        CursorProvider(directory: eventDirectory),
      ], countSubagents: args.contains("--include-subagents"), history: history)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if !args.contains("--watch") { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
    var count = 0
    repeat {
      let start = ContinuousClock.now
      let snapshot = await monitor.refresh()
      do { print(String(decoding: try encoder.encode(snapshot), as: UTF8.self)) } catch {
        fail("Could not encode snapshot")
      }
      count += 1
      guard args.contains("--watch"), samples.map({ count < $0 }) ?? true else { break }
      // Start-to-start cadence, without overlapping polls or busy retry loops.
      do { try await ContinuousClock().sleep(until: start.advanced(by: .seconds(5))) } catch {
        break
      }
    } while !Task.isCancelled
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
  }
}
