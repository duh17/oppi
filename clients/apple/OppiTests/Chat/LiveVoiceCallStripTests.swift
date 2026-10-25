import Testing
import UIKit
@testable import Oppi

/// The app-wide call experience around one Live Voice call: the strip shows everywhere but
/// the call's own chat, End & Call moves the call to another session, and session rows mark
/// the call's session.
@Suite("Live Voice call strip")
@MainActor
struct LiveVoiceCallStripTests {
    private let serverId = "sha256:call-strip"

    // MARK: Strip

    @Test("The strip hides only while the call's own chat is on screen")
    func stripHidesOnlyOnTheCallsChat() async throws {
        let app = CallApp()
        let call = try await app.confirmedCall(sessionId: "a", serverId: serverId)
        let key = LiveVoiceCallCenter.CallKey(serverId: serverId, sessionId: "a")
        let current = try #require(app.center.currentCall)
        #expect(call === current.controller)

        func strip(_ shown: [LiveVoiceCallCenter.CallKey]) -> LiveVoiceCallStripContent? {
            LiveVoiceCallStripContent.make(call: current, shownChats: shown, sessionTitle: "Plan", titleIsHidden: false)
        }
        #expect(strip([])?.title == "Plan", "No chat on screen (a list, Settings, Files)")
        #expect(strip([LiveVoiceCallCenter.CallKey(serverId: serverId, sessionId: "b")]) != nil,
                "Another session's chat still shows the strip")
        #expect(strip([LiveVoiceCallCenter.CallKey(serverId: "sha256:other-server", sessionId: "a")]) != nil,
                "The same session id on another server is another session")
        #expect(strip([key]) == nil, "The call's own chat is the call surface")

        // The center follows chats as they come and go; two chats on one session (a stack
        // swap) keep the strip hidden until both left.
        let first = NSObject(), second = NSObject()
        app.center.chatAppeared(first, serverId: serverId, sessionId: "a")
        app.center.chatAppeared(second, serverId: serverId, sessionId: "a")
        app.center.chatDisappeared(first)
        #expect(strip(Array(app.center.shownChats.values)) == nil)
        app.center.chatDisappeared(second)
        #expect(strip(Array(app.center.shownChats.values)) != nil)
    }

    @Test("The strip shows the call's phase: connecting without a duration, live with one, failed with its reason until End")
    func stripFollowsTheCallsPhase() async throws {
        let app = CallApp()
        let call = try #require(app.center.placeCall(serverId: serverId, sessionId: "a"))
        let channel = try #require(app.channels.last)
        let start = Task { await call.start(sessionId: "a", routeScope: .workspace("ws")) }
        #expect(await waitForMainActorCondition { !channel.opened.isEmpty })
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        #expect(await waitForMainActorCondition { channel.sent.contains { $0.typeLabel == "voice_call_start" } })

        var strip = try #require(app.strip())
        #expect(strip.phase == .connecting)
        #expect(strip.status == "Connecting")
        #expect(strip.connectedAt == nil, "No duration before the server confirms the call")

        channel.emit(.voiceCallState(activeSnapshot(sessionId: "a")))
        await start.value
        strip = try #require(app.strip())
        #expect(strip.phase == .live)
        let connectedAt = try #require(strip.connectedAt)

        // A reconnect inside the call keeps counting from the first confirmation.
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        channel.emit(.voiceCallState(activeSnapshot(sessionId: "a", eventSeq: 2)))
        #expect(await waitForMainActorCondition { call.callState?.eventSeq == 2 })
        #expect(app.strip()?.connectedAt == connectedAt)

        call.toggleMute()
        #expect(app.strip()?.isMuted == true)
        #expect(app.strip()?.status == "Muted")

        channel.emit(.error(message: "Session ended on the server.", code: nil, fatal: true))
        #expect(await waitForMainActorCondition { !call.isLive })
        strip = try #require(app.strip(), "A failed call keeps the strip until End")
        #expect(strip.phase == .failed)
        #expect(strip.status == "Session ended on the server.")
        #expect(!strip.isMuted)
        #expect(strip.connectedAt == nil)
        #expect(call.connectedAt == nil)

        await call.end()
        #expect(app.strip() == nil, "End dismisses the failed call")
    }

    @Test("A locked server, workspace, or session keeps the session title out of the strip")
    func lockedTitleSaysLiveVoice() async throws {
        let client = APIClient(baseURL: try #require(URL(string: "http://127.0.0.1:1")), token: "sk_test", configuration: .ephemeral)
        let ready = try makeTestAppRoot(readyServerId: serverId, apiClient: client)
        let connection = try #require(ready.coordinator.connection(for: serverId))
        connection.sessionStore.upsert(makeTestSession(id: "a", workspaceId: "ws", name: "Salary review"))
        let app = CallApp()
        let root = makeTestAppRoot(coordinator: ready.coordinator, liveVoiceCalls: app.center)
        _ = try await app.confirmedCall(sessionId: "a", serverId: serverId)

        for scope in [
            ScopedLockScope.server(serverId: serverId),
            .workspace(serverId: serverId, workspaceId: "ws"),
            .session(serverId: serverId, sessionId: "a"),
        ] {
            let locks = try isolatedLocks()
            #expect(LiveVoiceCallStripContent.current(root: root, locks: locks)?.title == "Salary review")
            locks.lock(scope, workspaceId: "ws")
            #expect(LiveVoiceCallStripContent.current(root: root, locks: locks)?.title == "Live Voice", "Locked: \(scope)")
        }
    }

    // MARK: End & Call

    @Test("Another session's call is ended, finished, and replaced by this session's on End & Call")
    func endAndCallMovesTheCall() async throws {
        let app = CallApp()
        let first = try await app.confirmedCall(sessionId: "a", serverId: serverId)
        let firstChannel = try #require(app.channels.first)

        #expect(app.center.callStart(serverId: serverId, sessionId: "a") == .onThisCall)
        let a = LiveVoiceCallCenter.CallKey(serverId: serverId, sessionId: "a")
        #expect(app.center.callStart(serverId: serverId, sessionId: "b") == .endsCall(a))
        #expect(app.center.callStart(serverId: nil, sessionId: nil) == .endsCall(a), "A Quick Session meets the live call")
        #expect(app.center.placeCall(serverId: serverId, sessionId: "b") == nil, "No silent takeover without End & Call")
        #expect(app.center.currentCall?.controller === first)

        let second = try #require(await app.replaceCall(sessionId: "b", serverId: serverId, ending: a))
        #expect(firstChannel.sent.last?.typeLabel == "voice_call_end", "The first call is ended on the server")
        #expect(firstChannel.closed)
        #expect(!first.isLive)
        #expect(second !== first)
        // The new call went through the one start path: starting at once, holding the mic.
        #expect(second.isStarting)
        #expect(app.center.callStart(serverId: serverId, sessionId: "b") == .onThisCall)
        #expect(app.center.call(serverId: serverId, sessionId: "a") == nil)

        let secondChannel = app.channels[1]
        #expect(await waitForMainActorCondition { secondChannel.opened.map(\.sessionId) == ["b"] })
        secondChannel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        #expect(await waitForMainActorCondition { secondChannel.sent.contains { $0.typeLabel == "voice_call_start" } })
        secondChannel.emit(.voiceCallState(activeSnapshot(sessionId: "b")))
        #expect(await waitForMainActorCondition { second.connectedAt != nil })
        #expect(app.center.call(serverId: serverId, sessionId: "b") === second)
        #expect(app.center.callStart(serverId: serverId, sessionId: "a") == .endsCall(
            LiveVoiceCallCenter.CallKey(serverId: serverId, sessionId: "b")
        ))
    }

    @Test("End & Call ends a call still starting before it reaches the server, then starts this session's")
    func endAndCallEndsAStartingCall() async throws {
        let app = CallApp()
        app.microphone.holds = true
        let first = try #require(app.center.startCall(
            serverId: serverId, sessionId: "a", routeScope: .workspace("ws"), using: app.connection
        ))
        #expect(first.isStarting)
        #expect(app.center.callStart(serverId: serverId, sessionId: "b") == .endsCall(
            LiveVoiceCallCenter.CallKey(serverId: serverId, sessionId: "a")
        ), "A starting call is already the call")

        app.microphone.holds = false
        let second = try #require(await app.replaceCall(
            sessionId: "b",
            serverId: serverId,
            ending: LiveVoiceCallCenter.CallKey(serverId: serverId, sessionId: "a")
        ))
        #expect(!first.isStarting && !first.isLive)
        app.microphone.answerHeld()

        let firstChannel = app.channels[0]
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(150)) { firstChannel.opened.isEmpty },
                "The ended call never reaches the server")
        #expect(await waitForMainActorCondition { app.channels[1].opened.map(\.sessionId) == ["b"] })
        #expect(app.center.call(serverId: serverId, sessionId: "b") === second)
    }

    @Test("End & Call never ends a call other than the one the person agreed to end")
    func endAndCallLeavesADifferentCallAlone() async throws {
        let app = CallApp()
        let first = try await app.confirmedCall(sessionId: "a", serverId: serverId)
        let agreed = LiveVoiceCallCenter.CallKey(serverId: serverId, sessionId: "a")
        #expect(app.center.callStart(serverId: serverId, sessionId: "b") == .endsCall(agreed))

        // While the alert is up, that call ends and another session's call takes the mic.
        await first.end()
        let other = try await app.confirmedCall(sessionId: "c", serverId: serverId)
        let otherChannel = try #require(app.channels.last)

        #expect(await app.replaceCall(sessionId: "b", serverId: serverId, ending: agreed) == nil)
        #expect(other.isLive, "The call nobody agreed to end keeps running")
        #expect(!otherChannel.sent.contains { $0.typeLabel == "voice_call_end" })
        // The chat asks again, now naming that call.
        #expect(app.center.callStart(serverId: serverId, sessionId: "b") == .endsCall(
            LiveVoiceCallCenter.CallKey(serverId: serverId, sessionId: "c")
        ))
    }

    @Test("A failed call on another session is replaced without asking")
    func failedCallIsReplacedWithoutConfirmation() async throws {
        let app = CallApp()
        let first = try await app.confirmedCall(sessionId: "a", serverId: serverId)
        app.channels[0].emit(.error(message: "Gone", code: nil, fatal: true))
        #expect(await waitForMainActorCondition { !first.isLive })
        #expect(app.center.currentCall != nil, "The failure shows until End")
        #expect(app.center.callStart(serverId: serverId, sessionId: "b") == .available)
        let second = try #require(app.center.placeCall(serverId: serverId, sessionId: "b"))
        #expect(second !== first)
    }

    // MARK: Row badge

    @Test("Only the call's session row carries the badge, muted while the call is muted, gone once it ends")
    func rowBadgeFollowsTheCall() async throws {
        let app = CallApp()
        let call = try await app.confirmedCall(sessionId: "a", serverId: serverId)
        #expect(app.center.rowBadge(serverId: serverId, sessionId: "a") == .live)
        #expect(app.center.rowBadge(serverId: serverId, sessionId: "b") == nil)
        #expect(app.center.rowBadge(serverId: "sha256:elsewhere", sessionId: "a") == nil)
        call.toggleMute()
        #expect(app.center.rowBadge(serverId: serverId, sessionId: "a") == .muted)
        await call.end()
        #expect(app.center.rowBadge(serverId: serverId, sessionId: "a") == nil)
    }

    @Test("The session row speaks the call badge with the row")
    func rowSpeaksTheBadge() throws {
        let row = SessionRowView(combinesAccessibility: true)
        let window = makeSceneWindow()
        window.isHidden = false
        window.addSubview(row)
        row.frame = CGRect(x: 0, y: 0, width: 360, height: 80)
        defer { window.isHidden = true }
        let session = makeTestSession(id: "a", name: "Plan the strip")
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            pendingAskCount: 0,
            pendingAsk: nil,
            workspaceContext: nil,
            seenAt: nil,
            searchSnippet: nil,
            catalogModels: []
        )
        for (badge, spoken) in [
            (SessionRowCallBadge.live, "On a Live Voice call"),
            (.muted, "On a Live Voice call, muted"),
        ] {
            row.apply(
                SessionRowView.Content(presentation: presentation, callBadge: badge),
                display: SessionRowDisplay(),
                themeID: .dark,
                iconAssetCache: nil
            )
            row.layoutIfNeeded()
            let label = try #require(row.accessibilityLabel)
            #expect(label.contains(spoken), "Got \(label)")
            #expect(label.contains("muted") == (badge == .muted), "Got \(label)")
        }
        row.apply(SessionRowView.Content(presentation: presentation), display: SessionRowDisplay(), themeID: .dark, iconAssetCache: nil)
        #expect(row.accessibilityLabel?.contains("Live Voice") == false)
    }

    // MARK: Helpers

    private func isolatedLocks() throws -> ScopedLockService {
        let defaults = try #require(UserDefaults(suiteName: "LiveVoiceCallStripTests-\(UUID().uuidString)"))
        let appLock = AppLockService(
            defaults: defaults,
            monotonicNow: { 0 },
            availability: { .available },
            method: { .faceID },
            authenticator: { _ in .cancelled },
            didTurnOn: {},
            isProtectedDataAvailable: { true }
        )
        return ScopedLockService(defaults: defaults, appLock: appLock, didLock: { _ in }, isProtectedDataAvailable: { true })
    }
}

