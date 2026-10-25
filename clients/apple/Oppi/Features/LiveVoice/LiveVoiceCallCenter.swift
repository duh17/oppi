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
    /// The calls as CallKit calls. Previews and tests start without CallKit.
    @ObservationIgnored let systemCall: LiveVoiceSystemCall

    init(
        systemCall: LiveVoiceSystemCall = .withoutCallKit(),
        makeController: @escaping @MainActor () -> LiveVoiceCallController = { LiveVoiceCallController() }
    ) {
        self.systemCall = systemCall
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

    /// A live or starting call owns the one microphone: no dictation anywhere while it runs.
    var ownsMicrophone: Bool {
        guard let controller = placed?.controller else { return false }
        return controller.isLive || controller.isStarting
    }

    /// What a new call on a session means now. The one policy for offering and starting calls.
    enum CallStart: Equatable {
        /// No call is live: a call may start here.
        case available
        /// This session's own call is live; its composer already is the call.
        case onThisCall
        /// Another session's call is live. A call here ends that one first, once the person
        /// confirms (`replaceCall`).
        case endsCall(CallKey)
    }

    /// What starting a call on this session would do. A nil session id is a session not made
    /// yet (Quick Session), which can only meet another session's call.
    /// A call counts from the moment it holds the microphone (`ownsMicrophone`), so one still
    /// starting is already the call another session would end.
    func callStart(serverId: String?, sessionId: String?) -> CallStart {
        guard let placed, ownsMicrophone else { return .available }
        if let serverId, let sessionId, placed.key == CallKey(serverId: serverId, sessionId: sessionId) {
            return .onThisCall
        }
        return .endsCall(placed.key)
    }

    /// The controller for a new call on this session, now the app's call; the caller starts it.
    /// Nil unless `callStart` is `.available`. A call that failed on another session is replaced.
    func placeCall(serverId: String, sessionId: String) -> LiveVoiceCallController? {
        guard callStart(serverId: serverId, sessionId: sessionId) == .available else { return nil }
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

    /// The one way a call starts (a chat's Live Voice tap, End & Call, a Quick Session's call).
    /// Nil unless `callStart` is `.available`. Otherwise the session's call is placed and starting when this
    /// returns: it holds the microphone and shows Connecting, and a second start is refused.
    /// The rest runs on in order: microphone access, read-aloud and dictation stopped, then the
    /// system call (`LiveVoiceSystemCall`, or none when CallKit refuses), then the server call.
    @discardableResult
    func startCall(
        serverId: String,
        sessionId: String,
        routeScope: SessionRouteScope,
        using connection: ServerConnection
    ) -> LiveVoiceCallController? {
        guard let call = placeCall(serverId: serverId, sessionId: sessionId) else { return nil }
        call.beginStart()
        let key = CallKey(serverId: serverId, sessionId: sessionId)
        let systemCall = systemCall
        Task {
            guard await call.prepareStart(sessionId: sessionId, using: connection) else { return }
            await systemCall.start(call, key: key) {
                await call.start(sessionId: sessionId, routeScope: routeScope)
            }
        }
        return call
    }

    /// Ends the call on `serverId`, if there is one: the server is going away, and its call
    /// must not keep the microphone with no chat left to end it from.
    func endCall(serverId: String) async {
        guard let placed, placed.key.serverId == serverId else { return }
        await placed.controller.end()
    }

    /// End & Call: ends the call the person agreed to end (`ending`, live or still starting),
    /// waits for it to finish, then starts this session's through `startCall`, so it is a system
    /// call like any other (a call ended before the server confirmed it retires in
    /// `placeCall`). Only that call is ended: if another call holds the microphone by now, it
    /// is left alone and this returns nil, for the caller to ask again about that one.
    func replaceCall(
        serverId: String,
        sessionId: String,
        ending agreed: CallKey,
        routeScope: SessionRouteScope,
        using connection: ServerConnection
    ) async -> LiveVoiceCallController? {
        if case .endsCall(let holder) = callStart(serverId: serverId, sessionId: sessionId),
           holder == agreed, let current = placed {
            await current.controller.end()
        }
        return startCall(serverId: serverId, sessionId: sessionId, routeScope: routeScope, using: connection)
    }

    /// Chats on screen, by the session they show (`chatAppeared`), so the app-wide call strip
    /// stays out of the way of the call's own chat.
    private(set) var shownChats: [ObjectIdentifier: CallKey] = [:]

    /// A chat for this session came on screen (or back, after what covered it left).
    func chatAppeared(_ chat: AnyObject, serverId: String, sessionId: String) {
        let key = CallKey(serverId: serverId, sessionId: sessionId)
        guard shownChats[ObjectIdentifier(chat)] != key else { return }
        shownChats[ObjectIdentifier(chat)] = key
    }

    /// The chat left the screen: popped, covered by a pushed page, or torn down.
    func chatDisappeared(_ chat: AnyObject) {
        guard shownChats[ObjectIdentifier(chat)] != nil else { return }
        shownChats[ObjectIdentifier(chat)] = nil
    }
}
