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

/// Sum optional token counters. `nil` means "not applicable" and stays nil until a real value appears.
func mergeOptionalTokenCounts(_ lhs: Int?, _ rhs: Int?) -> Int? {
    switch (lhs, rhs) {
    case (nil, nil):
        return nil
    case (let left?, nil):
        return left
    case (nil, let right?):
        return right
    case (let left?, let right?):
        return left + right
    }
}

/// Model-breakdown cache-write label.
/// `nil` means the provider has no write counter (for example xAI Grok).
func formatModelCacheWriteLabel(_ cacheWrite: Int?) -> String {
    guard let cacheWrite else { return "W: —" }
    return "W: \(formatModelTokenCount(cacheWrite))"
}

func formatModelTokenCount(_ value: Int) -> String {
    if value >= 1_000_000_000 {
        return String(format: "%.1fB", Double(value) / 1_000_000_000)
    }
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.0fK", Double(value) / 1_000)
    }
    return "\(value)"
}

extension StatsModelBreakdown {
    /// Prompt-cache effectiveness on the input side.
    ///
    /// Uses cacheRead / (cacheRead + uncachedInput + cacheWrite).
    /// Output tokens are excluded; cache writes are included because they are
    /// paid prompt-side work and should count against effectiveness.
    /// When cacheWrite is nil (provider has no write concept), it contributes 0.
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

// MARK: - Resource usage

enum ResourceUsageRange: Int, CaseIterable, Codable, Sendable, Equatable, Identifiable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }
    var shortLabel: String { "\(rawValue)d" }
}

struct ResourceUsageSubject: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable, Equatable, Hashable {
        case skill
        case `extension`
        case tools
    }

    let kind: Kind
    let id: String?
}

/// Identity of one server-scoped usage request. The server ID is not returned
/// in the usage payload, so it remains part of the client-side request key.
struct ResourceUsageRequestKey: Hashable, Sendable, Equatable {
    let serverId: String
    let subject: ResourceUsageSubject
}

enum ResourceUsageSignal: String, Codable, Sendable, Equatable {
    case agentLoad = "agent_load"
    case explicitActivation = "explicit_activation"
    case toolInvocation = "tool_invocation"
    case commandInvocation = "command_invocation"
}

enum ResourceUsageOwnerKind: String, Codable, Sendable, Equatable {
    case skill
    case `extension`
    case builtIn = "builtin"
}

struct ResourceUsageDailyRow: Codable, Sendable, Equatable, Identifiable {
    let date: String
    let actions: Int
    let sessions: Int

    var id: String { date }
}

struct ResourceUsageBreakdownRow: Codable, Sendable, Equatable, Identifiable {
    let signal: ResourceUsageSignal
    let name: String
    let ownerKind: ResourceUsageOwnerKind
    let ownerId: String
    let actions: Int
    let sessions: Int

    var id: String { "\(signal.rawValue)|\(ownerKind.rawValue)|\(ownerId)|\(name)" }
}

struct ResourceUsageCaptureStatus: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable, Equatable {
        case active
        case degraded
    }

    let status: Status
    let failedWrites: Int
    let droppedEvents: Int
    let lastCapturedAt: Int64?
}

struct ResourceUsageRetainedHistory: Codable, Sendable, Equatable {
    let retentionDays: Int
    let oldestRecordedAt: Int64?
    let lastRecordedAt: Int64?
}

struct ResourceUsageResponse: Codable, Sendable, Equatable {
    let subject: ResourceUsageSubject
    let rangeDays: ResourceUsageRange
    let timezone: String
    let recordingStartedAt: Int64
    let recordedActions: Int
    let distinctSessions: Int
    let activeDays: Int
    let lastRecordedAt: Int64?
    let retainedHistory: ResourceUsageRetainedHistory
    let daily: [ResourceUsageDailyRow]
    let breakdown: [ResourceUsageBreakdownRow]
    let capture: ResourceUsageCaptureStatus

    var range: ResourceUsageRange { rangeDays }

    func matches(
        requestKey: ResourceUsageRequestKey,
        range: ResourceUsageRange,
        timezone: String
    ) -> Bool {
        requestKey.subject == subject
            && rangeDays == range
            && self.timezone == timezone
    }