/// A call center whose every call talks to its own fake channel. Calls it starts run without
/// CallKit (the center's default system call).
@MainActor
private final class CallApp {
    private(set) var channels: [FakeLiveVoiceCallChannel] = []
    private(set) var center: LiveVoiceCallCenter!
    let microphone = MicrophoneGate()
    let connection = ServerConnection()

    init() {
        let microphone = microphone
        center = LiveVoiceCallCenter { [unowned self] in
            let channel = FakeLiveVoiceCallChannel()
            channels.append(channel)
            return LiveVoiceCallController(
                channel: channel,
                audio: FakeLiveVoiceAudioOwner(),
                memory: FakeLiveVoiceSessionMemory(),
                microphoneAccess: { await microphone.ask() }
            )
        }
    }

    /// End & Call, as the confirmation runs it.
    func replaceCall(
        sessionId: String,
        serverId: String,
        ending agreed: LiveVoiceCallCenter.CallKey
    ) async -> LiveVoiceCallController? {
        await center.replaceCall(
            serverId: serverId,
            sessionId: sessionId,
            ending: agreed,
            routeScope: .workspace("ws"),
            using: connection
        )
    }

    func strip() -> LiveVoiceCallStripContent? {
        LiveVoiceCallStripContent.make(
            call: center.currentCall,
            shownChats: Array(center.shownChats.values),
            sessionTitle: "Plan",
            titleIsHidden: false
        )
    }

