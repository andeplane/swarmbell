import SwiftUI

struct AgentsView: View {
  @ObservedObject var model: BeaconPhoneModel
  @State private var query = ""
  var body: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: 5)) { context in
        Group {
          if let snapshot = model.snapshot {
            List {
              Section {
                ConnectionSummary(model: model, now: context.date)
                if model.isCurrent(at: context.date) {
                  LabeledContent(
                    "Active",
                    value: "\(snapshot.counts.active)")
                  LabeledContent("Needs you", value: "\(snapshot.counts.needsYou)")
                    .foregroundStyle(snapshot.counts.needsYou > 0 ? .orange : .primary)
                } else {
                  Label("Live counts unavailable", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                }
              }
              if filtered(snapshot).isEmpty {
                Section {
                  if query.isEmpty {
                    ContentUnavailableView(
                      "No sessions observed", systemImage: "antenna.radiowaves.left.and.right",
                      description: Text(
                        "Your Mac has not reported any sessions. Source coverage is listed below."))
                  } else {
                    ContentUnavailableView.search(text: query)
                  }
                }
              } else {
                agentSection(
                  "Needs you",
                  rows: filtered(snapshot).filter {
                    $0.state == .needsYou && $0.freshness == .current
                  })
                agentSection(
                  "Working",
                  rows: filtered(snapshot).filter {
                    $0.state == .working && $0.freshness == .current
                  })
                agentSection(
                  "Other sessions",
                  rows: filtered(snapshot).filter { !$0.state.isActive || $0.freshness != .current }
                )
              }
              Section("Sources") {
                ForEach(snapshot.providers, id: \.harness) { source in
                  NavigationLink {
                    Form {
                      LabeledContent("Health", value: source.health.rawValue.capitalized)
                      LabeledContent(
                        "Attention", value: source.observesAttention ? "Observed" : "Unavailable")
                      Text(source.scope)
                      Text(source.message)
                      LabeledContent("Last checked") { Text(source.checkedAt, style: .relative) }
                    }.navigationTitle(source.harness.phoneName)
                  } label: {
                    Label(
                      source.harness.phoneName,
                      systemImage: source.health == .healthy
                        ? "checkmark.circle" : "exclamationmark.triangle")
                  }
                }
              }
            }
            .searchable(text: $query, prompt: "Search agents or projects")
          } else {
            ContentUnavailableView {
              Label(
                model.isPaired ? "Waiting for your Mac" : "Your agents, together",
                systemImage: "antenna.radiowaves.left.and.right")
            } description: {
              Text(
                model.isPaired
                  ? "Keep Agent Beacon running on your paired Mac. Connect this iPhone to the same local network."
                  : "Pair with Agent Beacon on your Mac to see which agents are working and which need you."
              )
            } actions: {
              NavigationLink("\(model.isPaired ? "Connection details" : "Pair your Mac")") {
                PairingView(model: model)
              }
              .buttonStyle(.borderedProminent)
            }
          }
        }
      }
      .navigationTitle("Agent Beacon")
    }
  }

  private func filtered(_ snapshot: MonitorSnapshot) -> [AgentRecord] {
    snapshot.agents.filter { agent in
      query.isEmpty
        || [agent.title, agent.workspace ?? "", agent.harness.phoneName]
          .contains { $0.localizedCaseInsensitiveContains(query) }
    }
  }
  @ViewBuilder private func agentSection(_ title: String, rows: [AgentRecord]) -> some View {
    if !rows.isEmpty {
      Section(title) {
        ForEach(rows) { agent in
          NavigationLink {
            AgentDetailView(agent: agent, model: model)
          } label: {
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: agent.harness.phoneSymbol)
                .font(.title3).foregroundStyle(agent.state == .needsYou ? .orange : .secondary)
                .frame(width: 26).accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 5) {
                Text(agent.title).font(.headline).lineLimit(3)
                Text("\(agent.harness.phoneName) · \(agent.phoneProject)")
                  .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Text(agent.phoneState).font(.caption).foregroundStyle(.secondary)
              }
            }.padding(.vertical, 4)
          }
        }
      }
    }
  }
}

struct ConnectionSummary: View {
  @ObservedObject var model: BeaconPhoneModel
  var now: Date
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(
        model.isCurrent(at: now) ? "Live from your Mac" : "Last received status",
        systemImage: model.isCurrent(at: now) ? "dot.radiowaves.left.and.right" : "clock"
      )
      .font(.subheadline.weight(.medium))
      if let date = model.snapshot?.generatedAt {
        Text("Updated \(date.formatted(.relative(presentation: .named)))")
          .font(.caption).foregroundStyle(.secondary)
      }
      if model.snapshot?.counts.incomplete == true {
        Label("Partial source coverage", systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !model.isCurrent(at: now) {
        Text("These sessions may have changed. Live counts return when your Mac reconnects.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }.padding(.vertical, 4)
  }
}

private struct AgentDetailView: View {
  let agent: AgentRecord
  @ObservedObject var model: BeaconPhoneModel
  var body: some View {
    Form {
      Section {
        Text(agent.title).font(.headline)
        LabeledContent("Harness", value: agent.harness.phoneName)
        LabeledContent("Status", value: agent.phoneState)
        if let reason = agent.reason { Text(reason) }
        LabeledContent("Last observed") { Text(agent.lastSeen, style: .relative) }
      }
      Section("Project") {
        if let path = agent.workspace { Text(path).textSelection(.enabled) }
        LabeledContent("Host", value: agent.host)
      }
      Section("Conversation") {
        Text(agent.sessionID).font(.footnote.monospaced()).textSelection(.enabled)
        ShareLink("Share session ID", item: agent.sessionID)
        Text(
          "Continue the conversation in its original app on your Mac. Agent Beacon on iPhone shows status and statistics."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
      Section {
        TimelineView(.periodic(from: .now, by: 5)) { context in
          ConnectionSummary(model: model, now: context.date)
        }
      }
    }
    .navigationTitle("Session").navigationBarTitleDisplayMode(.inline)
  }
}

extension Harness {
  var phoneName: String {
    switch self {
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    case .cursor: "Cursor"
    }
  }
  var phoneSymbol: String {
    switch self {
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .claudeCode: "asterisk"
    case .cursor: "cursorarrow"
    }
  }
}
extension AgentRecord {
  var phoneProject: String {
    workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? harness.phoneName
  }
  var phoneState: String {
    if freshness != .current {
      return freshness == .stale ? "Stale observation" : "Session not found"
    }
    switch state {
    case .working: return "Working"
    case .needsYou: return reason?.capitalized ?? "Needs you"
    case .idle: return "Idle"
    case .finished: return "Finished"
    case .failed: return "Failed"
    case .stopped: return "Stopped"
    case .unknown: return "Unknown"
    }
  }
}
