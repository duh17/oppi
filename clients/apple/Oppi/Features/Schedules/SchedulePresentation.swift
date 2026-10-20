import Foundation

/// Text the Schedules screens show for a schedule and its runs.
enum SchedulePresentation {
    /// Prettifies only the leading error code. Detail after the first `:` is
    /// server data (extension ids, skill paths) and must pass through unchanged.
    nonisolated static func runErrorSummary(_ error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        if error.contains("approval_required_noninteractive") {
            return "Approval required — this action can’t run unattended."
        }
        guard let colon = error.firstIndex(of: ":") else {
            return error.replacingOccurrences(of: "_", with: " ")
        }
        let code = error[..<colon].replacingOccurrences(of: "_", with: " ")
        let detail = error[error.index(after: colon)...].drop { $0 == " " }
        return "\(code): \(detail)"
    }

    static func runSourceLabel(_ kind: AgentScheduleRunKind) -> String {
        switch kind {
        case .due: "Scheduled"
        case .manual: "Started manually"
        }
    }

    static func prompt(in action: AgentScheduleAction) -> String {
        switch action {
        case .newSession(_, let prompt, _, _, _, _, _),
             .existingSession(_, _, let prompt, _):
            prompt
        }
    }

    static func runWithSectionTitle(_ action: AgentScheduleAction) -> String {
        switch action {
        case .newSession: "Run with"
        case .existingSession: "Target"
        }
    }
}

func scheduleRunsByInsertingNewest(
    _ run: AgentScheduleRunSummary,
    into runs: [AgentScheduleRunSummary],
    limit: Int
) -> [AgentScheduleRunSummary] {
    guard limit > 0 else { return [] }
    let updated = [run] + runs.filter { $0.id != run.id }
    return Array(updated.sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
        return $0.id > $1.id
    }.prefix(limit))
}

extension AgentScheduleStatus {
    static var filterOrder: [AgentScheduleStatus] { [.active, .paused, .archived] }

    var filterTitle: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .archived: "Archived"
        }
    }

    var emptyTitle: String {
        switch self {
        case .active: "No Active Schedules"
        case .paused: "No Paused Schedules"
        case .archived: "No Archived Schedules"
        }
    }

    var emptySystemImage: String {
        switch self {
        case .active: "calendar.badge.plus"
        case .paused: "pause.circle"
        case .archived: "archivebox"
        }
    }

    var emptyDescription: String {
        switch self {
        case .active: "Describe what should happen and when below."
        case .paused: "Schedules you pause will appear here."
        case .archived: "Archived schedules stay recoverable here."
        }
    }
}