    func confirmedCall(sessionId: String, serverId: String) async throws -> LiveVoiceCallController {
        let call = try #require(center.placeCall(serverId: serverId, sessionId: sessionId))
        let channel = try #require(channels.last)
        let start = Task { await call.start(sessionId: sessionId, routeScope: .workspace("ws")) }
        #expect(await waitForMainActorCondition { !channel.opened.isEmpty })
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        #expect(await waitForMainActorCondition { channel.sent.contains { $0.typeLabel == "voice_call_start" } })
        channel.emit(.voiceCallState(activeSnapshot(sessionId: sessionId)))
        await start.value
        try #require(call.isLive)
        return call
    }
}

/// Microphone access, granted; `holds` keeps the next answers waiting until `answerHeld`.
@MainActor
private final class MicrophoneGate {
    var holds = false
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    func ask() async -> Bool {
        guard holds else { return true }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func answerHeld() {
        let held = waiting
        waiting.removeAll()
        for continuation in held { continuation.resume(returning: true) }
    }
}

private func activeSnapshot(sessionId: String, eventSeq: Int = 1) -> VoiceCallStateSnapshot {
    VoiceCallStateSnapshot(
        callId: "call-\(sessionId)",
        controlSessionId: sessionId,
        lifecycle: .active,
        frontend: .attached,
        controllerLeaseEpoch: 1,
        controllerLeaseExpiresAt: 30_000,
        eventSeq: eventSeq,
        startedAt: 1_000,
        updatedAt: 2_000,
        delegations: [],
        partialTranscript: nil
    )
}
