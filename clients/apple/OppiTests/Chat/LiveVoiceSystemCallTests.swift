import CallKit
import Foundation
import Testing
@testable import Oppi

/// A Live Voice call as a CallKit call, started the way the app starts every call
/// (`LiveVoiceCallCenter.startCall`): the system's call UI and the app's call drive each other,
/// and the system decides when the call's audio may run.
@Suite("Live Voice system call")
@MainActor
struct LiveVoiceSystemCallTests {
    @Test("The system shows the call connecting at start and connected only once the server confirms it")
    func connectingThenConnected() async throws {
        let call = SystemCallHarness()
        try await call.start(confirm: false)
        let id = try #require(call.system.callId)
        #expect(call.telephony.reports == [.update(id, "Fix the build"), .connecting(id)])

        call.confirm()
        #expect(await waitForMainActorCondition { call.telephony.reports.contains(.connected(id)) })
        #expect(call.telephony.reports.filter { $0 == .connected(id) }.count == 1)
    }

    @Test("Denied microphone access fails the call with the reason and never shows a system call")
    func deniedMicrophoneShowsNoSystemCall() async throws {
        let call = SystemCallHarness()
        call.microphone.granted = false

        try #require(call.tap() != nil)

        #expect(await waitForMainActorCondition { call.controller.lastError != nil })
        #expect(call.telephony.requested.isEmpty)
        #expect(call.channel.opened.isEmpty)
        #expect(!call.center.ownsMicrophone)
    }

