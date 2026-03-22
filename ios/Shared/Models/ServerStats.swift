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
    let firstMessage: String?
    let workspaceName: String?
    let thinkingLevel: String?
    let parentSessionId: String?
    let contextTokens: Int?
    let contextWindow: Int?
    let createdAt: Double?  // epoch ms from server

    /// Display title matching iOS SessionRow logic: name → first message preview → Session <id>.
    var displayTitle: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let firstMessage = firstMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstMessage.isEmpty {
            return String(firstMessage.prefix(80))
        }
        return "Session \(String(id.prefix(8)))"
    }
}

// MARK: - Daily entry

struct DailyModelEntry: Codable, Sendable {
    let sessions: Int
    let cost: Double
    let tokens: Int
}

struct StatsDailyEntry: Codable {
    let date: String
    let sessions: Int
    let cost: Double
    let tokens: Int
    let byModel: [String: DailyModelEntry]?
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

// MARK: - Daily detail (hourly drill-down)

struct StatsDailyHourlyEntry: Codable, Sendable {
    let hour: Int          // 0-23
    let sessions: Int
    let cost: Double
    let tokens: Int
    let byModel: [String: DailyModelEntry]?
}

struct StatsDailySession: Codable, Sendable {
    let id: String
    let name: String?
    let model: String?
    let cost: Double
    let tokens: Int
    let createdAt: Double  // epoch ms
    let workspaceName: String?
    let status: String
}

struct DailyDetail: Codable, Sendable {
    let date: String       // "YYYY-MM-DD"
    let totals: StatsTotals
    let hourly: [StatsDailyHourlyEntry]
    let sessions: [StatsDailySession]
}

// MARK: - Sendable conformances

extension StatsMemory: Sendable {}
extension StatsDailyEntry: Sendable {}
extension StatsModelBreakdown: Sendable {}
extension StatsWorkspaceBreakdown: Sendable {}
extension StatsTotals: Sendable {}
