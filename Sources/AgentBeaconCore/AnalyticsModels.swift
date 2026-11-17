import Foundation

public struct ProviderRefreshTiming: Codable, Sendable {
  public var harness: Harness
  public var durationMilliseconds: Double
  public init(harness: Harness, durationMilliseconds: Double) {
    self.harness = harness
    self.durationMilliseconds = durationMilliseconds
  }
}

public struct RefreshTiming: Codable, Sendable {
  public var startedAt: Date
  public var durationMilliseconds: Double
  public var providers: [ProviderRefreshTiming]
  public init(
    startedAt: Date, durationMilliseconds: Double, providers: [ProviderRefreshTiming] = []
  ) {
    self.startedAt = startedAt
    self.durationMilliseconds = durationMilliseconds
    self.providers = providers
  }
}

public struct LatencySummary: Codable, Sendable {
  public var sampleCount: Int
  public var meanMilliseconds: Double
  public var p50Milliseconds: Double
  public var p95Milliseconds: Double
  public var maxMilliseconds: Double
}

public struct ProviderLatencySummary: Codable, Sendable, Identifiable {
  public var id: Harness { harness }
  public var harness: Harness
  public var latency: LatencySummary
}

public struct AnalyticsSummary: Codable, Sendable {
  public var observedSeconds: Double
  public var requestedSeconds: Double
  public var workingAgentSeconds: Double
  public var waitingAgentSeconds: Double
  public var meanActiveAgents: Double
  public var sourceAvailabilityFraction: Double
  public var completeCoverageFraction: Double
  public var peakActiveAgents: Int
  public var attentionEpisodes: Int
  public var completedEpisodes: Int
  public var meanObservedWaitSeconds: Double?
  public var p95ObservedWaitSeconds: Double?
}

public struct AnalyticsPoint: Codable, Sendable, Identifiable {
  public var id: Date { timestamp }
  public var timestamp: Date
  /// Nil means no observed time in this chart bucket, not zero agents.
  public var active: Double?
  public var working: Double?
  public var needsYou: Double?
  public var peakActive: Int
  public var observedSeconds: Double
  public var sourceAvailabilityFraction: Double
  public var sampleCount: Int
  /// A new segment follows every unobserved bucket; chart lines must not join segments.
  public var segment: Int
}

public struct AnalyticsBucket: Codable, Sendable, Identifiable {
  public var id: Int { index }
  public var index: Int
  public var label: String
  public var workingAgentSeconds: Double
  public var waitingAgentSeconds: Double
  public var observedSeconds: Double
  public var meanActiveAgents: Double
  public var peakActiveAgents: Int
  public var attentionEpisodes: Int
}

public struct AnalyticsHeatmapCell: Codable, Sendable, Identifiable {
  public var id: String { "\(weekday)-\(hour)" }
  public var weekday: Int
  public var hour: Int
  public var observedSeconds: Double
  public var workingAgentSeconds: Double
  public var waitingAgentSeconds: Double
  public var meanActiveAgents: Double
}

public struct HarnessAnalytics: Codable, Sendable, Identifiable {
  public var id: Harness { harness }
  public var harness: Harness
  public var workingAgentSeconds: Double
  public var waitingAgentSeconds: Double
  public var availableSeconds: Double
  public var healthySeconds: Double
  public var meanActiveAgents: Double
  public var peakActiveAgents: Int
  public var attentionEpisodes: Int
}

public struct AttentionReasonAnalytics: Codable, Sendable, Identifiable {
  public var id: String { reason }
  public var reason: String
  public var episodes: Int
  public var waitingAgentSeconds: Double
}

public struct AnalyticsReport: Codable, Sendable {
  public var from: Date
  public var to: Date
  public var generatedAt: Date
  public var timeZoneID: String
  public var sampleCount: Int
  public var summary: AnalyticsSummary
  public var timeSeries: [AnalyticsPoint]
  public var hourly: [AnalyticsBucket]
  public var weekdays: [AnalyticsBucket]
  public var weekdayHours: [AnalyticsHeatmapCell]
  public var harnesses: [HarnessAnalytics]
  public var attentionReasons: [AttentionReasonAnalytics]
  public var refreshLatency: LatencySummary
  public var providerLatencies: [ProviderLatencySummary]
  public var insights: [String]
}
