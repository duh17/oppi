@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
protocol LiveVoiceCallChannel: AnyObject {
    var onInboundAudio: (@MainActor (Data) -> Void)? { get set }
    func open(sessionId: String, routeScope: SessionRouteScope) -> AsyncStream<ServerMessage>
    func send(_ message: ClientMessage) async throws
    func sendAudio(_ pcm: Data) async throws
    func close()
}

struct LiveVoiceCallIdentity: Equatable, Sendable {
    var callId: String
    var clientCallId: String
    var eventSeq: Int
}

/// Remembers the open call per server and session, so a start after the app was closed
/// mid-call rejoins it.
@MainActor
protocol LiveVoiceSessionMemory: AnyObject {
    func callIdentity(forServer serverKey: String) -> LiveVoiceCallIdentity?
    func store(callIdentity: LiveVoiceCallIdentity, forServer serverKey: String)
    func clearCallIdentity(forServer serverKey: String)
}

/// Owns a Live Voice call on one session and its duplex capture. The app's
/// `LiveVoiceCallCenter` holds it, so the call outlives any chat showing it. It does not own
/// the text composer, which shows the call (`holdsComposer`). What the caller says arrives in
/// that session; its agent answers out loud.
@MainActor
@Observable
final class LiveVoiceCallController {
    /// Well inside the server's 30-second controller lease.
    private let keepAliveInterval: Duration

    private(set) var isLive = false
    private(set) var isMuted = false
    private(set) var callState: VoiceCallStateSnapshot?
    /// The call's own state: connecting, listening, the agent's progress, or why the call
    /// failed. What the user is saying is `partialTranscript`.
    private(set) var statusText = "Listening"
    private(set) var lastError: String?
    /// The agent's reply is playing.
    private(set) var isSpeaking = false
    /// The system put the call on hold (a phone call answered over it, `LiveVoiceSystemCall`):
    /// no mic audio goes out and nothing plays, but the server call and its keepalive go on.
    private(set) var isOnHold = false
    /// Mic and playback levels for the composer's orb; outlives each call's audio.
    @ObservationIgnored let meter = LiveVoiceAudioMeter()

    /// The composer is the call surface while the call is up, and after a failed call until
    /// End, so the reason stays on screen.
    var holdsComposer: Bool { isLive || lastError != nil }