    @Test("From the tap the starting call holds the mic and shows Connecting; a second start is refused, and End during the permission prompt starts nothing")
    func startingCallHoldsTheMicAndEndsCleanly() async throws {
        let call = SystemCallHarness()
        call.microphone.holdsAnswer = true

        try #require(call.tap() != nil)

        #expect(call.controller.isStarting)
        #expect(call.center.ownsMicrophone)
        #expect(call.center.callStart(serverId: "server-1", sessionId: "sess-2") != .available)
        #expect(call.tap() == nil)
        #expect(call.controller.composerCall?.isConnecting == true)
        #expect(call.controller.composerStatus == "Connecting")

        await call.controller.end()
        call.microphone.answer()

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            call.telephony.requested.isEmpty && call.channel.opened.isEmpty
        })
        #expect(!call.controller.isStarting)
        #expect(!call.center.ownsMicrophone)
        #expect(call.controller.composerCall == nil)
    }

    @Test("A system End while the start request is in flight starts nothing on the server")
    func systemEndDuringStartRequestStartsNothing() async throws {
        let call = SystemCallHarness()
        call.telephony.holdsStartRequest = true

        try #require(call.tap() != nil)
        try #require(await waitForMainActorCondition { call.system.callId != nil && !call.telephony.requested.isEmpty })
        let id = try #require(call.system.callId)
        #expect(call.telephony.performSystem(.end(call: id)))
        call.telephony.releaseStartRequest()

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            call.channel.opened.isEmpty && !call.controller.isLive
        })
        #expect(!call.channel.sent.contains { $0.typeLabel == "voice_call_start" })
        #expect(!call.controller.isStarting)
        #expect(call.system.callId == nil)
    }

    @Test("A system End while the start request is in flight, then the request failing, starts no call without CallKit")
    func systemEndThenFailedStartRequestStartsNoFallback() async throws {
        let call = SystemCallHarness()
        call.telephony.holdsStartRequest = true

        try #require(call.tap() != nil)
        try #require(await waitForMainActorCondition { call.system.callId != nil && !call.telephony.requested.isEmpty })
        let id = try #require(call.system.callId)
        #expect(call.telephony.performSystem(.end(call: id)))
        call.telephony.releaseStartRequest(
            throwing: NSError(domain: CXErrorCodeRequestTransactionError.errorDomain, code: 1)
        )

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            call.channel.opened.isEmpty && !call.controller.isLive
        })
        #expect(!call.controller.isStarting)
        #expect(call.system.callId == nil)
    }

    @Test("The app's End while the start request is in flight hangs up the system call and starts nothing on the server")
    func appEndDuringStartRequestStartsNothing() async throws {
        let call = SystemCallHarness()
        call.telephony.holdsStartRequest = true

        try #require(call.tap() != nil)
        try #require(await waitForMainActorCondition { call.system.callId != nil && !call.telephony.requested.isEmpty })
        let id = try #require(call.system.callId)
        await call.controller.end()
        call.telephony.releaseStartRequest()

        #expect(await waitForMainActorCondition { call.endRequested(id) })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            call.channel.opened.isEmpty && !call.controller.isLive
        })
        #expect(!call.channel.sent.contains { $0.typeLabel == "voice_call_start" })
        #expect(!call.controller.isStarting)
        #expect(call.system.callId == nil)
    }

    @Test("The system's End ends the app's call on the server, and nothing is reported back")
    func systemEndEndsAppCall() async throws {
        let call = SystemCallHarness()
        try await call.start()
        let id = try #require(call.system.callId)

        #expect(call.telephony.performSystem(.end(call: id)))

        #expect(await waitForMainActorCondition { call.channel.sent.last?.typeLabel == "voice_call_end" })
        #expect(await waitForMainActorCondition { !call.controller.isLive })
        #expect(call.system.callId == nil)
        #expect(!call.telephony.reports.contains { if case .ended = $0 { true } else { false } })
        #expect(!call.telephony.requested.contains { $0 is CXEndCallAction })
    }

    @Test("The app's End hangs up the system call with an end action")
    func appEndRequestsEndAction() async throws {
        let call = SystemCallHarness()
        try await call.start()
        let id = try #require(call.system.callId)

        await call.controller.end()

        #expect(await waitForMainActorCondition { call.endRequested(id) })
        #expect(call.system.callId == nil)
        #expect(!call.telephony.reports.contains { if case .ended = $0 { true } else { false } })
    }

    @Test("Removing the call's server ends the system call with the app's call")
    func serverRemovalEndsSystemCall() async throws {
        let call = SystemCallHarness()
        try await call.start()
        let id = try #require(call.system.callId)

        await call.center.endCall(serverId: "server-1")

        #expect(!call.controller.isLive)
        #expect(await waitForMainActorCondition { call.endRequested(id) })
        #expect(call.system.callId == nil)
    }

    @Test("An End before the server confirms hangs up the system call at once, and the late confirmation does not bring it back")
    func endBeforeConfirmLeavesNoSystemCall() async throws {
        let call = SystemCallHarness()
        try await call.start(confirm: false)
        let id = try #require(call.system.callId)

        await call.controller.end()
        #expect(call.controller.isEndingUnconfirmedCall)
        #expect(await waitForMainActorCondition { call.endRequested(id) })
        #expect(call.system.callId == nil)

        // The server's late confirmation: the retiring call ends it on the server only.
        call.confirm()
        #expect(await waitForMainActorCondition { call.channel.sent.last?.typeLabel == "voice_call_end" })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(100)) {
            call.system.callId == nil && !call.telephony.reports.contains(.connected(id))
        })
    }

    @Test("A call whose audio session the system never activates fails with the reason instead of staying live and silent")
    func missingActivationFailsCall() async throws {
        let call = SystemCallHarness(activationTimeout: .milliseconds(400))
        try await call.start(activateAudio: false)
        let id = try #require(call.system.callId)
        #expect(call.controller.isLive)

        #expect(await waitForMainActorCondition { !call.controller.isLive })
        #expect(call.controller.lastError == LiveVoiceSystemCall.noAudioText)
        #expect(call.channel.sent.last?.typeLabel == "voice_call_end", "The server call ends too")
        #expect(call.telephony.reports.filter { if case .ended = $0 { true } else { false } } == [.ended(id, .failed)])
        #expect(!call.telephony.requested.contains { $0 is CXEndCallAction })
        #expect(call.audio.starts == 0)
    }

    @Test("The no-audio reason stays on the call surface through the server's late confirmation, until End")
    func noAudioReasonOutlivesLateConfirmation() async throws {
        let call = SystemCallHarness(activationTimeout: .milliseconds(300))
        try await call.start(confirm: false, activateAudio: false)

        #expect(await waitForMainActorCondition { call.controller.lastError == LiveVoiceSystemCall.noAudioText })
        call.confirm()
        #expect(await waitForMainActorCondition { call.channel.sent.last?.typeLabel == "voice_call_end" })
        #expect(call.controller.lastError == LiveVoiceSystemCall.noAudioText)
        #expect(call.controller.composerCall != nil)

        await call.controller.end()
        #expect(call.controller.lastError == nil)
        #expect(call.controller.composerCall == nil)
    }

    @Test("A held call never fails for having no audio; after unhold the system must give the session back")
    func holdPausesTheNoAudioDeadline() async throws {
        let call = SystemCallHarness(activationTimeout: .milliseconds(200))
        try await call.start()
        let id = try #require(call.system.callId)

        #expect(call.telephony.performSystem(.setHeld(call: id, onHold: true)))
        call.telephony.events?.audioSessionDidDeactivate()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) { call.controller.isLive })

        #expect(call.telephony.performSystem(.setHeld(call: id, onHold: false)))
        #expect(await waitForMainActorCondition { call.controller.lastError == LiveVoiceSystemCall.noAudioText })
        #expect(call.telephony.reports.last == .ended(id, .failed))
    }

    @Test("A call the server ended is reported as the other side hanging up, a dropped link as failed",
          arguments: [EndCause.serverEnded, .linkDropped])
    func appSideEndsReportReason(cause: EndCause) async throws {
        let call = SystemCallHarness()
        try await call.start()
        let id = try #require(call.system.callId)

        switch cause {
        case .serverEnded:
            call.channel.emit(.voiceCallState(liveVoiceSnapshot(lifecycle: .ended)))
        case .linkDropped:
            call.channel.finishStream()
        }

        let reason: CXCallEndedReason = cause == .serverEnded ? .remoteEnded : .failed
        #expect(await waitForMainActorCondition { call.telephony.reports.contains(.ended(id, reason)) })
        #expect(!call.controller.isLive)
        #expect(call.system.callId == nil)
        #expect(!call.telephony.requested.contains { $0 is CXEndCallAction })
    }

    @Test("A call that fails before the server confirms it ends the system call as failed")
    func failedStartReportsFailed() async throws {
        let call = SystemCallHarness()
        try await call.start(confirm: false)
        let id = try #require(call.system.callId)

        call.channel.emit(.commandResult(
            command: "voice_call_start",
            requestId: nil,
            success: false,
            data: nil,
            error: "Voice backend is unavailable"
        ))

        #expect(await waitForMainActorCondition { call.telephony.reports.last == .ended(id, .failed) })
        #expect(!call.telephony.reports.contains(.connected(id)))
        #expect(call.system.callId == nil)
    }

    @Test("The system's mute mutes the app's call without the app asking the system again")
    func systemMuteMutesApp() async throws {
        let call = SystemCallHarness()
        try await call.start()
        let id = try #require(call.system.callId)

        #expect(call.telephony.performSystem(.setMuted(call: id, muted: true)))
        #expect(call.controller.isMuted)
        call.audio.emit(Data([1, 2]))
        #expect(call.channel.sentAudio.isEmpty)

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) { call.muteRequests.isEmpty })
    }

    @Test("The app's mute asks the system once, and the system performing that request changes nothing")
    func appMuteRequestsSystemMuteOnce() async throws {
        let call = SystemCallHarness()
        try await call.start()

        call.controller.toggleMute()

        #expect(await waitForMainActorCondition { call.muteRequests == [true] })
        #expect(call.controller.isMuted)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            call.muteRequests == [true] && call.controller.isMuted
        })
    }

    @Test("When the app's mute request and a system unmute cross, both sides end in the last mute the system performed")
    func crossingMutesSettleOnTheLastPerformed() async throws {
        let call = SystemCallHarness()
        try await call.start()
        let id = try #require(call.system.callId)
        call.telephony.performsRequests = false

        call.controller.toggleMute()
        #expect(await waitForMainActorCondition { call.muteRequests == [true] })
        // AirPods unmute before the system got to the app's request, which it performs last.
        #expect(call.telephony.performSystem(.setMuted(call: id, muted: false)))
        #expect(!call.controller.isMuted)
        call.telephony.performPendingRequests()

        #expect(call.controller.isMuted, "The system's last performed mute was the app's: muted")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            call.controller.isMuted && call.muteRequests == [true]
        })
    }

    @Test("Hold stops the mic and playback but keeps the server call and its keepalive; unhold resumes capture")
    func holdKeepsServerCall() async throws {
        let call = SystemCallHarness(keepAliveInterval: .milliseconds(30))
        try await call.start()
        let id = try #require(call.system.callId)
        #expect(await waitForMainActorCondition { call.audio.starts == 1 })

        #expect(call.telephony.performSystem(.setHeld(call: id, onHold: true)))
        call.telephony.events?.audioSessionDidDeactivate()

        #expect(call.audio.suspends == 1)
        #expect(call.controller.isLive)
        #expect(call.controller.isOnHold)
        call.audio.emit(Data([1, 2]))
        call.channel.emitAudio(Data([3, 4]))
        #expect(call.channel.sentAudio.isEmpty)
        #expect(call.audio.played.isEmpty)
        let keepalivesBefore = call.keepalives
        #expect(await waitForMainActorCondition { call.keepalives > keepalivesBefore + 1 })
        #expect(!call.channel.closed)
        #expect(!call.channel.sent.contains { $0.typeLabel == "voice_call_end" })

        #expect(call.telephony.performSystem(.setHeld(call: id, onHold: false)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.audio.starts == 1, "No capture until the system gives the audio session back")
        call.telephony.events?.audioSessionDidActivate()

        #expect(await waitForMainActorCondition { call.audio.starts == 2 })
        #expect(!call.controller.isOnHold)
        call.audio.emit(Data([5, 6]))
        #expect(await waitForMainActorCondition { call.channel.sentAudio == [Data([5, 6])] })
    }

    @Test("Capture waits for CallKit to activate the audio session, which the call's audio never activates itself")
    func captureWaitsForSystemActivation() async throws {
        let call = SystemCallHarness()
        try await call.start(activateAudio: false)
        #expect(call.controller.isLive)
        #expect(call.audio.starts == 0)

        call.telephony.events?.audioSessionDidActivate()

        #expect(await waitForMainActorCondition { call.audio.starts == 1 })
        #expect(call.audio.startedWithSystemSession == [true])
    }

    @Test("When CallKit refuses the start, the call starts without it and activates its own audio")
    func refusedStartFallsBack() async throws {
        let call = SystemCallHarness()
        call.telephony.startError = NSError(domain: CXErrorCodeRequestTransactionError.errorDomain, code: 1)
        try await call.start(activateAudio: false)

        #expect(call.controller.isLive)
        #expect(call.system.callId == nil)
        #expect(await waitForMainActorCondition { call.audio.starts == 1 })
        #expect(call.audio.startedWithSystemSession == [false])

        await call.controller.end()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(100)) {
            call.telephony.reports.isEmpty && call.telephony.requested.isEmpty
        })
    }

    @Test("The system UI names a session behind a scoped lock Live Voice, and any other by its title")
    func lockedSessionIsNotNamed() throws {
        let defaults = try #require(UserDefaults(suiteName: "LiveVoiceSystemCallTests-\(UUID().uuidString)"))
        let appLock = AppLockService(
            defaults: defaults, availability: { .available }, method: { .faceID },
            authenticator: { _ in .success }, didTurnOn: {}, isProtectedDataAvailable: { true }
        )
        let locks = ScopedLockService(defaults: defaults, appLock: appLock, didLock: { _ in }, isProtectedDataAvailable: { true })
        let session = makeTestSession(id: "sess-1", workspaceId: "ws-1", name: "Fix the build")
        let key = LiveVoiceCallCenter.CallKey(serverId: "server-1", sessionId: "sess-1")

        #expect(LiveVoiceSystemCall.displayName(for: key, locks: locks, session: session) == "Fix the build")
        locks.lock(.workspace(serverId: "server-1", workspaceId: "ws-1"))
        #expect(LiveVoiceSystemCall.displayName(for: key, locks: locks, session: session) == "Live Voice")
    }
}

