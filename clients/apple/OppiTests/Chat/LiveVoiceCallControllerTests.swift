import Foundation
import Testing
@testable import Oppi

@Suite("LiveVoiceCallController")
@MainActor
struct LiveVoiceCallControllerTests {
    @Test("Start opens a call stream on the chat's session and starts the call")
    func startOpensChatSessionStreamAndStartsCall() async throws {
        let channel = FakeLiveVoiceCallChannel()
        let controller = LiveVoiceCallController(
            channel: channel,
            memory: FakeLiveVoiceSessionMemory(),
            serverKey: "server-1",
            clientCallId: "client-call-1"
        )

        let startTask = Task { await controller.start(sessionId: "sess-1", routeScope: .workspace("ws-1")) }
        await waitUntil { !channel.opened.isEmpty }
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(channel.sent) == ["voice_call_start"] }
        channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 1, leaseEpoch: 1)))
        await startTask.value

        #expect(channel.opened == [OpenedStream(sessionId: "sess-1", routeScope: .workspace("ws-1"))])
        #expect(controller.isLive)
        #expect(sentTypes(channel.sent) == ["voice_call_start"])
        #expect(startPayload(channel.sent.first) == "client-call-1")
        #expect(!containsDeviceId(channel.sent.first))
    }

    @Test("A remembered call the server rejects is replaced by a new call, not an error")
    func rejectedStoredCallStartsFresh() async throws {
        let app = relaunched(after: try await startedHarness())

        let restart = Task { await app.controller.start(sessionId: "sess-1", routeScope: .workspace("ws-1")) }
        await waitUntil { !app.channel.opened.isEmpty }
        app.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(app.channel.sent).contains("voice_call_attach") }
        let attach = app.channel.sent.last { $0.typeLabel == "voice_call_attach" }
        app.channel.emit(.commandResult(
            command: "voice_call_attach",
            requestId: requestId(of: attach),
            success: false,
            data: nil,
            error: "Voice call has ended"
        ))
        await waitUntil { sentTypes(app.channel.sent).last == "voice_call_start" }
        app.channel.emit(.voiceCallState(Self.snapshot(callId: "call-2", eventSeq: 1, leaseEpoch: 1)))
        await restart.value

        #expect(app.controller.isLive)
        #expect(app.controller.callState?.callId == "call-2")
        #expect(app.controller.lastError == nil)
    }

    @Test("Reconnect attaches the existing call instead of starting another")
    func reconnectAttachesExistingCall() async throws {
        let harness = try await startedHarness()
        harness.channel.emit(
            .voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 4, leaseEpoch: 2))
        )
        await waitUntil { harness.controller.callState?.callId == "call-1" }

        harness.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(harness.channel.sent).contains("voice_call_attach") }

        #expect(sentTypes(harness.channel.sent) == ["voice_call_start", "voice_call_attach"])
        let attached = attachPayload(harness.channel.sent.last)
        #expect(attached?.0 == "call-1")
        #expect(attached?.1 == 4)
        #expect(!containsDeviceId(harness.channel.sent.last))
    }

    @Test("After a reconnect no keepalive goes out until the call is rejoined")
    func reconnectHoldsKeepaliveUntilRejoined() async throws {
        let harness = try await startedHarness()
        harness.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(harness.channel.sent).contains("voice_call_attach") }
        let attach = harness.channel.sent.last { $0.typeLabel == "voice_call_attach" }

        await harness.controller.sendKeepAliveNow()
        #expect(!sentTypes(harness.channel.sent).contains("voice_call_keepalive"))

        harness.channel.emit(.commandResult(
            command: "voice_call_attach",
            requestId: requestId(of: attach),
            success: true,
            data: nil,
            error: nil
        ))
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 3, leaseEpoch: 2)))
        await waitUntil { harness.controller.callState?.controllerLeaseEpoch == 2 }
        await harness.controller.sendKeepAliveNow()
        #expect(leasePayload(harness.channel.sent.last)?.1 == 2)
    }

    @Test("A keepalive rejected after a server restart rejoins the call instead of hanging up")
    func staleKeepaliveRejoins() async throws {
        let harness = try await startedHarness()
        await harness.controller.sendKeepAliveNow()
        let keepalive = harness.channel.sent.last { $0.typeLabel == "voice_call_keepalive" }

        harness.channel.emit(.commandResult(
            command: "voice_call_keepalive",
            requestId: requestId(of: keepalive),
            success: false,
            data: nil,
            error: "Stale voice controller lease"
        ))
        await waitUntil { sentTypes(harness.channel.sent).last == "voice_call_attach" }

        #expect(harness.controller.isLive)
        #expect(harness.controller.lastError == nil)
        #expect(!harness.channel.closed)
        #expect(attachPayload(harness.channel.sent.last)?.0 == "call-1")
    }

    @Test("An old stopped request does not hide what the user is saying now")
    func oldBlockedRequestDoesNotStick() async throws {
        let harness = try await startedHarness()
        let stopped = Self.delegation("d-1", .blocked, "Stopped.")

        harness.channel.emit(.voiceCallState(Self.snapshot(
            callId: "call-1", eventSeq: 2, leaseEpoch: 1, delegations: [stopped]
        )))
        await waitUntil { harness.controller.statusText == "Stopped." }

        harness.channel.emit(.voiceCallState(Self.snapshot(
            callId: "call-1", eventSeq: 3, leaseEpoch: 1,
            partialTranscript: "check the server tests", delegations: [stopped]
        )))
        await waitUntil { harness.controller.partialTranscript == "check the server tests" }
        #expect(harness.controller.statusText == "Listening")

        harness.channel.emit(.voiceCallState(Self.snapshot(
            callId: "call-1", eventSeq: 4, leaseEpoch: 1,
            delegations: [stopped, Self.delegation("d-2", .completed, "All passed.")]
        )))
        await waitUntil { harness.controller.callState?.eventSeq == 4 }
        #expect(harness.controller.statusText == "Listening")
    }

    @Test("Keepalive uses the current lease and never invents a device id")
    func keepaliveUsesCurrentLease() async throws {
        let harness = try await startedHarness()
        harness.channel.emit(
            .voiceCallState(Self.snapshot(callId: "call-9", eventSeq: 1, leaseEpoch: 7))
        )
        await waitUntil { harness.controller.callState?.controllerLeaseEpoch == 7 }

        await harness.controller.sendKeepAliveNow()

        #expect(sentTypes(harness.channel.sent).last == "voice_call_keepalive")
        let keepalive = leasePayload(harness.channel.sent.last)
        #expect(keepalive?.0 == "call-9")
        #expect(keepalive?.1 == 7)
        #expect(!containsDeviceId(harness.channel.sent.last))
    }

    @Test("Keepalive keeps its cadence while the user talks and call states stream in")
    func keepaliveSurvivesStreamingCallStates() async throws {
        let harness = try await startedHarness(keepAliveInterval: .milliseconds(100))

        // Partial transcripts arrive as call states far faster than the keepalive interval.
        for seq in 2...25 {
            harness.channel.emit(.voiceCallState(
                Self.snapshot(callId: "call-1", eventSeq: seq, leaseEpoch: 1, partialTranscript: "word \(seq)")
            ))
            try await Task.sleep(for: .milliseconds(30))
        }

        let keepalives = sentTypes(harness.channel.sent).filter { $0 == "voice_call_keepalive" }
        #expect(keepalives.count >= 3)
    }

    @Test("End ends the call and restores the composer")
    func endEndsCall() async throws {
        let harness = try await startedHarness()
        harness.channel.emit(
            .voiceCallState(Self.snapshot(callId: "call-end", eventSeq: 3, leaseEpoch: 1))
        )
        await waitUntil { harness.controller.callState?.callId == "call-end" }

        await harness.controller.end()

        #expect(sentTypes(harness.channel.sent).last == "voice_call_end")
        let ended = leasePayload(harness.channel.sent.last)
        #expect(ended?.0 == "call-end")
        #expect(ended?.1 == 1)
        #expect(harness.channel.closed)
        #expect(!harness.controller.isLive)
    }

    @Test("Mute stops Live Voice capture and drops PCM")
    func muteStopsCapture() async throws {
        let harness = try await startedHarness()
        #expect(harness.audio.isCapturing)
        #expect(!harness.audio.openedDictationStream)

        harness.audio.emit(Data([1, 2, 3, 4]))
        await waitUntil { !harness.channel.sentAudio.isEmpty }
        #expect(harness.channel.sentAudio == [Data([1, 2, 3, 4])])

        harness.controller.toggleMute()
        #expect(harness.controller.isMuted)
        #expect(!harness.audio.isCapturing)

        harness.audio.emit(Data([9, 9]))
        await Task.yield()
        #expect(harness.channel.sentAudio == [Data([1, 2, 3, 4])])
        #expect(sentTypes(harness.channel.sent) == ["voice_call_start"])
    }

    @Test("Partial Yuwp transcripts reach the composer without a client dictation stream, and clear once sent")
    func partialTranscriptUpdatesComposer() async throws {
        let harness = try await startedHarness()
        harness.channel.emit(
            .voiceCallState(
                Self.snapshot(callId: "call-1", eventSeq: 2, leaseEpoch: 1, partialTranscript: "  list open ")
            )
        )
        await waitUntil { harness.controller.partialTranscript == "list open" }
        #expect(harness.controller.composerStatus == "Listening")
        #expect(harness.controller.isLive)
        #expect(!harness.audio.openedDictationStream)

        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 3, leaseEpoch: 1)))
        await waitUntil { harness.controller.callState?.eventSeq == 3 }
        #expect(harness.controller.partialTranscript.isEmpty)
    }

    @Test("The composer says Speaking while the reply plays and Muted while muted, unless a dropped link needs saying")
    func composerStatusFollowsPlayback() async throws {
        let harness = try await startedHarness()
        #expect(harness.controller.composerStatus == "Listening")

        harness.audio.setPlaybackActive(true)
        #expect(harness.controller.isSpeaking)
        #expect(harness.controller.composerStatus == "Speaking")

        harness.channel.emit(.voiceCallState(Self.snapshot(
            callId: "call-1", eventSeq: 4, leaseEpoch: 1, frontend: .detached
        )))
        await waitUntil { harness.controller.callState?.eventSeq == 4 }
        #expect(harness.controller.composerStatus == "Reconnecting")

        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 5, leaseEpoch: 1)))
        await waitUntil { harness.controller.callState?.eventSeq == 5 }
        #expect(harness.controller.composerStatus == "Speaking")
        harness.audio.setPlaybackActive(false)
        #expect(harness.controller.composerStatus == "Listening")
        harness.controller.toggleMute()
        #expect(harness.controller.composerStatus == "Muted")
        harness.controller.toggleMute()

        harness.audio.setPlaybackActive(true)
        await harness.controller.end()
        #expect(!harness.controller.isSpeaking)
    }

    @Test("User partial transcript flushes leftover scheduled playback")
    func userPartialFlushesPlayback() async throws {
        let harness = try await startedHarness()
        harness.channel.emitAudio(Data([1]))
        await waitUntil { harness.audio.played == [Data([1])] }
        let stopsBefore = harness.audio.playbackStops

        harness.channel.emit(
            .voiceCallState(
                Self.snapshot(callId: "call-1", eventSeq: 2, leaseEpoch: 1, partialTranscript: "stop")
            )
        )
        await waitUntil { harness.audio.playbackStops > stopsBefore }

        #expect(harness.controller.isLive)
        #expect(harness.controller.partialTranscript == "stop")
        #expect(harness.audio.isCapturing)
        #expect(!harness.controller.isMuted)
    }

    @Test("Voice call state without a user partial leaves playback scheduled")
    func stateWithoutPartialDoesNotFlushPlayback() async throws {
        let harness = try await startedHarness()
        let stopsBefore = harness.audio.playbackStops
        harness.channel.emitAudio(Data([1]))
        await waitUntil { harness.audio.played == [Data([1])] }

        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 2, leaseEpoch: 1)))
        await waitUntil { harness.controller.callState?.eventSeq == 2 }

        #expect(harness.audio.playbackStops == stopsBefore)
        #expect(harness.controller.isLive)
        #expect(harness.audio.isCapturing)
    }

    @Test("Capture failure keeps the bar showing the error until End, and still ends the call")
    func captureFailureFailsClosed() async throws {
        let harness = try await connectingHarness()
        harness.audio.startError = LiveVoiceTestError.missing
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 1, leaseEpoch: 1)))
        await harness.startTask.value

        #expect(!harness.controller.isLive)
        #expect(harness.controller.lastError != nil)
        #expect(harness.controller.statusText == harness.controller.lastError)
        #expect(harness.controller.statusText != "Listening")
        #expect(harness.controller.holdsComposer)
        #expect(sentTypes(harness.channel.sent).contains("voice_call_end"))
        #expect(leasePayload(harness.channel.sent.last { $0.typeLabel == "voice_call_end" })?.0 == "call-1")
        #expect(harness.channel.closed)
        #expect(harness.memory.callIdentity(forServer: "server-1") == nil)
        #expect(!harness.audio.isCapturing)

        await harness.controller.end()
        #expect(harness.controller.lastError == nil)
        #expect(harness.controller.statusText == "Listening")
        #expect(!harness.controller.holdsComposer)
    }

    @Test("A second start after capture failure mints a new client call id")
    func secondStartAfterCaptureFailureUsesFreshIdentity() async throws {
        let harness = try await connectingHarness()
        harness.audio.startError = LiveVoiceTestError.missing
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 1, leaseEpoch: 1)))
        await harness.startTask.value
        let firstId = startPayload(harness.channel.sent.first)
        #expect(firstId == "client-call-1")
        #expect(harness.memory.callIdentity(forServer: "server-1") == nil)
        #expect(sentTypes(harness.channel.sent).contains("voice_call_end"))
        #expect(!harness.controller.isLive)

        harness.audio.startError = nil
        let restart = Task { await harness.controller.start(sessionId: "sess-1", routeScope: .workspace("ws-1")) }
        await waitUntil { harness.channel.opened.count == 2 }
        harness.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { harness.channel.sent.filter { $0.typeLabel == "voice_call_start" }.count == 2 }
        let secondStart = harness.channel.sent.last { $0.typeLabel == "voice_call_start" }
        let secondId = startPayload(secondStart)
        #expect(secondId != nil)
        #expect(secondId != firstId)
        #expect(!sentTypes(harness.channel.sent).contains("voice_call_attach"))
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-2", eventSeq: 1, leaseEpoch: 1)))
        await restart.value

        #expect(harness.controller.isLive)
        #expect(harness.controller.callState?.callId == "call-2")
    }

    @Test("Rejected start keeps the bar showing the server error until End")
    func rejectedStartFailsClosed() async throws {
        let harness = try await connectingHarness()
        let requestId = requestId(of: harness.channel.sent.first)
        #expect(requestId != nil)

        harness.channel.emit(
            .commandResult(
                command: "voice_call_start",
                requestId: requestId,
                success: false,
                data: nil,
                error: "An active voice call already exists for this control session"
            )
        )
        await harness.startTask.value

        #expect(!harness.controller.isLive)
        #expect(harness.controller.lastError?.contains("already exists") == true)
        #expect(harness.controller.statusText == harness.controller.lastError)
        #expect(harness.controller.statusText != "Listening")
        #expect(harness.controller.holdsComposer)
        #expect(harness.channel.closed)
        #expect(!harness.audio.isCapturing)

        await harness.controller.end()
        #expect(harness.controller.lastError == nil)
        #expect(harness.controller.statusText == "Listening")
        #expect(!harness.controller.holdsComposer)
    }

    @Test("A second start after End mints a new client call id")
    func secondStartAfterEndUsesFreshIdentity() async throws {
        let harness = try await startedHarness()
        let firstId = startPayload(harness.channel.sent.first)
        #expect(firstId == "client-call-1")

        await harness.controller.end()
        #expect(!harness.controller.isLive)

        let restart = Task { await harness.controller.start(sessionId: "sess-1", routeScope: .workspace("ws-1")) }
        await waitUntil { harness.channel.opened.count == 2 }
        harness.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { harness.channel.sent.filter { $0.typeLabel == "voice_call_start" }.count == 2 }
        let secondStart = harness.channel.sent.last { $0.typeLabel == "voice_call_start" }
        let secondId = startPayload(secondStart)
        #expect(secondId != nil)
        #expect(secondId != firstId)
        #expect(requestId(of: secondStart) != nil)
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-2", eventSeq: 1, leaseEpoch: 1)))
        await restart.value

        #expect(harness.controller.isLive)
        #expect(harness.controller.callState?.callId == "call-2")
    }

    @Test("A start after the app closed mid-call attaches the remembered call instead of starting another")
    func startAfterRelaunchAttachesPersistedCall() async throws {
        let harness = try await startedHarness()
        #expect(harness.memory.callIdentity(forServer: "server-1")?.callId == "call-1")
        let app = relaunched(after: harness)

        let restart = Task { await app.controller.start(sessionId: "sess-1", routeScope: .workspace("ws-1")) }
        await waitUntil { !app.channel.opened.isEmpty }
        app.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(app.channel.sent).contains("voice_call_attach") }
        let attached = attachPayload(app.channel.sent.last { $0.typeLabel == "voice_call_attach" })
        #expect(attached?.0 == "call-1")
        #expect(requestId(of: app.channel.sent.last { $0.typeLabel == "voice_call_attach" }) != nil)
        app.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 5, leaseEpoch: 3)))
        await restart.value

        #expect(app.controller.isLive)
        #expect(app.controller.callState?.callId == "call-1")
        #expect(sentTypes(app.channel.sent) == ["voice_call_attach"])
    }

    @Test("A server error keeps the bar showing the real message until End")
    func serverErrorTearsDownFakeLiveBar() async throws {
        let harness = try await connectingHarness()
        #expect(harness.controller.isLive)

        harness.channel.emit(.error(message: "Continuous voice control is unavailable", code: nil, fatal: false))
        await harness.startTask.value

        #expect(!harness.controller.isLive)
        #expect(harness.controller.lastError == "Continuous voice control is unavailable")
        #expect(harness.controller.statusText == "Continuous voice control is unavailable")
        #expect(harness.controller.holdsComposer)
        #expect(harness.channel.closed)
        #expect(!harness.audio.isCapturing)

        await harness.controller.end()
        #expect(harness.controller.lastError == nil)
        #expect(!harness.controller.holdsComposer)
    }

    @Test("A session run error during a call leaves the call up")
    func sessionRunErrorKeepsCall() async throws {
        let harness = try await startedHarness()

        harness.channel.emit(.error(message: "Provider overloaded", code: nil, fatal: false))
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 2, leaseEpoch: 1)))
        await waitUntil { harness.controller.callState?.eventSeq == 2 }

        #expect(harness.controller.isLive)
        #expect(harness.controller.lastError == nil)
        #expect(!harness.channel.closed)
        #expect(harness.audio.isCapturing)
    }

    @Test("Another caller's failed command on the session leaves the call up")
    func foreignCommandFailureKeepsCall() async throws {
        let harness = try await startedHarness()

        harness.channel.emit(.commandResult(
            command: "set_thinking_level",
            requestId: "chat-request-1",
            success: false,
            data: nil,
            error: "Unsupported thinking level"
        ))
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 2, leaseEpoch: 1)))
        await waitUntil { harness.controller.callState?.eventSeq == 2 }

        #expect(harness.controller.isLive)
        #expect(harness.controller.lastError == nil)
        #expect(!harness.channel.closed)
    }

    @Test("The session going away during a call ends it with the reason")
    func fatalErrorEndsCall() async throws {
        let harness = try await startedHarness()

        harness.channel.emit(.error(message: "Session not found: sess-1", code: nil, fatal: true))
        await waitUntil { !harness.controller.isLive }

        #expect(harness.controller.lastError == "Session not found: sess-1")
        #expect(harness.channel.closed)
        #expect(!harness.audio.isCapturing)
    }

    @Test("The call stream ending for good ends the call, stops capture, and says why")
    func streamFinishingEndsConfirmedCall() async throws {
        let harness = try await startedHarness()
        await waitUntil { harness.audio.isCapturing }

        // WebSocketClient finishes its stream only on a terminal disconnect.
        harness.channel.finishStream()
        await waitUntil { !harness.controller.isLive }

        #expect(harness.controller.lastError == "Live Voice disconnected.")
        #expect(!harness.audio.isCapturing)
        #expect(harness.channel.closed)
    }

    @Test("Inbound PCM plays on the duplex owner without ending the call")
    func inboundPcmPlaysWithoutEndingCall() async throws {
        let harness = try await startedHarness()
        harness.channel.emitAudio(Data([9, 8, 7, 6]))
        await waitUntil { harness.audio.played == [Data([9, 8, 7, 6])] }
        #expect(harness.controller.isLive)
        #expect(harness.audio.isCapturing)
    }

    @Test("A delegation update shows its text without cutting off speech already playing")
    func delegationUpdateKeepsPlayback() async throws {
        let harness = try await startedHarness()
        let stopsBefore = harness.audio.playbackStops
        harness.channel.emitAudio(Data([1]))
        await waitUntil { harness.audio.played == [Data([1])] }

        harness.channel.emit(
            .voiceDelegationUpdate(
                VoiceDelegationUpdateMessage(
                    callId: "call-1",
                    controlSessionId: "sess-1",
                    eventSeq: 4,
                    delegationId: "delegation-1",
                    utteranceId: "utterance-1",
                    kind: .final,
                    text: "three open sessions",
                    createdAt: 2_000
                )
            )
        )
        await waitUntil { harness.controller.statusText == "three open sessions" }

        harness.channel.emitAudio(Data([2]))
        await waitUntil { harness.audio.played == [Data([1]), Data([2])] }
        #expect(harness.audio.playbackStops == stopsBefore)
        #expect(harness.controller.isLive)
    }

    @Test("Finish during an unconfirmed start still ends the orphaned server call")
    func finishDuringUnconfirmedStartEndsOrphan() async throws {
        let harness = try await connectingHarness()
        let endTask = Task { await harness.controller.end() }
        await waitUntil { !harness.controller.isLive }
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-orphan", eventSeq: 1, leaseEpoch: 1)))
        await waitUntil { sentTypes(harness.channel.sent).contains("voice_call_end") }
        await endTask.value
        await harness.startTask.value

        #expect(sentTypes(harness.channel.sent).contains("voice_call_end"))
        #expect(leasePayload(harness.channel.sent.last { $0.typeLabel == "voice_call_end" })?.0 == "call-orphan")
        #expect(!harness.controller.isLive)
    }

    @Test("End pressed while connecting, then a socket drop: the start is re-sent and its call ended")
    func orphanReconnectResendsStartAndEndsTheCall() async throws {
        let harness = try await connectingHarness()
        let endTask = Task { await harness.controller.end() }
        await waitUntil { !harness.controller.isLive }

        // The socket dropped and reconnected; the start's reply went down with the old one.
        harness.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(harness.channel.sent) == ["voice_call_start", "voice_call_start"] }
        #expect(sentTypes(harness.channel.sent) == ["voice_call_start", "voice_call_start"])
        #expect(startPayload(harness.channel.sent.last) == "client-call-1")

        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-orphan", eventSeq: 1, leaseEpoch: 1)))
        await waitUntil { sentTypes(harness.channel.sent).contains("voice_call_end") }
        await endTask.value
        await harness.startTask.value

        #expect(sentTypes(harness.channel.sent) == ["voice_call_start", "voice_call_start", "voice_call_end"])
        #expect(leasePayload(harness.channel.sent.last)?.0 == "call-orphan")
        #expect(!harness.controller.isLive)
    }

    @Test("End pressed while a rejoin attach is unanswered, then a socket drop: the attach is re-sent and the call ended")
    func orphanAttachReconnectReattachesAndEnds() async throws {
        let app = relaunched(after: try await startedHarness())
        let restart = Task { await app.controller.start(sessionId: "sess-1", routeScope: .workspace("ws-1")) }
        await waitUntil { !app.channel.opened.isEmpty }
        app.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(app.channel.sent).last == "voice_call_attach" }
        let endTask = Task { await app.controller.end() }
        await waitUntil { !app.controller.isLive }

        app.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(app.channel.sent) == ["voice_call_attach", "voice_call_attach"] }
        #expect(sentTypes(app.channel.sent) == ["voice_call_attach", "voice_call_attach"])
        app.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 5, leaseEpoch: 3)))
        await waitUntil { sentTypes(app.channel.sent).last == "voice_call_end" }
        await endTask.value
        await restart.value

        #expect(leasePayload(app.channel.sent.last)?.0 == "call-1")
        #expect(!sentTypes(app.channel.sent).contains("voice_call_start"))
        #expect(!app.controller.isLive)
    }

    @Test("Unrelated failures during an orphaned finish do not drop the end")
    func orphanIgnoresUnrelatedFailures() async throws {
        let harness = try await connectingHarness()
        let endTask = Task { await harness.controller.end() }
        await waitUntil { !harness.controller.isLive }

        harness.channel.emit(.commandResult(
            command: "set_model", requestId: "someone-else", success: false, data: nil, error: "No such model"
        ))
        harness.channel.emit(.commandResult(
            command: "voice_call_keepalive", requestId: "an-older-request", success: false, data: nil,
            error: "Stale voice controller lease"
        ))
        harness.channel.emit(.error(message: "Provider overloaded", code: nil, fatal: false))
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-orphan", eventSeq: 1, leaseEpoch: 1)))
        await waitUntil { sentTypes(harness.channel.sent).contains("voice_call_end") }
        await endTask.value
        await harness.startTask.value

        #expect(leasePayload(harness.channel.sent.last)?.0 == "call-orphan")
        #expect(harness.controller.lastError == nil)
    }

    @Test("An orphan's own rejected start closes quietly: no error on the composer after End")
    func orphanRejectedStartClosesWithoutError() async throws {
        let harness = try await connectingHarness()
        let endTask = Task { await harness.controller.end() }
        await waitUntil { !harness.controller.isLive }
        harness.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(harness.channel.sent).count == 2 }
        #expect(sentTypes(harness.channel.sent) == ["voice_call_start", "voice_call_start"])

        harness.channel.emit(.commandResult(
            command: "voice_call_start",
            requestId: requestId(of: harness.channel.sent.last),
            success: false,
            data: nil,
            error: "Voice call identity already belongs to an ended call"
        ))
        await waitUntil { harness.channel.closed }
        await endTask.value
        await harness.startTask.value

        #expect(harness.controller.lastError == nil)
        #expect(!harness.controller.holdsComposer)
        #expect(!harness.controller.isLive)
    }

    @Test("A reconnect before the start's reply re-sends the start with the same client call id")
    func reconnectBeforeStartReplyResendsStart() async throws {
        let harness = try await connectingHarness()

        // The socket dropped after voice_call_start and reconnected; the reply is lost.
        harness.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(harness.channel.sent) == ["voice_call_start", "voice_call_start"] }

        #expect(sentTypes(harness.channel.sent) == ["voice_call_start", "voice_call_start"])
        #expect(startPayload(harness.channel.sent.last) == "client-call-1")
        #expect(requestId(of: harness.channel.sent.last) != requestId(of: harness.channel.sent.first))

        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 1, leaseEpoch: 1)))
        await harness.startTask.value
        #expect(harness.controller.isLive)
        #expect(harness.controller.callState?.callId == "call-1")
    }

    @Test("A rejected re-sent start fails the call with the server's reason instead of hanging")
    func rejectedResentStartFailsClosed() async throws {
        let harness = try await connectingHarness()
        harness.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(harness.channel.sent).count == 2 }
        #expect(sentTypes(harness.channel.sent) == ["voice_call_start", "voice_call_start"])
        harness.channel.emit(.commandResult(
            command: "voice_call_start",
            requestId: requestId(of: harness.channel.sent.last),
            success: false,
            data: nil,
            error: "Voice call identity already belongs to an ended call"
        ))
        await harness.startTask.value

        #expect(!harness.controller.isLive)
        #expect(harness.controller.lastError == "Voice call identity already belongs to an ended call")
    }

    private func connectingHarness(keepAliveInterval: Duration = .seconds(10)) async throws -> Harness {
        let channel = FakeLiveVoiceCallChannel()
        let audio = FakeLiveVoiceAudioOwner()
        let memory = FakeLiveVoiceSessionMemory()
        let controller = LiveVoiceCallController(
            channel: channel,
            audio: audio,
            memory: memory,
            serverKey: "server-1",
            clientCallId: "client-call-1",
            keepAliveInterval: keepAliveInterval
        )
        let startTask = Task { await controller.start(sessionId: "sess-1", routeScope: .workspace("ws-1")) }
        await waitUntil { !channel.opened.isEmpty }
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(channel.sent) == ["voice_call_start"] }
        return Harness(
            controller: controller,
            channel: channel,
            audio: audio,
            memory: memory,
            startTask: startTask
        )
    }

    /// The app was closed mid-call and opened again: a new controller on the same remembered
    /// call, while the server kept the call.
    private func relaunched(
        after harness: Harness
    ) -> (controller: LiveVoiceCallController, channel: FakeLiveVoiceCallChannel) {
        let channel = FakeLiveVoiceCallChannel()
        let controller = LiveVoiceCallController(
            channel: channel,
            audio: FakeLiveVoiceAudioOwner(),
            memory: harness.memory,
            serverKey: "server-1",
            clientCallId: "client-call-2"
        )
        return (controller, channel)
    }

    private func startedHarness(keepAliveInterval: Duration = .seconds(10)) async throws -> Harness {
        let harness = try await connectingHarness(keepAliveInterval: keepAliveInterval)
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 1, leaseEpoch: 1)))
        await harness.startTask.value
        return harness
    }

    private static func snapshot(
        callId: String,
        eventSeq: Int,
        leaseEpoch: Int,
        frontend: VoiceCallFrontendState = .attached,
        partialTranscript: String? = nil,
        delegations: [VoiceCallDelegationSnapshot] = []
    ) -> VoiceCallStateSnapshot {
        VoiceCallStateSnapshot(
            callId: callId,
            controlSessionId: "sess-1",
            lifecycle: .active,
            frontend: frontend,
            controllerLeaseEpoch: leaseEpoch,
            controllerLeaseExpiresAt: 30_000,
            eventSeq: eventSeq,
            startedAt: 1_000,
            updatedAt: 2_000,
            delegations: delegations,
            partialTranscript: partialTranscript
        )
    }

    private static func delegation(
        _ id: String,
        _ state: VoiceCallDelegationState,
        _ text: String
    ) -> VoiceCallDelegationSnapshot {
        VoiceCallDelegationSnapshot(
            delegationId: id,
            utteranceId: "u-\(id)",
            request: "request \(id)",
            state: state,
            createdAt: 1_000,
            latestText: text
        )
    }
}