    /// What the user is saying right now, before the server sends it as their message.
    var partialTranscript: String {
        callState?.partialTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The composer's placeholder during a call.
    var composerStatus: String {
        // A dropped frontend outranks the voice; the reply keeps playing.
        guard isLive, callState?.frontend == .attached else {
            return statusText
        }
        if isOnHold { return "On Hold" }
        if isSpeaking { return "Speaking" }
        // Muted replaces only plain listening; the agent's progress still shows.
        if isMuted, statusText == Self.listening { return "Muted" }
        return statusText
    }

    private static let listening = "Listening"

    /// The chat input bar's call surface; nil once the call has let go of the composer.
    var composerCall: ComposerLiveVoiceCall? {
        guard holdsComposer else { return nil }
        return ComposerLiveVoiceCall(
            isLive: isLive,
            isConnecting: isLive && callState == nil,
            isMuted: isMuted,
            isSpeaking: isSpeaking,
            status: composerStatus,
            transcript: partialTranscript,
            meter: meter,
            onToggleMute: { [weak self] in self?.toggleMute() },
            onEnd: { [weak self] in Task { await self?.end() } }
        )
    }

    @ObservationIgnored private var channel: LiveVoiceCallChannel?
    @ObservationIgnored private var audio: LiveVoiceAudioOwning?
    @ObservationIgnored private var memory: LiveVoiceSessionMemory
    @ObservationIgnored private var serverKey: String
    @ObservationIgnored private var clientCallId: String
    @ObservationIgnored private var hasIssuedClientCallId = false
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var didConfirmCall = false
    @ObservationIgnored private var startSent = false
    /// The failure text of a call the server ended; `LiveVoiceSystemCall` reports it to the
    /// system as the other side hanging up, not as a failure.
    static let endedText = "Live Voice ended."
    /// CallKit activates and deactivates the audio session for a system call
    /// (`LiveVoiceSystemCall`); the call's audio then waits for `setAudioSessionActive(true)`
    /// and never activates or deactivates the session itself.
    @ObservationIgnored private var systemActivatesAudioSession = false
    @ObservationIgnored private var systemAudioSessionActive = false
    @ObservationIgnored private var pendingRequestId: String?
    /// Request id of an attach that rejoins a call (a remembered one, or this one after the
    /// stream reconnected). Until it answers the lease is unknown, so no keepalive goes out;
    /// if it fails the call is gone and a fresh one starts.
    @ObservationIgnored private var rejoinRequestId: String?
    /// End was pressed before the server confirmed the call: its late snapshot is ended.
    @ObservationIgnored private var endsOrphanedCall = false
    @ObservationIgnored private var startGeneration: UInt64 = 0
    @ObservationIgnored private var startWaiter: StartWaiter?
    @ObservationIgnored private var captureStarted = false

    private struct StartWaiter {
        let generation: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        channel: LiveVoiceCallChannel? = nil,
        audio: LiveVoiceAudioOwning? = nil,
        memory: LiveVoiceSessionMemory = UserDefaultsLiveVoiceSessionMemory(),
        serverKey: String = "default",
        clientCallId: String = UUID().uuidString,
        keepAliveInterval: Duration = .seconds(10)
    ) {
        self.keepAliveInterval = keepAliveInterval
        self.channel = channel
        self.audio = audio
        self.memory = memory
        self.serverKey = serverKey
        self.clientCallId = clientCallId
    }

    var isActive: Bool { isLive }

    /// End was pressed before the server confirmed the call; the end goes out when the
    /// confirmation arrives. Whoever replaces this controller keeps it until then.
    var isEndingUnconfirmedCall: Bool { endsOrphanedCall }

    func start(
        sessionId: String,
        routeScope: SessionRouteScope,
        using connection: ServerConnection
    ) async {
        // Without the microphone the call would start and send silence while showing "Listening".
        guard await Self.hasMicrophoneAccess() else {
            failClosed(
                "Oppi needs microphone access for Live Voice. Turn it on in Settings.",
                closeChannel: false
            )
            return
        }
        bind(connection, sessionId: sessionId)
        // A reply being read aloud would talk over the call.
        connection.audioPlayer.stop()
        await start(sessionId: sessionId, routeScope: routeScope)
    }

    func start(sessionId: String, routeScope: SessionRouteScope) async {
        guard let channel else {
            failClosed("Live Voice is not connected to a server.", closeChannel: false)
            return
        }

        startGeneration &+= 1
        let generation = startGeneration
        consumeTask?.cancel()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        audio?.stopPlayback()
        isSpeaking = false
        audio?.onPlaybackActiveChange = { [weak self] active in
            self?.isSpeaking = active
        }
        channel.onInboundAudio = { [weak self] data in
            guard let self, self.mayRunAudio else { return }
            self.audio?.play(data)
        }
        channel.close()
        endsOrphanedCall = false
        pendingRequestId = nil
        didConfirmCall = false
        rejoinRequestId = nil
        startSent = false
        callState = nil
        lastError = nil
        statusText = "Connecting"
        isLive = true
        prepareIdentityForNewStart()

        let stream = channel.open(sessionId: sessionId, routeScope: routeScope)
        await withCheckedContinuation { continuation in
            startWaiter = StartWaiter(generation: generation, continuation: continuation)
            consume(stream, generation: generation)
        }
        guard generation == startGeneration else { return }
        if !didConfirmCall {
            failClosed(lastError ?? "Live Voice stream is unavailable.", closeChannel: true)
        }
    }

    /// Ends the call for good. Only End, the server, or a dead link end a call: leaving its
    /// chat does not.
    func end() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil

        if let callState, callState.lifecycle == .active {
            invalidateStartWaiter()
            consumeTask?.cancel()
            await sendEnd(callState: callState)
            resetLocalCall()
            return
        }

        // Start was sent but the server has not confirmed a callId yet. Keep
        // the stream open so the late snapshot can be ended instead of orphaned.
        if startSent || pendingRequestId != nil {
            endsOrphanedCall = true
            isLive = false
            statusText = "Listening"
            invalidateStartWaiter()
            return
        }

        invalidateStartWaiter()
        consumeTask?.cancel()
        resetLocalCall()
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    /// Mute as the system asked for it (`LiveVoiceSystemCall`): its in-call UI or a headset.
    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        audio?.setMuted(muted)
    }

