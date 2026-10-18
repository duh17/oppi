import Foundation
import Testing
@testable import Oppi

@Suite("LiveVoiceCallController")
@MainActor
struct LiveVoiceCallControllerTests {
    @Test("Start creates a hidden voice-control session, opens its stream, and starts the call")
    func startCreatesSessionOpensStreamAndStartsCall() async throws {
        let sessions = FakeLiveVoiceSessionGateway()
        let channel = FakeLiveVoiceCallChannel()
        let memory = FakeLiveVoiceSessionMemory()
        let controller = LiveVoiceCallController(
            sessions: sessions,
            channel: channel,
            memory: memory,
            serverKey: "server-1",
            clientCallId: "client-call-1"
        )

        let startTask = Task { await controller.start() }
        await waitUntil { !channel.openedSessionIds.isEmpty }
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(channel.sent) == ["voice_call_start"] }
        channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 1, leaseEpoch: 1)))
        await startTask.value

        #expect(sessions.createdPurposes == ["voice-control"])
        #expect(sessions.resumedIds.isEmpty)
        #expect(channel.openedSessionIds == ["voice-created"])
        #expect(memory.sessionId(forServer: "server-1") == "voice-created")
        #expect(controller.isLive)
        #expect(sentTypes(channel.sent) == ["voice_call_start"])
        #expect(startPayload(channel.sent.first) == "client-call-1")
        #expect(!containsDeviceId(channel.sent.first))
    }

    @Test("Start resumes a stored voice-control session instead of creating another")
    func startResumesStoredSession() async throws {
        let sessions = FakeLiveVoiceSessionGateway()
        let channel = FakeLiveVoiceCallChannel()
        let memory = FakeLiveVoiceSessionMemory()
        memory.store(sessionId: "voice-existing", forServer: "server-1")
        let controller = LiveVoiceCallController(
            sessions: sessions,
            channel: channel,
            memory: memory,
            serverKey: "server-1",
            clientCallId: "client-call-2"
        )

        let startTask = Task { await controller.start() }
        await waitUntil { !channel.openedSessionIds.isEmpty }
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(channel.sent) == ["voice_call_start"] }
        channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 1, leaseEpoch: 1)))
        await startTask.value

        #expect(sessions.createdPurposes.isEmpty)
        #expect(sessions.resumedIds == ["voice-existing"])
        #expect(channel.openedSessionIds == ["voice-existing"])
        #expect(controller.isLive)
    }

    @Test("Start creates a new hidden session when resume fails")
    func startCreatesWhenResumeFails() async throws {
        let sessions = FakeLiveVoiceSessionGateway()
        sessions.resumeError = LiveVoiceTestError.missing
        let channel = FakeLiveVoiceCallChannel()
        let memory = FakeLiveVoiceSessionMemory()
        memory.store(sessionId: "stale-voice", forServer: "server-1")
        let controller = LiveVoiceCallController(
            sessions: sessions,
            channel: channel,
            memory: memory,
            serverKey: "server-1",
            clientCallId: "client-call-3"
        )

        let startTask = Task { await controller.start() }
        await waitUntil { !channel.openedSessionIds.isEmpty }
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(channel.sent) == ["voice_call_start"] }
        channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 1, leaseEpoch: 1)))
        await startTask.value

        #expect(sessions.resumedIds == ["stale-voice"])
        #expect(sessions.createdPurposes == ["voice-control"])
        #expect(channel.openedSessionIds == ["voice-created"])
        #expect(memory.sessionId(forServer: "server-1") == "voice-created")
    }

    @Test("A call remembered from a voice session that no longer resumes starts fresh")
    func staleSessionCallStartsFresh() async throws {
        let sessions = FakeLiveVoiceSessionGateway()
        sessions.resumeError = LiveVoiceTestError.missing
        let channel = FakeLiveVoiceCallChannel()
        let memory = FakeLiveVoiceSessionMemory()
        memory.store(sessionId: "stale-voice", forServer: "server-1")
        memory.store(
            callIdentity: LiveVoiceCallIdentity(callId: "old-call", clientCallId: "old-client", eventSeq: 9),
            forServer: "server-1"
        )
        let controller = LiveVoiceCallController(
            sessions: sessions,
            channel: channel,
            memory: memory,
            serverKey: "server-1"
        )

        let startTask = Task { await controller.start() }
        await waitUntil { !channel.openedSessionIds.isEmpty }
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { !channel.sent.isEmpty }
        // Attaching "old-call" here is what failed with "Voice call belongs to a different control session".
        #expect(sentTypes(channel.sent) == ["voice_call_start"])
        #expect(startPayload(channel.sent.first) != "old-client")
        channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 1, leaseEpoch: 1)))
        await startTask.value
        #expect(controller.isLive)
        #expect(controller.lastError == nil)
    }

    @Test("A remembered call the server rejects is replaced by a new call, not an error")
    func rejectedStoredCallStartsFresh() async throws {
        let harness = try await startedHarness()
        await harness.controller.leave()

        let restart = Task { await harness.controller.start() }
        await waitUntil { harness.channel.openedSessionIds.count == 2 }
        harness.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(harness.channel.sent).contains("voice_call_attach") }
        let attach = harness.channel.sent.last { $0.typeLabel == "voice_call_attach" }
        harness.channel.emit(.commandResult(
            command: "voice_call_attach",
            requestId: requestId(of: attach),
            success: false,
            data: nil,
            error: "Voice call has ended"
        ))
        await waitUntil { sentTypes(harness.channel.sent).last == "voice_call_start" }
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-2", eventSeq: 1, leaseEpoch: 1)))
        await restart.value

        #expect(harness.controller.isLive)
        #expect(harness.controller.callState?.callId == "call-2")
        #expect(harness.controller.lastError == nil)
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

    @Test("Leave detaches the frontend without inventing a device id")
    func leaveDetachesCall() async throws {
        let harness = try await startedHarness()
        harness.channel.emit(
            .voiceCallState(Self.snapshot(callId: "call-leave", eventSeq: 2, leaseEpoch: 4))
        )
        await waitUntil { harness.controller.callState?.callId == "call-leave" }

        await harness.controller.leave()

        #expect(sentTypes(harness.channel.sent).last == "voice_call_detach")
        let detached = leasePayload(harness.channel.sent.last)
        #expect(detached?.0 == "call-leave")
        #expect(detached?.1 == 4)
        #expect(harness.channel.closed)
        #expect(!harness.controller.isLive)
    }

    @Test("Approval required presents the existing challenge summary")
    func approvalRequiredPresentsSummary() async throws {
        let harness = try await startedHarness()
        harness.channel.emit(
            .voiceApprovalRequired(
                VoiceApprovalRequiredMessage(
                    callId: "call-1",
                    controlSessionId: "voice-created",
                    eventSeq: 8,
                    challengeId: "challenge-1",
                    requestId: "request-1",
                    summary: "Allow the test command?",
                    targetRefs: ["command:npm-test"],
                    expiresAt: 9_000
                )
            )
        )
        await waitUntil { harness.controller.approvalSummary == "Allow the test command?" }

        #expect(harness.controller.statusText == "Allow the test command?")
        #expect(!sentTypes(harness.channel.sent).contains("voice_approval_response"))
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

    @Test("Partial Yuwp transcripts update the Live Voice bar without a client dictation stream")
    func partialTranscriptUpdatesStatus() async throws {
        let harness = try await startedHarness()
        harness.channel.emit(
            .voiceCallState(
                Self.snapshot(callId: "call-1", eventSeq: 2, leaseEpoch: 1, partialTranscript: "list open")
            )
        )
        await waitUntil { harness.controller.statusText == "list open" }
        #expect(harness.controller.isLive)
        #expect(!harness.audio.openedDictationStream)
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
        #expect(harness.controller.statusText == "stop")
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
        #expect(ChatView.showsLiveVoiceBar(
            isLive: harness.controller.isLive,
            lastError: harness.controller.lastError
        ))
        #expect(sentTypes(harness.channel.sent).contains("voice_call_end"))
        #expect(leasePayload(harness.channel.sent.last { $0.typeLabel == "voice_call_end" })?.0 == "call-1")
        #expect(harness.channel.closed)
        #expect(harness.memory.callIdentity(forServer: "server-1") == nil)
        #expect(!harness.audio.isCapturing)

        await harness.controller.end()
        #expect(harness.controller.lastError == nil)
        #expect(harness.controller.statusText == "Listening")
        #expect(!ChatView.showsLiveVoiceBar(
            isLive: harness.controller.isLive,
            lastError: harness.controller.lastError
        ))
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
        let restart = Task { await harness.controller.start() }
        await waitUntil { harness.channel.openedSessionIds.count == 2 }
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
        #expect(ChatView.showsLiveVoiceBar(
            isLive: harness.controller.isLive,
            lastError: harness.controller.lastError
        ))
        #expect(harness.channel.closed)
        #expect(!harness.audio.isCapturing)

        await harness.controller.end()
        #expect(harness.controller.lastError == nil)
        #expect(harness.controller.statusText == "Listening")
        #expect(!ChatView.showsLiveVoiceBar(
            isLive: harness.controller.isLive,
            lastError: harness.controller.lastError
        ))
    }

    @Test("A second start after End mints a new client call id")
    func secondStartAfterEndUsesFreshIdentity() async throws {
        let harness = try await startedHarness()
        let firstId = startPayload(harness.channel.sent.first)
        #expect(firstId == "client-call-1")

        await harness.controller.end()
        #expect(!harness.controller.isLive)

        let restart = Task { await harness.controller.start() }
        await waitUntil { harness.channel.openedSessionIds.count == 2 }
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

    @Test("Start after leave attaches the persisted call instead of starting another")
    func startAfterLeaveAttachesPersistedCall() async throws {
        let harness = try await startedHarness()
        await harness.controller.leave()
        #expect(!harness.controller.isLive)
        #expect(harness.memory.callIdentity(forServer: "server-1")?.callId == "call-1")

        let restart = Task { await harness.controller.start() }
        await waitUntil { harness.channel.openedSessionIds.count == 2 }
        harness.channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(harness.channel.sent).contains("voice_call_attach") }
        let attached = attachPayload(harness.channel.sent.last { $0.typeLabel == "voice_call_attach" })
        #expect(attached?.0 == "call-1")
        #expect(requestId(of: harness.channel.sent.last { $0.typeLabel == "voice_call_attach" }) != nil)
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 5, leaseEpoch: 3)))
        await restart.value

        #expect(harness.controller.isLive)
        #expect(harness.controller.callState?.callId == "call-1")
        #expect(!sentTypes(harness.channel.sent.suffix(2)).contains("voice_call_start"))
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
        #expect(ChatView.showsLiveVoiceBar(
            isLive: harness.controller.isLive,
            lastError: harness.controller.lastError
        ))
        #expect(harness.channel.closed)
        #expect(!harness.audio.isCapturing)

        await harness.controller.end()
        #expect(harness.controller.lastError == nil)
        #expect(!ChatView.showsLiveVoiceBar(
            isLive: harness.controller.isLive,
            lastError: harness.controller.lastError
        ))
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
                    controlSessionId: "voice-created",
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

    private func connectingHarness() async throws -> Harness {
        let sessions = FakeLiveVoiceSessionGateway()
        let channel = FakeLiveVoiceCallChannel()
        let audio = FakeLiveVoiceAudioOwner()
        let memory = FakeLiveVoiceSessionMemory()
        let controller = LiveVoiceCallController(
            sessions: sessions,
            channel: channel,
            audio: audio,
            memory: memory,
            serverKey: "server-1",
            clientCallId: "client-call-1"
        )
        let startTask = Task { await controller.start() }
        await waitUntil { !channel.openedSessionIds.isEmpty }
        channel.emit(.streamConnected(userName: "owner", serverDictationAvailable: false))
        await waitUntil { sentTypes(channel.sent) == ["voice_call_start"] }
        return Harness(
            controller: controller,
            channel: channel,
            audio: audio,
            sessions: sessions,
            memory: memory,
            startTask: startTask
        )
    }

    private func startedHarness() async throws -> Harness {
        let harness = try await connectingHarness()
        harness.channel.emit(.voiceCallState(Self.snapshot(callId: "call-1", eventSeq: 1, leaseEpoch: 1)))
        await harness.startTask.value
        return harness
    }

    private static func snapshot(
        callId: String,
        eventSeq: Int,
        leaseEpoch: Int,
        partialTranscript: String? = nil
    ) -> VoiceCallStateSnapshot {
        VoiceCallStateSnapshot(
            callId: callId,
            controlSessionId: "voice-created",
            lifecycle: .active,
            frontend: .attached,
            controllerLeaseEpoch: leaseEpoch,
            controllerLeaseExpiresAt: 30_000,
            eventSeq: eventSeq,
            startedAt: 1_000,
            updatedAt: 2_000,
            delegations: [],
            pendingApprovals: [],
            partialTranscript: partialTranscript
        )
    }
}

