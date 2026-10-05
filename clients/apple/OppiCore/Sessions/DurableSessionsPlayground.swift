import Foundation

/// Rules for the Durable Sessions experiment: a per-device playground list of
/// one server's durable sessions. Main session lists keep showing every session.
enum DurableSessionsPlayground {
    /// The Durable item shows only when this device opted in and the server
    /// advertises `capabilities.durableSessions`.
    static func isAvailable(experimentEnabled: Bool, serverOffersDurable: Bool) -> Bool {
        experimentEnabled && serverOffersDurable
    }

    /// Durable workspace sessions, most recent activity first.
    static func sessions(from sessions: [Session]) -> [Session] {
        sessions
            .filter { $0.engine == .durable && $0.control == nil }
            .sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.id < rhs.id
            }
    }
}