    // MARK: System call (CallKit)

    /// Who activates the audio session for the next start: CallKit for a system call, the
    /// call's own audio otherwise. A system call's session starts out inactive.
    func useSystemAudioSession(_ system: Bool) {
        systemActivatesAudioSession = system
        systemAudioSessionActive = false
    }

    /// CallKit activated (`provider(_:didActivate:)`) or took away (`didDeactivate`) the
    /// session. Audio runs only while it is active; the server call is not touched.
    func setAudioSessionActive(_ active: Bool) {
        systemAudioSessionActive = active
        updateAudioGate()
    }

    /// CallKit's hold: capture and playback stop without ending the call; unhold resumes them.
    func setOnHold(_ held: Bool) {
        guard isOnHold != held else { return }
        isOnHold = held
        updateAudioGate()
    }

    /// Whether the call's audio may run now: not on hold, and for a system call only while
    /// CallKit has the session active.
    private var mayRunAudio: Bool {
        !isOnHold && (!systemActivatesAudioSession || systemAudioSessionActive)
    }

    private func updateAudioGate() {
        guard mayRunAudio else {
            suspendCapture()
            return
        }
        guard isLive, callState?.lifecycle == .active, !captureStarted else { return }
        Task { [weak self] in
            // The gate may have closed again before this ran.
            guard let self, self.mayRunAudio, self.isLive, self.callState?.lifecycle == .active else { return }
            await self.startCaptureIfNeeded()
        }
    }

    func sendKeepAliveNow() async {
        guard let callState, callState.lifecycle == .active, rejoinRequestId == nil else { return }
        await send(
            .voiceCallKeepAlive(
                callId: callState.callId,
                controllerLeaseEpoch: callState.controllerLeaseEpoch,
                requestId: nextRequestId()
            )
        )
    }