enum EndCause: Sendable {
    case serverEnded
    case linkDropped
}

/// The microphone permission answer, optionally held while the prompt would be up.
@MainActor
private final class FakeMicrophoneAccess {
    var granted = true
    var holdsAnswer = false
    private var waiting: CheckedContinuation<Void, Never>?

    func ask() async -> Bool {
        if holdsAnswer {
            await withCheckedContinuation { waiting = $0 }
        }
        return granted
    }

    func answer() {
        holdsAnswer = false
        waiting?.resume()
        waiting = nil
    }
}

@MainActor
private final class SystemCallHarness {
    let telephony = FakeLiveVoiceTelephony()
    let channel = FakeLiveVoiceCallChannel()
    let audio = FakeLiveVoiceAudioOwner()
    let microphone = FakeMicrophoneAccess()
    let connection = ServerConnection()
    let controller: LiveVoiceCallController
    let system: LiveVoiceSystemCall
    /// The app's call center, whose one controller is `controller`.
    let center: LiveVoiceCallCenter

    init(keepAliveInterval: Duration = .seconds(10), activationTimeout: Duration = .seconds(5)) {
        let microphone = microphone
        let controller = LiveVoiceCallController(
            channel: channel,
            audio: audio,
            memory: FakeLiveVoiceSessionMemory(),
            serverKey: "server-1",
            clientCallId: "client-call-1",
            keepAliveInterval: keepAliveInterval,
            microphoneAccess: { await microphone.ask() }
        )
        self.controller = controller
        let telephony = telephony
        system = LiveVoiceSystemCall(
            telephony: { telephony },
            displayName: { _ in "Fix the build" },
            configureAudioSession: {},
            activationTimeout: activationTimeout
        )
        center = LiveVoiceCallCenter(systemCall: system) { controller }
    }