@MainActor
private struct Harness {
    let controller: LiveVoiceCallController
    let channel: FakeLiveVoiceCallChannel
    let audio: FakeLiveVoiceAudioOwner
    let memory: FakeLiveVoiceSessionMemory
    let startTask: Task<Void, Never>
}

@MainActor
final class FakeLiveVoiceAudioOwner: LiveVoiceAudioOwning {
    private(set) var isCapturing = false
    let openedDictationStream = false
    var onPCM: (@MainActor (Data) -> Void)?
    var onPlaybackActiveChange: (@MainActor (Bool) -> Void)?
    var startError: Error?
    private(set) var played: [Data] = []
    private(set) var playbackStops = 0

    func start() async throws {
        if let startError {
            throw startError
        }
        isCapturing = true
    }

    func setMuted(_ muted: Bool) {
        isCapturing = !muted
    }

    func play(_ pcm: Data) {
        played.append(pcm)
    }

    func stopPlayback() {
        playbackStops += 1
    }

    func stop() {
        isCapturing = false
    }

    func emit(_ data: Data) {
        guard isCapturing else { return }
        onPCM?(data)
    }

    func setPlaybackActive(_ active: Bool) {
        onPlaybackActiveChange?(active)
    }
}

private enum LiveVoiceTestError: Error {
    case missing
}

