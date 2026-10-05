import Foundation

/// Rules for the Durable Sessions experiment: the All Sessions list scoped to
/// one server's durable sessions. Main session lists keep showing every session.
enum DurableSessionsPlayground {
    /// The Durable item shows only when this device opted in and the server
    /// advertises `capabilities.durableSessions`.
    static func isAvailable(experimentEnabled: Bool, serverOffersDurable: Bool) -> Bool {
        experimentEnabled && serverOffersDurable
    }

    /// Durable sessions from the server's full history (`recentDays=0`) merged
    /// with the live store, whose copies are newer and include sessions created
    /// after the history loaded.
    static func sessions(history: [Session], live: [Session]) -> [Session] {
        var byId = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for session in live { byId[session.id] = session }
        return sessions(from: Array(byId.values))
    }

    /// Durable workspace sessions, most recent activity first.
    static func sessions(from sessions: [Session]) -> [Session] {
        sessions
            .filter(isListed)
            .sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.id < rhs.id
            }
    }

    /// A durable workspace session; control sessions stay out of the playground.
    static func isListed(_ session: Session) -> Bool {
        session.engine == .durable && session.control == nil
    }
}
