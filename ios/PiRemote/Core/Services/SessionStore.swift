import Foundation

/// Observable store for session list and active session state.
///
/// Scoped to prevent re-renders from unrelated state changes.
/// Permission timer ticks don't touch this store.
@MainActor @Observable
final class SessionStore {
    var sessions: [Session] = []
    var activeSessionId: String?

    /// Current active session (convenience).
    var activeSession: Session? {
        sessions.first { $0.id == activeSessionId }
    }

    /// Insert or update a session from server data.
    func upsert(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.insert(session, at: 0) // Most recent first
        }
    }

    /// Remove a session.
    func remove(id: String) {
        sessions.removeAll { $0.id == id }
        if activeSessionId == id {
            activeSessionId = nil
        }
    }

    /// Sort sessions by last activity (most recent first).
    func sort() {
        sessions.sort { $0.lastActivity > $1.lastActivity }
    }
}