    var muteRequests: [Bool] {
        telephony.requested.compactMap { ($0 as? CXSetMutedCallAction)?.isMuted }
    }

    var keepalives: Int {
        channel.sent.filter { $0.typeLabel == "voice_call_keepalive" }.count
    }

    func endRequested(_ id: UUID) -> Bool {
        telephony.requested.contains { ($0 as? CXEndCallAction)?.callUUID == id }
    }

    /// The Live Voice tap: the app's one start path.
    @discardableResult
    func tap() -> LiveVoiceCallController? {
        center.startCall(serverId: "server-1", sessionId: "sess-1", routeScope: .workspace("ws-1"), using: connection)
    }

    /// Taps Live Voice and runs the call up to the server's start; CallKit activates the audio
    /// session first unless `activateAudio` is false, and the server confirms unless `confirm`
    /// is false.
    func start(confirm: Bool = true, activateAudio: Bool = true) async throws {
        try #require(tap() != nil)
        try #require(await waitForMainActorCondition { !channel.opened.isEmpty })
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        try #require(await waitForMainActorCondition { channel.sent.map(\.typeLabel) == ["voice_call_start"] })
        if activateAudio, system.callId != nil {
            telephony.events?.audioSessionDidActivate()
        }
        guard confirm else { return }
        self.confirm()
        try #require(await waitForMainActorCondition { controller.isLive && controller.callState?.lifecycle == .active })
    }

