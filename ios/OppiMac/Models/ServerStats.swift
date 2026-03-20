import Foundation

// MARK: - Memory

struct StatsMemory: Codable {
    let heapUsed: Double
    let heapTotal: Double
    let rss: Double
    let external: Double
}

// MARK: - Active session

struct StatsActiveSession: Codable, Sendable {
    let id: String
    let status: String
    let model: String?
    let cost: Double
    let name: String?
    let thinkingLevel: String?
    let parentSessionId: String?
    let contextTokens: Int?
    let contextWindow: Int?
    let createdAt: Double?  // epoch ms from server
}

// MARK: - Daily entry

struct StatsDailyEntry: Codable {
    let date: String
    let sessions: Int
    let cost: Double
    let tokens: Int
}

// MARK: - Model breakdown

struct StatsModelBreakdown: Codable {
    let model: String
    let sessions: Int
    let cost: Double
    let tokens: Int
    let share: Double
}

// MARK: - Workspace breakdown

struct StatsWorkspaceBreakdown: Codable {
    let id: String
    let name: String?
    let sessions: Int
    let cost: Double
}

// MARK: - Totals

struct StatsTotals: Codable {
    let sessions: Int
    let cost: Double
    let tokens: Int
}

// MARK: - Top-level response

struct ServerStats: Codable, Sendable {
    let memory: StatsMemory
    let activeSessions: [StatsActiveSession]
    let daily: [StatsDailyEntry]
    let modelBreakdown: [StatsModelBreakdown]
    let workspaceBreakdown: [StatsWorkspaceBreakdown]
    let totals: StatsTotals
}

// MARK: - Helpers

extension StatsActiveSession {
    var isBusy: Bool { status == "busy" || status == "starting" }
}

// MARK: - Sendable conformances

extension StatsMemory: Sendable {}
extension StatsDailyEntry: Sendable {}
extension StatsModelBreakdown: Sendable {}
extension StatsWorkspaceBreakdown: Sendable {}
extension StatsTotals: Sendable {}