    var coverage: ResourceUsageCoveragePresentation {
        ResourceUsageCoveragePresentation(capture: capture)
    }
}

struct ResourceUsageCoveragePresentation: Sendable, Equatable {
    let capture: ResourceUsageCaptureStatus

    var isPartial: Bool { capture.status == .degraded }
}

enum ResourceUsagePresentationState: Sendable, Equatable {
    case loading
    case empty
    case content
    case failure(String)

    static func resolve(
        isLoading: Bool,
        response: ResourceUsageResponse?,
        error: String?
    ) -> Self {
        if let response {
            return response.recordedActions == 0 ? .empty : .content
        }
        if isLoading { return .loading }
        if let error { return .failure(error) }
        return .loading
    }
}

struct ResourceUsageToolGroup: Sendable, Equatable, Identifiable {
    enum Kind: Int, Sendable, Equatable, Identifiable {
        case builtIn
        case extensions

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .builtIn: "Built-in Tools"
            case .extensions: "Extension Tools"
            }
        }
    }

    let kind: Kind
    let rows: [ResourceUsageBreakdownRow]

    var id: Kind { kind }
}

enum ResourceUsagePresentation {
    static func response(
        _ response: ResourceUsageResponse?,
        responseKey: ResourceUsageRequestKey?,
        requestKey: ResourceUsageRequestKey,
        range: ResourceUsageRange,
        timezone: String
    ) -> ResourceUsageResponse? {
        guard let response,
              responseKey == requestKey,
              response.matches(requestKey: requestKey, range: range, timezone: timezone) else {
            return nil
        }
        return response
    }

    static func error(
        _ error: String?,
        errorRequestID: String?,
        requestID: String
    ) -> String? {
        guard errorRequestID == requestID else { return nil }
        return error
    }

    static func emptyMessage(for range: ResourceUsageRange) -> String {
        "No recorded activity in the last \(range.rawValue) days."
    }

    static func toolGroups(
        from rows: [ResourceUsageBreakdownRow]
    ) -> [ResourceUsageToolGroup] {
        let definitions: [(ResourceUsageToolGroup.Kind, ResourceUsageOwnerKind)] = [
            (.builtIn, .builtIn),
            (.extensions, .extension),
        ]
        return definitions.compactMap { kind, ownerKind in
            let matches = rows.filter { $0.ownerKind == ownerKind }
            return matches.isEmpty ? nil : ResourceUsageToolGroup(kind: kind, rows: matches)
        }
    }

    static func signalLabel(_ signal: ResourceUsageSignal) -> String {
        switch signal {
        case .agentLoad: "Agent load"
        case .explicitActivation: "Explicit activation"
        case .toolInvocation: "Tool invocation"
        case .commandInvocation: "Command invocation"
        }
    }

    static func summaryAccessibilityLabel(_ usage: ResourceUsageResponse) -> String {
        "Observed usage for the last \(usage.range.rawValue) days: "
            + "\(usage.recordedActions) recorded actions, "
            + "\(usage.distinctSessions) sessions, \(usage.activeDays) active days."
    }

    static func breakdownAccessibilityLabel(_ row: ResourceUsageBreakdownRow) -> String {
        "\(row.name), \(signalLabel(row.signal).lowercased()), "
            + "\(row.actions) recorded actions, \(row.sessions) sessions."
    }

    static func recordingStartedLabel(_ usage: ResourceUsageResponse) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: usage.timezone)
        let date = Date(timeIntervalSince1970: Double(usage.recordingStartedAt) / 1_000)
        return "Recorded by this server since \(formatter.string(from: date))"
    }

    static func coverageAccessibilityLabel(_ usage: ResourceUsageResponse) -> String {
        let capture = usage.capture.status == .active
            ? "Live capture is current."
            : "Live capture is partial."
        return "Coverage: \(recordingStartedLabel(usage)). \(capture) "
            + "Recorded activity is retained for up to \(usage.retainedHistory.retentionDays) days."
    }

    static func dailyActivityAccessibilityLabel(_ usage: ResourceUsageResponse) -> String {
        "Daily activity: \(usage.recordedActions) recorded actions across "
            + "\(usage.activeDays) active days in the last \(usage.range.rawValue) days."
    }
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
