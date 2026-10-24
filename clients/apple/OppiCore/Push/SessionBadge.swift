import Foundation

/// The app icon badge: how many sessions are waiting on the user, across every paired server.
///
/// A session counts while its status is blocked (`SessionStatusKind.isBlocked`): it waits on
/// an approval, a question, or a sign-in, lead or subagent alike. A finished run counts
/// nothing, whether it succeeded or failed, and neither does anything else the user has not
/// seen yet. It drops when a session stops waiting, not when it is opened. The Live
/// Activity counts threads instead, so a lead and its waiting subagent are one on the card.
/// Each session counts once, however many notifications it raised.
///
/// The app recounts from its session stores and stores the set in the App Group. While the
/// app is not running, the Notification Service Extension adds each decrypted blocked push's
/// session to that set and badges the push with its size; an error or agent-message push
/// leaves the badge as it is.
struct SessionBadge: Codable, Equatable, Sendable {
    struct Key: Codable, Hashable, Sendable {
        let serverId: String
        let sessionId: String
    }

    private(set) var sessions: Set<Key> = []

    var count: Int { sessions.count }

    /// The session a decrypted push says waits on the user, or nil for a pairing push and for
    /// any push that is not a blockage: the server sends a failed run and an agent's message
    /// for a session that is not waiting on anything, so neither adds to the count.
    static func key(serverId: String, plaintext: PushPlaintext) -> Key? {
        guard plaintext.event == .blocked, let sessionId = plaintext.sessionId else { return nil }
        return Key(serverId: serverId, sessionId: sessionId)
    }

    /// A second push for the same session adds nothing.
    mutating func insert(_ key: Key) {
        sessions.insert(key)
    }

    /// The app's recount. `needingYou` replaces what each server in `loadedServerIds` needs; a
    /// paired server the app has not loaded yet keeps what pushes recorded for it, so those
    /// entries settle once it loads; a server that is no longer paired drops out.
    mutating func reconcile(needingYou: Set<Key>, loadedServerIds: Set<String>, pairedServerIds: Set<String>) {
        sessions = sessions
            .filter { pairedServerIds.contains($0.serverId) && !loadedServerIds.contains($0.serverId) }
            .union(needingYou)
    }
}
