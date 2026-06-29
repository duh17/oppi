import Foundation

/// Observable store for pending AskCard prompts (agent questions to the user).
///
/// A session can have multiple blocking extension UI requests pending at once
/// when Pi runs sibling tools in parallel. The client renders one AskCard per
/// session at a time and reveals the next request after the current request is
/// answered or settled.
///
/// This is the canonical pending ask projection for composer rendering,
/// cross-session restore, workspace attention snapshots, and session list badges.
@MainActor @Observable
final class AskRequestStore {
    // Per-server backing storage: server id -> session id -> queued asks.
    private var serverPending: [String: [String: [AskRequest]]] = [:]

    /// Which server's asks are currently active.
    private(set) var activeServerId: String?

    private var activeServerKey: String { activeServerId ?? "" }

    private var activePendingQueues: [String: [AskRequest]] {
        get { serverPending[activeServerKey] ?? [:] }
        set { serverPending[activeServerKey] = newValue }
    }

    // MARK: - Active server API

    /// The visible pending ask request for each session on the active server.
    var pending: [String: AskRequest] {
        Dictionary(uniqueKeysWithValues: activePendingQueues.compactMap { entry in
            guard let first = entry.value.first else { return nil }
            return (entry.key, first)
        })
    }

    /// Append a pending ask for a session, or update an existing request with the same id.
    ///
    /// Returns `true` when this is a new queued request, and `false` for an idempotent replay/update.
    @discardableResult
    func set(_ ask: AskRequest, for sessionId: String) -> Bool {
        var queues = activePendingQueues
        var queue = queues[sessionId] ?? []
        let inserted: Bool

        if let existingIndex = queue.firstIndex(where: { $0.id == ask.id }) {
            queue[existingIndex] = ask
            inserted = false
        } else {
            queue.append(ask)
            inserted = true
        }

        queues[sessionId] = queue
        activePendingQueues = queues
        return inserted
    }

    /// Remove every pending ask for a session.
    func remove(for sessionId: String) {
        var queues = activePendingQueues
        queues.removeValue(forKey: sessionId)
        activePendingQueues = queues
    }

    /// Remove one request by id, preserving other queued requests for the same session.
    @discardableResult
    func remove(id requestId: String) -> [(sessionId: String, request: AskRequest)] {
        var queues = activePendingQueues
        var removed: [(sessionId: String, request: AskRequest)] = []

        for sessionId in Array(queues.keys) {
            guard var queue = queues[sessionId] else { continue }
            var sessionRemoved: [AskRequest] = []
            queue.removeAll { ask in
                guard ask.id == requestId else { return false }
                sessionRemoved.append(ask)
                return true
            }
            guard !sessionRemoved.isEmpty else { continue }
            removed.append(contentsOf: sessionRemoved.map { (sessionId: sessionId, request: $0) })
            if queue.isEmpty {
                queues.removeValue(forKey: sessionId)
            } else {
                queues[sessionId] = queue
            }
        }

        activePendingQueues = queues
        return removed
    }

    /// Get the visible pending ask for a specific session, if any.
    func pending(for sessionId: String) -> AskRequest? {
        activePendingQueues[sessionId]?.first
    }

    /// Check whether a session has any pending ask.
    func hasPending(for sessionId: String) -> Bool {
        !(activePendingQueues[sessionId]?.isEmpty ?? true)
    }

    /// Apply an authoritative workspace-scoped HTTP attention snapshot.
    ///
    /// Returns session IDs where a snapshot-managed ask was removed.
    @discardableResult
    func applyWorkspaceSnapshot(
        workspaceId: String,
        asks: [AskRequest],
        workspaceSessionIds: Set<String>
    ) -> [String] {
        var queues = activePendingQueues
        var incomingById: [String: AskRequest] = [:]
        for ask in asks {
            incomingById[ask.id] = ask
        }
        var retainedIncomingIds = Set<String>()
        var removedSessionIds = Set<String>()

        for sessionId in Array(queues.keys) {
            guard let queue = queues[sessionId] else { continue }
            var nextQueue: [AskRequest] = []

            for ask in queue {
                guard Self.isWorkspaceSnapshotManagedAsk(
                    ask,
                    workspaceId: workspaceId,
                    workspaceSessionIds: workspaceSessionIds
                ) else {
                    nextQueue.append(ask)
                    continue
                }

                if let refreshedAsk = incomingById[ask.id] {
                    nextQueue.append(refreshedAsk)
                    retainedIncomingIds.insert(ask.id)
                } else {
                    removedSessionIds.insert(sessionId)
                }
            }

            if nextQueue.isEmpty {
                queues.removeValue(forKey: sessionId)
            } else {
                queues[sessionId] = nextQueue
            }
        }

        for ask in asks where !retainedIncomingIds.contains(ask.id) {
            var queue = queues[ask.sessionId] ?? []
            if let existingIndex = queue.firstIndex(where: { $0.id == ask.id }) {
                queue[existingIndex] = ask
            } else {
                queue.append(ask)
            }
            queues[ask.sessionId] = queue
        }

        activePendingQueues = queues
        return Array(removedSessionIds).sorted()
    }

    // MARK: - Server switching

    /// Switch the active server partition.
    func switchServer(to serverId: String) {
        guard serverId != activeServerId else { return }
        activeServerId = serverId
        if serverPending[serverId] == nil {
            serverPending[serverId] = [:]
        }
    }

    private static func isWorkspaceSnapshotManagedAsk(
        _ ask: AskRequest,
        workspaceId: String,
        workspaceSessionIds: Set<String>
    ) -> Bool {
        ask.responseEncoding == .ask
            && (ask.workspaceId == workspaceId
                || (ask.workspaceId == nil && workspaceSessionIds.contains(ask.sessionId)))
    }
}
