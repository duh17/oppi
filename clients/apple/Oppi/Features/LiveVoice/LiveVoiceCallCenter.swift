import Observation

/// The app's Live Voice call. There is at most one, on one server's session, and it lives
/// here rather than in a chat: leaving the chat (back to the list, another session, a
/// stack/split swap, a lock cover) leaves the call running, and the session's chat shows the
/// same call when it opens again. Only End, the server ending it (a deleted session), or a
/// dead link end it (`LiveVoiceCallController`).
///
/// `AppRootEnvironment.liveVoiceCalls` holds the one instance for the app. `OppiApp` also
/// hands it to `ConnectionCoordinator` (removing a server ends its call) and to
/// `VoiceInputManager.shared` (no dictation while a call holds the microphone).
@MainActor
@Observable
final class LiveVoiceCallCenter {
    /// The same session id on two servers is two sessions.
    struct CallKey: Hashable, Sendable {
        let serverId: String
        let sessionId: String
    }

    /// The call and the session it talks to.
    struct Call {
        let key: CallKey
        let controller: LiveVoiceCallController
    }

    /// The last call placed. Kept after it ends, so the same session's next call reuses its
    /// controller (a fresh client call id, the same meter), as a chat's own controller did.
    private var placed: Call?
    /// Replaced calls whose End was pressed before the server confirmed them. Each is kept
    /// until its late snapshot arrives and the end goes out; dropped, it would leave the
    /// server's call running detached until its TTL.
    @ObservationIgnored private var retiring: [LiveVoiceCallController] = []
    @ObservationIgnored private let makeController: @MainActor () -> LiveVoiceCallController

    init(makeController: @escaping @MainActor () -> LiveVoiceCallController = { LiveVoiceCallController() }) {
        self.makeController = makeController
    }

    /// The call on screen somewhere: live, connecting, or failed and showing why until End.
    /// Nil once it ended.
    var currentCall: Call? {
        guard let placed, placed.controller.holdsComposer else { return nil }
        return placed
    }

    /// The session's call, wherever it was started; nil when it has none.
    func call(serverId: String, sessionId: String) -> LiveVoiceCallController? {
        guard let currentCall,
              currentCall.key == CallKey(serverId: serverId, sessionId: sessionId) else { return nil }
        return currentCall.controller
    }

    /// A live call owns the one microphone: no dictation anywhere while it runs.
    var ownsMicrophone: Bool { placed?.controller.isLive == true }

    /// Whether any session may offer a new call now. Interim policy: while a call is live,
    /// no session offers one, its own included (that one already has it). Switching a call to
    /// another session is a later product decision; this is the one place to change.
    var mayStartCall: Bool { !ownsMicrophone }

    /// The controller for a new call on this session, now the app's call; the caller starts it.
    /// Nil while `mayStartCall` refuses. A call that failed on another session is replaced.
    func placeCall(serverId: String, sessionId: String) -> LiveVoiceCallController? {
        guard mayStartCall else { return nil }
        let key = CallKey(serverId: serverId, sessionId: sessionId)
        if let placed, placed.key == key {
            return placed.controller
        }
        retiring.removeAll { !$0.isEndingUnconfirmedCall }
        if let placed, placed.controller.isEndingUnconfirmedCall {
            retiring.append(placed.controller)
        }
        let call = Call(key: key, controller: makeController())
        placed = call
        return call.controller
    }

    /// Ends the call on `serverId`, if there is one: the server is going away, and its call
    /// must not keep the microphone with no chat left to end it from.
    func endCall(serverId: String) async {
        guard let placed, placed.key.serverId == serverId else { return }
        await placed.controller.end()
    }
}
