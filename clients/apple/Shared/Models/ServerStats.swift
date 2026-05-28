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

/// Which server stats metric a chart or hero row displays.
enum StatsMetric: String, CaseIterable {
    case sessions
    case cost
    case tokens

    var chartTitle: String {
        switch self {
        case .sessions: return "Daily Sessions"
        case .cost: return "Daily Cost"
        case .tokens: return "Daily Tokens"
        }
    }

    func value(from data: DailyModelEntry) -> Double {
        switch self {
        case .sessions: return Double(data.sessions)
        case .cost: return data.cost
        case .tokens: return Double(data.tokens)
        }
    }

    func value(from entry: StatsDailyEntry) -> Double {
        switch self {
        case .sessions: return Double(entry.sessions)
        case .cost: return entry.cost
        case .tokens: return Double(entry.tokens)
        }
    }

    func axisLabel(_ value: Double) -> String {
        switch self {
        case .cost:
            return SessionFormatting.costString(value)
        case .sessions:
            return String(format: "%.0f", value)
        case .tokens:
            if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
            if value >= 1_000 { return String(format: "%.0fK", value / 1_000) }
            return String(format: "%.0f", value)
        }
    }

    func displayValue(_ value: Double) -> String {
        switch self {
        case .cost:
            return SessionFormatting.costString(value)
        case .sessions:
            return String(format: "%.0f", value)
        case .tokens:
            if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
            if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
            return String(format: "%.0f", value)
        }
    }

}

struct StatsModelDayValue: Identifiable {
    let date: Date
    let model: String
    let value: Double

    var id: String { "\(Int(date.timeIntervalSince1970))-\(model)" }

    static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Model breakdown

struct StatsModelBreakdown: Codable {
    let model: String
    let sessions: Int
    let cost: Double
    let tokens: Int
    let inputTokens: Int
    let cacheRead: Int?
    let cacheWrite: Int?
    let share: Double
}

func computePromptCacheRate(cacheRead: Int, inputTokens: Int, cacheWrite: Int) -> Double? {
    let denominator = cacheRead + inputTokens + cacheWrite
    guard cacheRead > 0, denominator > 0 else { return nil }
    return Double(cacheRead) / Double(denominator)
}

extension StatsModelBreakdown {
    /// Prompt-cache effectiveness on the input side.
    ///
    /// Uses cacheRead / (cacheRead + uncachedInput + cacheWrite).
    /// Output tokens are excluded; cache writes are included because they are
    /// paid prompt-side work and should count against effectiveness.
    var promptCacheRate: Double? {
        computePromptCacheRate(
            cacheRead: cacheRead ?? 0,
            inputTokens: inputTokens,
            cacheWrite: cacheWrite ?? 0
        )
    }
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