    // nonisolated: the permission callback runs off the main actor (as in VoiceInputSystemAccess).
    nonisolated private static func hasMicrophoneAccess() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        return AVAudioApplication.shared.recordPermission == .granted
    }

    private func bind(_ connection: ServerConnection, sessionId: String) {
        channel = ServerConnectionLiveVoiceChannel(connection: connection)
        if audio == nil {
            audio = LiveVoiceAudioOwner(engine: LiveVoiceDuplexCaptureEngine(meter: meter))
        }
        let server = connection.credentials?.normalizedServerFingerprint
            ?? connection.credentials?.host
            ?? "default"
        // A remembered call belongs to the session it was started on.
        serverKey = "\(server).\(sessionId)"
    }

    private func consume(_ stream: AsyncStream<ServerMessage>, generation: UInt64) {
        consumeTask = Task { [weak self] in
            defer { self?.resumeStartWaiter(generation: generation) }
            for await message in stream {
                guard let self, !Task.isCancelled else { return }
                await self.handle(message, generation: generation)
            }
            // The stream finishes on its own only when the link is gone for good (device
            // revoked, auth refresh failed, session gone). Our own close paths cancel this
            // task, bump the generation, or clear isLive first. A pre-confirm finish is
            // start()'s to report (startWaiter is still set).
            guard let self, !Task.isCancelled, generation == self.startGeneration,
                  self.isLive, self.startWaiter == nil else { return }
            self.failClosed("Live Voice disconnected.", closeChannel: true)
        }
    }

    private func resumeStartWaiter(generation: UInt64) {
        guard let waiter = startWaiter, waiter.generation == generation else { return }
        startWaiter = nil
        waiter.continuation.resume()
    }

    private func handle(_ message: ServerMessage, generation: UInt64) async {
        if endsOrphanedCall {
            await handleOrphan(message)
            return
        }
        guard generation == startGeneration else { return }

        switch message {
        case .streamConnected:
            // A new socket: an attach sent on the old one will never be answered.
            rejoinRequestId = nil
            await sendJoinOrStart()
        case .voiceCallState(let snapshot):
            apply(snapshot)
            if snapshot.lifecycle == .active {
                await startCaptureIfNeeded()
                if isLive {
                    confirmStart(generation: generation)
                }
            } else if snapshot.lifecycle == .ended {
                memory.clearCallIdentity(forServer: serverKey)
                failClosed(Self.endedText, closeChannel: true)
            }
        case .commandResult(let command, let requestId, let success, _, let error):
            // The session's stream also carries other callers' command results (model, compact).
            guard command.hasPrefix("voice_") else { return }
            if requestId != nil, requestId == rejoinRequestId {
                rejoinRequestId = nil
                if !success {
                    // The call is gone (ended, or the server no longer has it). The user is
                    // on this call: start a new one instead of failing it.
                    forgetStoredCall()
                    await sendStart()
                    return
                }
            }
            if !success, command == "voice_call_keepalive" {
                // The lease moved on under us (a server restart or a reconnect re-attached
                // the call): rejoin it instead of hanging up.
                await rejoinCall()
                return
            }
            if !success {
                failClosed(error ?? "Live Voice failed.", closeChannel: true)
                return
            }
            if !didConfirmCall, requestId != nil, requestId == pendingRequestId {
                confirmStart(generation: generation)
            }
        case .error(let message, _, let fatal):
            // The call rides the session's own stream, which also carries the session's run
            // errors. Once the call is up, a failed run is the agent's to say out loud, not a
            // reason to hang up; a fatal error (the session is gone) ends the call.
            if didConfirmCall, !fatal { return }
            failClosed(message, closeChannel: true)
        case .voiceDelegationUpdate(let update):
            // Status only. Playback stops when the user talks (a new partial transcript);
            // an update must not cut off speech already playing.
            if !update.text.isEmpty {
                statusText = update.text
            }
        default:
            break
        }
    }

    private func apply(_ snapshot: VoiceCallStateSnapshot) {
        let previousPartial = callState?.partialTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextPartial = snapshot.partialTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        callState = snapshot
        if !nextPartial.isEmpty, nextPartial != previousPartial {
            audio?.stopPlayback()
        }
        if snapshot.lifecycle == .ended {
            isLive = false
            statusText = "Listening"
            keepAliveTask?.cancel()
            keepAliveTask = nil
            memory.clearCallIdentity(forServer: serverKey)
            return
        }
        isLive = true
        persistIdentity(from: snapshot)
        statusText = Self.statusText(for: snapshot)
        if keepAliveTask == nil {
            startKeepAlive(generation: startGeneration)
        }
    }

    private static func statusText(for snapshot: VoiceCallStateSnapshot) -> String {
        if snapshot.frontend == .detached {
            return "Reconnecting"
        }
        // The user talking now outranks any older outcome; their words fill the field.
        let partial = snapshot.partialTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !partial.isEmpty {
            return "Listening"
        }
        // Only the newest request's failure is news; a later request supersedes an old one.
        if let latest = snapshot.delegations.last, latest.state == .blocked,
           let text = latest.latestText, !text.isEmpty {
            return text
        }
        return "Listening"
    }

    private func startKeepAlive(generation: UInt64) {
        keepAliveTask?.cancel()
        let interval = keepAliveInterval
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, generation == self.startGeneration, !Task.isCancelled else { return }
                await self.sendKeepAliveNow()
            }
        }
    }

    private func invalidateStartWaiter() {
        let waiter = startWaiter
        startWaiter = nil
        startGeneration &+= 1
        waiter?.continuation.resume()
    }

    private func prepareIdentityForNewStart() {
        if let identity = memory.callIdentity(forServer: serverKey) {
            clientCallId = identity.clientCallId
            return
        }
        if hasIssuedClientCallId {
            clientCallId = UUID().uuidString
        }
        hasIssuedClientCallId = true
    }

    private func sendJoinOrStart() async {
        if let callState, callState.lifecycle == .active {
            await rejoinCall()
            return
        }
        if let identity = memory.callIdentity(forServer: serverKey) {
            clientCallId = identity.clientCallId
            await sendAttach(callId: identity.callId, lastEventSeq: identity.eventSeq)
            rejoinRequestId = pendingRequestId
            return
        }
        // A reconnect with the start already sent: its reply went down with the old socket.
        // The same clientCallId makes the resend idempotent on the server (it re-enters the
        // call the first start created, or creates it); a rejected resend fails the call.
        await sendStart()
    }

    private func rejoinCall() async {
        guard let callState, callState.lifecycle == .active, rejoinRequestId == nil else { return }
        await sendAttach(callId: callState.callId, lastEventSeq: callState.eventSeq)
        rejoinRequestId = pendingRequestId
    }

    private func forgetStoredCall() {
        memory.clearCallIdentity(forServer: serverKey)
        clientCallId = UUID().uuidString
    }

    private func sendStart() async {
        let requestId = nextRequestId()
        pendingRequestId = requestId
        startSent = true
        await send(.voiceCallStart(clientCallId: clientCallId, requestId: requestId))
    }

    private func sendAttach(callId: String, lastEventSeq: Int?) async {
        let requestId = nextRequestId()
        pendingRequestId = requestId
        await send(
            .voiceCallAttach(
                callId: callId,
                lastEventSeq: lastEventSeq,
                requestId: requestId
            )
        )
    }

    private func sendEnd(callState: VoiceCallStateSnapshot) async {
        let requestId = nextRequestId()
        pendingRequestId = requestId
        await send(
            .voiceCallEnd(
                callId: callState.callId,
                controllerLeaseEpoch: callState.controllerLeaseEpoch,
                requestId: requestId
            )
        )
    }

    private func handleOrphan(_ message: ServerMessage) async {
        switch message {
        case .streamConnected:
            // The socket dropped after the start (or attach) went out, so its snapshot will
            // never come. Ask again: the same clientCallId re-enters the call the first start
            // made, and the snapshot reaches the end this orphan is waiting to send.
            if startSent {
                await sendStart()
            } else if let identity = memory.callIdentity(forServer: serverKey) {
                await sendAttach(callId: identity.callId, lastEventSeq: identity.eventSeq)
            }
        case .voiceCallState(let snapshot):
            guard snapshot.lifecycle == .active else { return }
            endsOrphanedCall = false
            await sendEnd(callState: snapshot)
            resetLocalCall()
        case .commandResult(_, let requestId, let success, _, _):
            // The stream also carries other callers' results; only the orphan's own request
            // failing means there is no call to finish. The person already pressed End, so it
            // closes quietly with no error left on the composer.
            if !success, requestId != nil, requestId == pendingRequestId {
                resetLocalCall()
            }
        case .error(_, _, let fatal):
            // A run error on the session's stream is not about this call; a fatal one means the
            // session is gone, so the call cannot be finished.
            if fatal {
                resetLocalCall()
            }
        default:
            break
        }
    }

    private func confirmStart(generation: UInt64) {
        didConfirmCall = true
        // Every call state (each partial transcript while the user talks) confirms the call.
        // Restarting the timer here would starve the keepalive during long speech and let
        // the server's lease expire under a live call.
        if keepAliveTask == nil {
            startKeepAlive(generation: generation)
        }
        resumeStartWaiter(generation: generation)
    }

    private func persistIdentity(from snapshot: VoiceCallStateSnapshot) {
        memory.store(
            callIdentity: LiveVoiceCallIdentity(
                callId: snapshot.callId,
                clientCallId: clientCallId,
                eventSeq: snapshot.eventSeq
            ),
            forServer: serverKey
        )
    }

    private func startCaptureIfNeeded() async {
        guard let audio, !captureStarted, mayRunAudio else { return }
        captureStarted = true
        audio.systemActivatesSession = systemActivatesAudioSession
        audio.onPCM = { [weak self] data in
            Task { await self?.forwardAudio(data) }
        }
        do {
            try await audio.start()
            // A start (or a resume after hold) opens the mic; a muted call stays muted.
            if isMuted { audio.setMuted(true) }
        } catch {
            let activeCall = callState
            if let activeCall, activeCall.lifecycle == .active {
                await sendEnd(callState: activeCall)
            }
            memory.clearCallIdentity(forServer: serverKey)
            failClosed(error.localizedDescription, closeChannel: true)
        }
    }

    private func forwardAudio(_ pcm: Data) async {
        guard isLive, !isMuted, !pcm.isEmpty else { return }
        try? await channel?.sendAudio(pcm)
    }

    /// Hold, or the system took the audio session: stop the audio, keep the call.
    private func suspendCapture() {
        guard captureStarted else { return }
        captureStarted = false
        audio?.onPCM = nil
        audio?.suspend()
        isSpeaking = false
    }

    private func stopCapture() {
        captureStarted = false
        audio?.onPCM = nil
        audio?.stopPlayback()
        audio?.stop()
        isSpeaking = false
    }

    private func failClosed(_ message: String, closeChannel: Bool) {
        lastError = message
        isLive = false
        isMuted = false
        isOnHold = false
        statusText = message
        stopCapture()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        didConfirmCall = false
        startSent = false
        pendingRequestId = nil
        endsOrphanedCall = false
        rejoinRequestId = nil
        callState = nil
        if closeChannel {
            consumeTask?.cancel()
            channel?.close()
        }
        resumeStartWaiter(generation: startGeneration)
    }

    private func resetLocalCall() {
        memory.clearCallIdentity(forServer: serverKey)
        channel?.close()
        didConfirmCall = false
        startSent = false
        pendingRequestId = nil
        endsOrphanedCall = false
        rejoinRequestId = nil
        callState = nil
        lastError = nil
        isLive = false
        isMuted = false
        isOnHold = false
        statusText = "Listening"
        stopCapture()
    }

    private func send(_ message: ClientMessage) async {
        try? await channel?.send(message)
    }

    private func nextRequestId() -> String {
        UUID().uuidString
    }
}

