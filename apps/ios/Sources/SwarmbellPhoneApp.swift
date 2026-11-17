import SwiftUI

@main
struct SwarmbellPhoneApp: App {
  @StateObject private var model = SwarmbellPhoneModel()
  @State private var selectedTab = 0
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      TabView(selection: $selectedTab) {
        AgentsView(model: model)
          .tabItem { Label("Agents", systemImage: "bell") }
          .tag(0)
        PhoneStatisticsView(model: model)
          .tabItem { Label("Statistics", systemImage: "chart.bar.xaxis") }
          .tag(1)
        NavigationStack { PairingView(model: model) }
          .tabItem { Label("Connection", systemImage: "desktopcomputer") }
          .tag(2)
      }
      .tint(.blue)
      .task { model.start() }
      .onOpenURL { url in
        guard url.scheme == "swarmbell" else { return }
        switch url.host {
        case "statistics": selectedTab = 1
        case "connection": selectedTab = 2
        case "agents": selectedTab = 0
        default: break
        }
      }
      .onChange(of: model.receivedAt) { old, new in
        if old == nil && new != nil && selectedTab == 2 { selectedTab = 0 }
      }
      .onChange(of: phase) { _, next in
        if next == .active { model.start() } else if next == .background { model.stop() }
      }
    }
  }
}
