import Foundation

/// Observable store for pending AskCard prompts (agent questions to the user).
///
/// Each session can have at most one pending ask at a time.
///
/// This is the canonical pending ask projection for composer rendering,
/// cross-session restore, workspace attention snapshots, and session list badges.
@MainActor @Observable
final class AskRequestStore {
    // Per-server backing storage
    private var serverPending: [String: [String: AskRequest]] = [:]

    /// Which server's asks are currently active.
    private(set) var activeServerId: String?

    // MARK: - Active server API

    /// All pending ask requests for the currently active server.
    var pending: [String: AskRequest] {
        get { serverPending[activeServerId ?? ""] ?? [:] }
        set { serverPending[activeServerId ?? ""] = newValue }
    }

    /// Total pending count for the active server.
    var count: Int { pending.count }

    /// Set a pending ask for a session (replaces any existing).
    func set(_ ask: AskRequest, for sessionId: String) {
        var dict = pending
        dict[sessionId] = ask
        pending = dict
    }

    /// Remove the pending ask for a session.
    func remove(for sessionId: String) {
        var dict = pending
        dict.removeValue(forKey: sessionId)
        pending = dict
    }

    /// Get the pending ask for a specific session, if any.
    func pending(for sessionId: String) -> AskRequest? {
        pending[sessionId]
    }

    /// Check whether a session has a pending ask.
    func hasPending(for sessionId: String) -> Bool {
        pending[sessionId] != nil
    }

    /// Apply an authoritative workspace-scoped HTTP attention snapshot.
    ///
    /// Returns session IDs whose pending ask was removed.
    @discardableResult
    func applyWorkspaceSnapshot(
        workspaceId: String,
        asks: [AskRequest],
        workspaceSessionIds: Set<String>
    ) -> [String] {
        let incomingSessionIds = Set(asks.map(\.sessionId))
        var dict = pending
        let removedSessionIds = dict.values
            .filter { ask in
                ask.workspaceId == workspaceId ||
                    (ask.workspaceId == nil && workspaceSessionIds.contains(ask.sessionId))
            }
            .filter { !incomingSessionIds.contains($0.sessionId) }
            .map(\.sessionId)

        for sessionId in removedSessionIds {
            dict.removeValue(forKey: sessionId)
        }

        for ask in asks {
            dict[ask.sessionId] = ask
        }

        pending = dict
        return removedSessionIds
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

    /// Remove all data for a server (on unpair).
    func removeServer(_ serverId: String) {
        serverPending.removeValue(forKey: serverId)
        if activeServerId == serverId {
            activeServerId = nil
        }
    }
}
