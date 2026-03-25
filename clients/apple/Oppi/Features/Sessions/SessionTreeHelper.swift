import Foundation

/// Helpers for parent-child session relationships using flat session lists.
///
/// Sessions form a logical tree via `parentSessionId`. These helpers extract
/// roots, children, descendants, and aggregates directly from the flat list
/// without building an intermediate tree structure.
enum SessionTreeHelper {

    /// Aggregate child status counts for badges.
    struct StatusCounts: Equatable {
        var working: Int = 0
        var done: Int = 0
        var error: Int = 0
        var total: Int = 0
    }

    // MARK: - Direct children

    /// Get all immediate child sessions for a given parent.
    // periphery:ignore - used by SessionTreeHelperTests via @testable import
    static func childSessions(of parentId: String, in sessions: [Session]) -> [Session] {
        sessions.filter { $0.parentSessionId == parentId }
    }

    /// Get sorted immediate children of a parent session (by createdAt ascending).
    static func sortedChildSessions(of parentId: String, in sessions: [Session]) -> [Session] {
        childSessions(of: parentId, in: sessions).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Root filtering

    /// Filter sessions to only roots, checking parent existence against a broader session list.
    /// A root has no parentSessionId, or its parent is not in allSessions.
    static func rootSessions(from sessions: [Session], allSessions: [Session]) -> [Session] {
        let allIds = Set(allSessions.map(\.id))
        return sessions.filter { session in
            guard let parentId = session.parentSessionId else { return true }
            return !allIds.contains(parentId)
        }
    }

    // MARK: - Descendants

    /// All descendants (children, grandchildren, etc.) of a session.
    /// Guards against circular references via a visited set.
    static func allDescendants(of parentId: String, in sessions: [Session]) -> [Session] {
        let childrenByParent = Dictionary(grouping: sessions.filter { $0.parentSessionId != nil }) {
            $0.parentSessionId ?? ""
        }
        var result: [Session] = []
        var visited = Set<String>([parentId])
        var queue = childrenByParent[parentId] ?? []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard !visited.contains(current.id) else { continue }
            visited.insert(current.id)
            result.append(current)
            queue.append(contentsOf: childrenByParent[current.id] ?? [])
        }
        return result
    }

    /// Count of all descendants.
    // periphery:ignore - used by SessionTreeHelperTests via @testable import
    static func descendantCount(of parentId: String, in sessions: [Session]) -> Int {
        allDescendants(of: parentId, in: sessions).count
    }

    /// Status counts for all descendants.
    static func descendantStatusCounts(of parentId: String, in sessions: [Session]) -> StatusCounts {
        var counts = StatusCounts()
        for session in allDescendants(of: parentId, in: sessions) {
            counts.total += 1
            switch session.status {
            case .starting, .busy, .stopping: counts.working += 1
            case .ready, .stopped: counts.done += 1
            case .error: counts.error += 1
            }
        }
        return counts
    }

    /// Aggregate cost: session + all descendants.
    static func descendantCost(of sessionId: String, in sessions: [Session]) -> Double {
        let own = sessions.first { $0.id == sessionId }?.cost ?? 0
        return own + allDescendants(of: sessionId, in: sessions).reduce(0.0) { $0 + $1.cost }
    }

    /// Aggregate pending count: session + direct children only.
    /// Grandchildren are not included — matches the one-level-deep spawn_agent UX.
    static func aggregatePendingCount(
        of sessionId: String,
        in sessions: [Session],
        pendingForSession: (String) -> Int
    ) -> Int {
        let own = pendingForSession(sessionId)
        let childPending = childSessions(of: sessionId, in: sessions)
            .reduce(0) { $0 + pendingForSession($1.id) }
        return own + childPending
    }
}