struct OpenedStream: Equatable {
    let sessionId: String
    let routeScope: SessionRouteScope
}

@MainActor
final class FakeLiveVoiceCallChannel: LiveVoiceCallChannel {
    var sent: [ClientMessage] = []
    var sentAudio: [Data] = []
    var opened: [OpenedStream] = []
    var closed = false
    var onInboundAudio: (@MainActor (Data) -> Void)?
    private var continuation: AsyncStream<ServerMessage>.Continuation?
    private var pending: [ServerMessage] = []

    func open(sessionId: String, routeScope: SessionRouteScope) -> AsyncStream<ServerMessage> {
        opened.append(OpenedStream(sessionId: sessionId, routeScope: routeScope))
        closed = false
        return AsyncStream { continuation in
            self.continuation = continuation
            let queued = pending
            pending.removeAll()
            for message in queued {
                continuation.yield(message)
            }
        }
    }

    func send(_ message: ClientMessage) async throws {
        // Match ServerConnectionLiveVoiceChannel: close() drops the client, so a
        // later send is a no-op instead of an append.
        guard !closed else { return }
        sent.append(message)
    }

    func sendAudio(_ pcm: Data) async throws {
        guard !closed else { return }
        sentAudio.append(pcm)
    }

    func close() {
        closed = true
        continuation?.finish()
        continuation = nil
        pending.removeAll()
    }

