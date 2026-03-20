import Foundation

// MARK: - Top-level response

/// Full response from `GET /server/stats?range=N`.
struct ServerStats: Codable, Sendable {
    let memory: StatsMemory
    let activeSessions: [StatsActiveSession]
    let daily: [StatsDailyEntry]
    let modelBreakdown: [StatsModelBreakdown]
    let workspaceBreakdown: [StatsWorkspaceBreakdown]
    let totals: StatsTotals
}

// MARK: - Memory

/// Process memory snapshot from `process.memoryUsage()`, values in MB.
struct StatsMemory: Codable, Sendable {
    let heapUsed: Double
    let heapTotal: Double
    let rss: Double
    let external: Double
}

// MARK: - Active sessions

/// A session that is not stopped or in error state.
struct StatsActiveSession: Codable, Identifiable, Sendable {
    let id: String
    let status: String
    let model: String?
    let cost: Double
    let name: String?
    let thinkingLevel: String?
    let parentSessionId: String?
    let contextTokens: Int?
    let contextWindow: Int?
    let createdAt: Double

    /// True when the session is actively processing (status == "busy").
    var isBusy: Bool { status == "busy" }
    /// True when the session has a parent (child agent).
    var isChild: Bool { parentSessionId != nil }
}

// MARK: - Daily breakdown

/// Aggregated stats for a single calendar day (UTC).
struct StatsDailyEntry: Codable, Sendable {
    let date: String                              // "YYYY-MM-DD"
    let sessions: Int
    let cost: Double
    let tokens: Int
    let byModel: [String: StatsDailyModelEntry]
}

/// Per-model stats within a daily entry.
struct StatsDailyModelEntry: Codable, Sendable {
    let sessions: Int
    let cost: Double
    let tokens: Int
}

// MARK: - Model breakdown

/// Aggregated stats across the range period for a single model.
struct StatsModelBreakdown: Codable, Identifiable, Sendable {
    var id: String { model }
    let model: String
    let sessions: Int
    let cost: Double
    let tokens: Int
    /// Fraction of total cost (0–1).
    let share: Double
}

// MARK: - Workspace breakdown

/// Aggregated stats across the range period for a single workspace.
struct StatsWorkspaceBreakdown: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let sessions: Int
    let cost: Double
}

// MARK: - Totals

/// Overall totals across all sessions in the range.
struct StatsTotals: Codable, Sendable {
    let sessions: Int
    let cost: Double
    let tokens: Int
}