/// The call's own stream to its session, from `ServerConnection.makeLiveVoiceWebSocketClient`.
/// The connection keeps no reference to it, so focusing another session, switching the active
/// server, or a chat releasing its stream leaves the call's socket alone.
@MainActor
final class ServerConnectionLiveVoiceChannel: LiveVoiceCallChannel {
    private let connection: ServerConnection
    private var client: WebSocketClient?
    private var consumeTask: Task<Void, Never>?
    var onInboundAudio: (@MainActor (Data) -> Void)?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func open(sessionId: String, routeScope: SessionRouteScope) -> AsyncStream<ServerMessage> {
        close()
        guard let client = connection.makeLiveVoiceWebSocketClient(
            sessionId: sessionId,
            routeScope: routeScope
        ) else {
            return AsyncStream { $0.finish() }
        }
        self.client = client
        client.onBinaryFrame = { [weak self] data in
            self?.onInboundAudio?(data)
        }
        let frames = client.connect()
        return AsyncStream { continuation in
            let task = Task {
                for await frame in frames {
                    continuation.yield(frame.message)
                }
                continuation.finish()
            }
            consumeTask = task
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func send(_ message: ClientMessage) async throws {
        try await client?.send(message)
    }

    func sendAudio(_ pcm: Data) async throws {
        try await client?.sendBinary(pcm)
    }

    func close() {
        consumeTask?.cancel()
        consumeTask = nil
        client?.disconnect()
        client = nil
    }
}

@MainActor
final class UserDefaultsLiveVoiceSessionMemory: LiveVoiceSessionMemory {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func callIdentity(forServer serverKey: String) -> LiveVoiceCallIdentity? {
        let prefix = callKeyPrefix(for: serverKey)
        guard let callId = defaults.string(forKey: prefix + ".callId")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !callId.isEmpty,
              let clientCallId = defaults.string(forKey: prefix + ".clientCallId")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientCallId.isEmpty else {
            return nil
        }
        return LiveVoiceCallIdentity(
            callId: callId,
            clientCallId: clientCallId,
            eventSeq: defaults.integer(forKey: prefix + ".eventSeq")
        )
    }

    func store(callIdentity: LiveVoiceCallIdentity, forServer serverKey: String) {
        let prefix = callKeyPrefix(for: serverKey)
        defaults.set(callIdentity.callId, forKey: prefix + ".callId")
        defaults.set(callIdentity.clientCallId, forKey: prefix + ".clientCallId")
        defaults.set(callIdentity.eventSeq, forKey: prefix + ".eventSeq")
    }

    func clearCallIdentity(forServer serverKey: String) {
        let prefix = callKeyPrefix(for: serverKey)
        defaults.removeObject(forKey: prefix + ".callId")
        defaults.removeObject(forKey: prefix + ".clientCallId")
        defaults.removeObject(forKey: prefix + ".eventSeq")
    }

    private func callKeyPrefix(for serverKey: String) -> String {
        "oppi.liveVoice.call.\(serverKey)"
    }
}
