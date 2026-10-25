import CallKit
import Foundation
import Testing
@testable import Oppi

/// A Live Voice call as a CallKit call: the system's call UI and the app's call drive each
/// other, and the system decides when the call's audio may run.
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
        await call.startTask?.value
        #expect(await waitForMainActorCondition { call.telephony.reports.contains(.connected(id)) })
        #expect(call.telephony.reports.filter { $0 == .connected(id) }.count == 1)
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

        #expect(await waitForMainActorCondition {
            call.telephony.requested.contains { ($0 as? CXEndCallAction)?.callUUID == id }
        })
        #expect(call.system.callId == nil)
        #expect(!call.telephony.reports.contains { if case .ended = $0 { true } else { false } })
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
        await call.startTask?.value

        #expect(call.telephony.reports.last == .ended(id, .failed))
        #expect(!call.telephony.reports.contains(.connected(id)))
        #expect(call.system.callId == nil)
    }

    @Test("The system's mute mutes the app's call without the app asking the system again")
    func systemMuteMutesApp() async throws {
        let call = SystemCallHarness()
        try await call.start()
        let id = try #require(call.system.callId)

        #expect(call.telephony.performSystem(.setMuted(call: id, muted: true, action: UUID())))
        #expect(call.controller.isMuted)
        call.audio.emit(Data([1, 2]))
        #expect(call.channel.sentAudio.isEmpty)

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            !call.telephony.requested.contains { $0 is CXSetMutedCallAction }
        })
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

    @Test("A system unmute that lands while the app's mute request is in flight wins, and the late echo is ignored")
    func systemMuteRacingAppRequest() async throws {
        let call = SystemCallHarness()
        try await call.start()
        let id = try #require(call.system.callId)
        call.telephony.performsRequests = false

        call.controller.toggleMute()
        #expect(await waitForMainActorCondition { call.muteRequests == [true] })
        // AirPods unmute before the system got to the app's request.
        #expect(call.telephony.performSystem(.setMuted(call: id, muted: false, action: UUID())))
        #expect(!call.controller.isMuted)
        call.telephony.performPendingRequests()

        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) {
            !call.controller.isMuted
        })
        #expect(call.muteRequests == [true])
    }

    @Test("Hold stops the mic and playback but keeps the server call and its keepalive; unhold resumes capture")
    func holdKeepsServerCall() async throws {
        let call = SystemCallHarness(keepAliveInterval: .milliseconds(30))
        try await call.start()
        let id = try #require(call.system.callId)
        #expect(call.audio.starts == 1)

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

@MainActor
private final class SystemCallHarness {
    let telephony = FakeLiveVoiceTelephony()
    let channel = FakeLiveVoiceCallChannel()
    let audio = FakeLiveVoiceAudioOwner()
    let controller: LiveVoiceCallController
    let system: LiveVoiceSystemCall
    private(set) var startTask: Task<Void, Never>?

    init(keepAliveInterval: Duration = .seconds(10)) {
        controller = LiveVoiceCallController(
            channel: channel,
            audio: audio,
            memory: FakeLiveVoiceSessionMemory(),
            serverKey: "server-1",
            clientCallId: "client-call-1",
            keepAliveInterval: keepAliveInterval
        )
        let telephony = telephony
        system = LiveVoiceSystemCall(
            telephony: { telephony },
            displayName: { _ in "Fix the build" },
            configureAudioSession: {}
        )
    }

    var muteRequests: [Bool] {
        telephony.requested.compactMap { ($0 as? CXSetMutedCallAction)?.isMuted }
    }

    var keepalives: Int {
        channel.sent.filter { $0.typeLabel == "voice_call_keepalive" }.count
    }

    /// Starts the call through the system call up to the server's start; CallKit activates
    /// the audio session first unless `activateAudio` is false.
    func start(confirm: Bool = true, activateAudio: Bool = true) async throws {
        let controller = controller
        let system = system
        startTask = Task {
            await system.start(controller, key: .init(serverId: "server-1", sessionId: "sess-1")) {
                await controller.start(sessionId: "sess-1", routeScope: .workspace("ws-1"))
            }
        }
        try #require(await waitForMainActorCondition { !channel.opened.isEmpty })
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        try #require(await waitForMainActorCondition { channel.sent.map(\.typeLabel) == ["voice_call_start"] })
        if activateAudio, system.callId != nil {
            telephony.events?.audioSessionDidActivate()
        }
        guard confirm else { return }
        self.confirm()
        await startTask?.value
        try #require(controller.isLive)
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
    private(set) var requested: [CXCallAction] = []
    private(set) var reports: [Report] = []
    private var pending: [CXCallAction] = []

    func request(_ action: CXCallAction) async throws {
        if action is CXStartCallAction, let startError { throw startError }
        requested.append(action)
        if performsRequests {
            _ = events?.perform(Self.systemAction(for: action))
        } else {
            pending.append(action)
        }
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
            .setMuted(call: mute.callUUID, muted: mute.isMuted, action: mute.uuid)
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