@MainActor
private struct Harness {
    let controller: LiveVoiceCallController
    let channel: FakeLiveVoiceCallChannel
    let audio: FakeLiveVoiceAudioOwner
    let sessions: FakeLiveVoiceSessionGateway
    let memory: FakeLiveVoiceSessionMemory
    let startTask: Task<Void, Never>
}

private enum LiveVoiceTestError: Error {
    case missing
}

@MainActor
final class FakeLiveVoiceAudioOwner: LiveVoiceAudioOwning {
    private(set) var isCapturing = false
    let openedDictationStream = false
    var onPCM: (@MainActor (Data) -> Void)?
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
}

@MainActor
private final class FakeLiveVoiceSessionGateway: LiveVoiceSessionGateway {
    var createdPurposes: [String] = []
    var resumedIds: [String] = []
    var resumeError: Error?

    func createVoiceControlSession(purpose: String) async throws -> Session {
        createdPurposes.append(purpose)
        var session = makeTestSession(id: "voice-created", name: "Voice Control")
        session.voice = VoiceControlSessionMetadata(purpose: purpose)
        return session
    }

    func resumeVoiceControlSession(id: String) async throws -> Session {
        resumedIds.append(id)
        if let resumeError {
            throw resumeError
        }
        var session = makeTestSession(id: id, name: "Voice Control")
        session.voice = VoiceControlSessionMetadata(purpose: "voice-control")
        return session
    }
}

@MainActor
private final class FakeLiveVoiceCallChannel: LiveVoiceCallChannel {
    var sent: [ClientMessage] = []
    var sentAudio: [Data] = []
    var openedSessionIds: [String] = []
    var closed = false
    var onInboundAudio: (@MainActor (Data) -> Void)?
    private var continuation: AsyncStream<ServerMessage>.Continuation?
    private var pending: [ServerMessage] = []

    func open(sessionId: String) -> AsyncStream<ServerMessage> {
        openedSessionIds.append(sessionId)
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
}

@MainActor
private final class FakeLiveVoiceSessionMemory: LiveVoiceSessionMemory {
    private var values: [String: String] = [:]
    private var identities: [String: LiveVoiceCallIdentity] = [:]

    func sessionId(forServer serverKey: String) -> String? {
        values[serverKey]
    }

    func store(sessionId: String, forServer serverKey: String) {
        values[serverKey] = sessionId
    }

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
         .voiceCallDetach(_, _, let requestId),
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
         .voiceCallDetach(let callId, let epoch, _),
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