    func confirm() {
        channel.emit(.voiceCallState(liveVoiceSnapshot(lifecycle: .active)))
    }
}

/// CallKit as the app sees it: requests are performed right away unless `performsRequests`
/// is off, as the provider would after the system accepts them.
@MainActor
private final class FakeLiveVoiceTelephony: LiveVoiceTelephony {
    enum Report: Equatable {
        case connecting(UUID)
        case connected(UUID)
        case update(UUID, String)
        case ended(UUID, CXCallEndedReason)
    }

    weak var events: LiveVoiceTelephonyEvents?
    var startError: Error?
    var performsRequests = true
    /// The start request returns (or throws) only on `releaseStartRequest`, after the system
    /// performed it.
    var holdsStartRequest = false
    private(set) var requested: [CXCallAction] = []
    private(set) var reports: [Report] = []
    private var pending: [CXCallAction] = []
    private var heldStart: CheckedContinuation<Void, Error>?

    func request(_ action: CXCallAction) async throws {
        if action is CXStartCallAction, let startError { throw startError }
        requested.append(action)
        if performsRequests {
            _ = events?.perform(Self.systemAction(for: action))
        } else {
            pending.append(action)
        }
        if action is CXStartCallAction, holdsStartRequest {
            try await withCheckedThrowingContinuation { heldStart = $0 }
        }
    }

    func releaseStartRequest(throwing error: Error? = nil) {
        if let error {
            heldStart?.resume(throwing: error)
        } else {
            heldStart?.resume()
        }
        heldStart = nil
    }

    /// The system performing an action it started (its UI, a headset, another call).
    func performSystem(_ action: LiveVoiceSystemAction) -> Bool {
        events?.perform(action) ?? false
    }

    func performPendingRequests() {
        let actions = pending
        pending.removeAll()
        for action in actions { _ = events?.perform(Self.systemAction(for: action)) }
    }

    func reportConnecting(call: UUID) { reports.append(.connecting(call)) }
    func reportConnected(call: UUID) { reports.append(.connected(call)) }
    func reportUpdate(call: UUID, displayName: String) { reports.append(.update(call, displayName)) }
    func reportEnded(call: UUID, reason: CXCallEndedReason) { reports.append(.ended(call, reason)) }

    private static func systemAction(for action: CXCallAction) -> LiveVoiceSystemAction {
        switch action {
        case let mute as CXSetMutedCallAction:
            .setMuted(call: mute.callUUID, muted: mute.isMuted)
        case let hold as CXSetHeldCallAction:
            .setHeld(call: hold.callUUID, onHold: hold.isOnHold)
        case is CXEndCallAction:
            .end(call: action.callUUID)
        default:
            .start(call: action.callUUID)
        }
    }
}

private func liveVoiceSnapshot(lifecycle: VoiceCallLifecycleState) -> VoiceCallStateSnapshot {
    VoiceCallStateSnapshot(
        callId: "call-1",
        controlSessionId: "sess-1",
        lifecycle: lifecycle,
        frontend: .attached,
        controllerLeaseEpoch: 1,
        controllerLeaseExpiresAt: 30_000,
        eventSeq: 1,
        startedAt: 1_000,
        updatedAt: 2_000,
        delegations: [],
        partialTranscript: nil
    )
}
