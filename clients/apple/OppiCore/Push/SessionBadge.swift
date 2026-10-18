import Foundation

/// The app icon badge: how many sessions owe the user a look, across every paired server.
///
/// A session owes a look while it waits on the user (approval, question, sign-in), lead or
/// subagent alike, and while a top-level run's done or error outcome is unseen on this
/// device. A subagent that merely finished, and a run the user cancelled, owe nothing. Each
/// session counts once, however many notifications it raised.
///
/// The app recounts from its session stores and stores the set in the App Group. While the
/// app is not running, the Notification Service Extension adds each decrypted push's session
/// to that set and badges the push with its size.
struct SessionBadge: Codable, Equatable, Sendable {
    struct Key: Codable, Hashable, Sendable {
        let serverId: String
        let sessionId: String
    }

    private(set) var sessions: Set<Key> = []

    var count: Int { sessions.count }

    /// The counting rule, for the app's session stores and the extension's pushes alike.
    static func owesLook(isBlocked: Bool, hasUnseenOutcome: Bool, isTopLevel: Bool) -> Bool {
        isBlocked || (hasUnseenOutcome && isTopLevel)
    }

    /// The session a decrypted push says owes a look, or nil for a pairing push. Blocked
    /// pushes come for any session; the server sends a failed run and an agent's message only
    /// for top-level sessions, and each is something the user has not seen yet.
    static func key(serverId: String, plaintext: PushPlaintext) -> Key? {
        guard let sessionId = plaintext.sessionId,
              owesLook(
                isBlocked: plaintext.event == .blocked,
                hasUnseenOutcome: plaintext.event == .error || plaintext.event == .notify,
                isTopLevel: true
              ) else { return nil }
        return Key(serverId: serverId, sessionId: sessionId)
    }

    /// A second push for the same session adds nothing.
    mutating func insert(_ key: Key) {
        sessions.insert(key)
    }

    /// The app's recount. `owed` replaces what each server in `loadedServerIds` owes; a
    /// paired server the app has not loaded yet keeps what pushes recorded for it; a server
    /// that is no longer paired drops out.
    mutating func reconcile(owed: Set<Key>, loadedServerIds: Set<String>, pairedServerIds: Set<String>) {
        sessions = sessions
            .filter { pairedServerIds.contains($0.serverId) && !loadedServerIds.contains($0.serverId) }
            .union(owed)
    }
}