    func emit(_ message: ServerMessage) {
        if let continuation {
            continuation.yield(message)
        } else {
            pending.append(message)
        }
    }

    func emitAudio(_ pcm: Data) {
        onInboundAudio?(pcm)
    }

    /// The stream ends without the controller closing the channel.
    func finishStream() {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
final class FakeLiveVoiceSessionMemory: LiveVoiceSessionMemory {
    private var identities: [String: LiveVoiceCallIdentity] = [:]

    func callIdentity(forServer serverKey: String) -> LiveVoiceCallIdentity? {
        identities[serverKey]
    }

    func store(callIdentity: LiveVoiceCallIdentity, forServer serverKey: String) {
        identities[serverKey] = callIdentity
    }

    func clearCallIdentity(forServer serverKey: String) {
        identities[serverKey] = nil
    }
}

private func sentTypes(_ messages: [ClientMessage]) -> [String] {
    messages.map(\.typeLabel)
}

private func startPayload(_ message: ClientMessage?) -> String? {
    guard case .voiceCallStart(let clientCallId, _) = message else { return nil }
    return clientCallId
}

private func requestId(of message: ClientMessage?) -> String? {
    switch message {
    case .voiceCallStart(_, let requestId),
         .voiceCallAttach(_, _, let requestId),
         .voiceCallKeepAlive(_, _, let requestId),
         .voiceCallEnd(_, _, let requestId):
        return requestId
    default:
        return nil
    }
}

private func attachPayload(_ message: ClientMessage?) -> (String, Int)? {
    guard case .voiceCallAttach(let callId, let lastEventSeq, _) = message else { return nil }
    return (callId, lastEventSeq ?? -1)
}

private func leasePayload(_ message: ClientMessage?) -> (String, Int)? {
    switch message {
    case .voiceCallKeepAlive(let callId, let epoch, _),
         .voiceCallEnd(let callId, let epoch, _):
        return (callId, epoch)
    default:
        return nil
    }
}

private func containsDeviceId(_ message: ClientMessage?) -> Bool {
    guard let message else { return false }
    guard let data = try? JSONEncoder().encode(message),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    return object["deviceId"] != nil || object["authenticatedDeviceId"] != nil
}

private func waitUntil(
    timeoutMs: Int = 500,
    _ predicate: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
    while Date() < deadline {
        if await MainActor.run(body: predicate) {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }
}
