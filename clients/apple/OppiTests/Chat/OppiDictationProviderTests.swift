@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import Oppi

@MainActor
final class TestDictationTransport: DictationTransport {
    var sentMessages: [ClientMessage] = []
    var sentAudio: [Data] = []
    var closeCount = 0
    var onSendDictation: ((ClientMessage) async throws -> Void)?
    var onSendAudio: ((Data) async throws -> Void)?

    func sendDictation(_ message: ClientMessage) async throws {
        sentMessages.append(message)
        try await onSendDictation?(message)
    }

    func sendDictationAudio(_ data: Data) async throws {
        sentAudio.append(data)
        try await onSendAudio?(data)
    }

    func closeDictationTransport() {
        closeCount += 1
    }
}

@MainActor
@discardableResult
private func installTestDictationTransport(
    on provider: OppiDictationProvider,
    transport: TestDictationTransport = TestDictationTransport(),
    messages: AsyncStream<ServerMessage> = AsyncStream<ServerMessage> { _ in }
) -> TestDictationTransport {
    provider._makeDictationTransportForTesting = { (transport, messages) }
    return transport
}

/// Substitute only the microphone startup; Stop, events, PCM drain and cleanup
/// are the real OppiDictationSession, including an indefinitely open receive side.
@MainActor
final class TestPCMDictationSession: VoiceTranscriptionSession {
    let session: OppiDictationSession
    var events: AsyncThrowingStream<VoiceSessionEvent, Error> { session.events }
    var audioLevels: AsyncStream<Float> { session.audioLevels }

    init(_ session: OppiDictationSession) { self.session = session }

    func start() async throws -> VoiceSessionStartTimings {
        session._installPCMInputForTesting()
        session._startMessageListenerForTesting()
        session._startAudioDrainTaskForTesting()
        return VoiceSessionStartTimings(analyzerStartMs: 0, audioStartMs: 0)
    }

    func stop() async { await session.stop() }
    func cancel() async { await session.cancel() }
    func rebuildAudioCapture() async throws { try await session.rebuildAudioCapture() }
}

// MARK: - Dictation ServerMessage Decoding

@Suite("Dictation ServerMessage decoding")
struct DictationServerMessageDecodingTests {

    @Test func decodesReadyMinimal() throws {
        let message = try decode(#"{"type":"dictation_ready"}"#)
        #expect(message == .dictationReady(provider: nil, contextApplied: nil))
    }

    @Test func decodesReadyWithProviderInfo() throws {
        let json = #"{"type":"dictation_ready","sttProvider":"mlx-server","sttModel":"Qwen3-ASR-1.7B"}"#
        let message = try decode(json)
        let expected = DictationProviderInfo(
            sttProvider: "mlx-server",
            sttModel: "Qwen3-ASR-1.7B"
        )
        #expect(message == .dictationReady(provider: expected, contextApplied: nil))
    }

    @Test func decodesReadyWithContextApplied() throws {
        let json = #"{"type":"dictation_ready","sttProvider":"mlx-server","sttModel":"Qwen3-ASR-1.7B","contextApplied":true}"#
        let message = try decode(json)
        let expected = DictationProviderInfo(
            sttProvider: "mlx-server",
            sttModel: "Qwen3-ASR-1.7B"
        )
        #expect(message == .dictationReady(provider: expected, contextApplied: true))
    }

    @Test func decodesReadyWithContextAppliedFalse() throws {
        let json = #"{"type":"dictation_ready","contextApplied":false}"#
        let message = try decode(json)
        #expect(message == .dictationReady(provider: nil, contextApplied: false))
    }

    @Test func decodesReadyWithPartialProviderInfo() throws {
        // If only sttProvider is present but not sttModel, provider should be nil
        let json = #"{"type":"dictation_ready","sttProvider":"openai"}"#
        let message = try decode(json)
        #expect(message == .dictationReady(provider: nil))
    }

    @Test func decodesResult() throws {
        let json = #"{"type":"dictation_result","text":"Hello world"}"#
        let message = try decode(json)
        #expect(message == .dictationResult(text: "Hello world", snap: false))
    }

    @Test func decodesResultWithCommittedAndActiveSplit() throws {
        let json = #"{"type":"dictation_result","text":"Hello world","committedText":"Hello","activeText":"world"}"#
        let message = try decode(json)
        #expect(message == .dictationResult(
            text: "Hello world",
            snap: false,
            split: DictationTranscriptSplit(committedText: "Hello", activeText: "world")
        ))
    }

    @Test func decodesFinal() throws {
        let json = #"{"type":"dictation_final","text":"Hello world how are you"}"#
        let message = try decode(json)
        #expect(message == .dictationFinal(text: "Hello world how are you"))
    }

    @Test func decodesFinalMinimal() throws {
        let json = #"{"type":"dictation_final","text":"Hello"}"#
        let message = try decode(json)
        #expect(message == .dictationFinal(text: "Hello"))
    }

    @Test func decodesError() throws {
        let json = #"{"type":"dictation_error","error":"STT backend unreachable","fatal":true}"#
        let message = try decode(json)
        #expect(message == .dictationError(error: "STT backend unreachable", fatal: true))
    }

    @Test func decodesErrorDefaultsFatalToFalse() throws {
        let json = #"{"type":"dictation_error","error":"transient failure"}"#
        let message = try decode(json)
        #expect(message == .dictationError(error: "transient failure", fatal: false))
    }

    private func decode(_ json: String) throws -> ServerMessage {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(ServerMessage.self, from: data)
    }
}

// MARK: - Dictation ClientMessage Encoding

@Suite("Dictation ClientMessage encoding")
struct DictationClientMessageEncodingTests {

    @Test func encodesStart() throws {
        let message = ClientMessage.dictationStart()
        let json = try encode(message)
        #expect(json.contains("\"type\":\"dictation_start\""))
        #expect(!json.contains("contextualStrings"))
    }

    @Test func encodesStartWithContextualStrings() throws {
        let json = try encode(.dictationStart(contextualStrings: ["Foo Bar", "Yuwp"]))
        #expect(json.contains("\"type\":\"dictation_start\""))
        #expect(json.contains("\"contextualStrings\""))
        #expect(json.contains("Foo Bar"))
        #expect(json.contains("Yuwp"))
    }

    @Test func encodingDropsIllegalContextualStrings() throws {
        let json = try encode(.dictationStart(contextualStrings: ["", "  ", "ok\nno"]))
        #expect(json.contains("\"type\":\"dictation_start\""))
        #expect(!json.contains("contextualStrings"))
    }

    @Test func encodesStop() throws {
        let message = ClientMessage.dictationStop
        let json = try encode(message)
        #expect(json.contains("\"type\":\"dictation_stop\""))
    }

    @Test func encodesCancel() throws {
        let message = ClientMessage.dictationCancel
        let json = try encode(message)
        #expect(json.contains("\"type\":\"dictation_cancel\""))
    }

    private func encode(_ message: ClientMessage) throws -> String {
        let data = try JSONEncoder().encode(message)
        return try #require(String(data: data, encoding: .utf8))
    }
}

// MARK: - PCM Conversion

@Suite("PCM conversion")
struct PCMConversionTests {

    @Test func convertsFloat32ToInt16PCM() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ))

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4

        let floatData = try #require(buffer.floatChannelData?[0])
        floatData[0] = 0.0      // silence
        floatData[1] = 1.0      // max positive
        floatData[2] = -1.0     // max negative
        floatData[3] = 0.5      // mid positive

        let pcmData = OppiDictationSession.convertToInt16PCM(buffer: buffer)

        // 4 samples * 2 bytes each = 8 bytes
        #expect(pcmData.count == 8)

        // Verify sample values (little-endian Int16)
        pcmData.withUnsafeBytes { raw in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            #expect(int16Ptr[0] == 0)           // silence
            #expect(int16Ptr[1] == Int16.max)   // max positive
            #expect(int16Ptr[2] == -Int16.max)  // max negative
            #expect(int16Ptr[3] == Int16(0.5 * Float(Int16.max)))  // mid positive
        }
    }

    @Test func closedOrBackpressuredPCMStreamStopsDeliveryHeartbeat() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        withExtendedLifetime(stream) {
            #expect(AudioEngineHelper.enqueueCaptureInput(Data([1]), into: continuation, events: events.continuation))
            #expect(!AudioEngineHelper.enqueueCaptureInput(Data([2]), into: continuation, events: events.continuation))
            #expect(!AudioEngineHelper.enqueueCaptureInput(Data([3]), into: continuation, events: events.continuation))
        }
    }

    @Test func emptyBufferReturnsEmptyData() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ))

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 0))
        buffer.frameLength = 0

        let pcmData = OppiDictationSession.convertToInt16PCM(buffer: buffer)
        #expect(pcmData.isEmpty)
    }

    @Test func clampsOutOfRangeValues() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ))

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2

        let floatData = try #require(buffer.floatChannelData?[0])
        floatData[0] = 2.0    // over max
        floatData[1] = -3.0   // under min

        let pcmData = OppiDictationSession.convertToInt16PCM(buffer: buffer)

        pcmData.withUnsafeBytes { raw in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            #expect(int16Ptr[0] == Int16.max)    // clamped to max
            #expect(int16Ptr[1] == -Int16.max)   // clamped to min
        }
    }
}

// MARK: - Event Mapping

@Suite("Dictation event mapping")
struct DictationEventMappingTests {

    @Test func resultMapsToReplaceFinalTranscript() {
        let event = mapServerMessage(.dictationResult(text: "Hello world", snap: false))
        #expect(event == .replaceFinalTranscript("Hello world"))
    }

    @Test func resultMapsCommittedAndActiveSplit() {
        let event = mapServerMessage(
            .dictationResult(
                text: "Hello world",
                snap: false,
                split: DictationTranscriptSplit(committedText: "Hello", activeText: "world")
            )
        )
        #expect(event == .replaceFinalTranscript(
            "Hello world",
            snap: false,
            committedText: "Hello",
            activeText: "world"
        ))
    }

    @Test func finalMapsToSettledReplaceFinalTranscript() {
        let event = mapServerMessage(.dictationFinal(text: "Complete transcript"))
        #expect(event == .replaceFinalTranscript("Complete transcript", snap: true))
    }

    @Test func readyMapsToNil() {
        let event = mapServerMessage(.dictationReady(provider: nil))
        #expect(event == nil)
    }

    @Test func nonFatalErrorMapsToNil() {
        let event = mapServerMessage(.dictationError(error: "transient", fatal: false))
        #expect(event == nil)
    }

    /// Map a server message to the VoiceSessionEvent it would produce,
    /// following the same logic as OppiDictationSession's message listener.
    private func mapServerMessage(_ message: ServerMessage) -> VoiceSessionEvent? {
        switch message {
        case .dictationReady:
            return nil
        case .dictationResult(let text, let snap, let split):
            return .replaceFinalTranscript(
                text,
                snap: snap,
                committedText: split?.committedText,
                activeText: split?.activeText
            )
        case .dictationFinal(let text, let split):
            return text.isEmpty ? nil : .replaceFinalTranscript(
                text,
                snap: true,
                committedText: split?.committedText,
                activeText: split?.activeText
            )
        case .dictationError(_, let fatal):
            return fatal ? nil : nil
        default:
            return nil
        }
    }
}

// MARK: - Provider Tests

@Suite("OppiDictationProvider")
@MainActor
struct OppiDictationProviderTests {

    @Test func providerIdAndEngine() {
        let provider = OppiDictationProvider()
        #expect(provider.id == .oppiServer)
        #expect(provider.engine == .serverDictation)
    }

    @Test func prepareSessionThrowsWithoutCredentials() async {
        let provider = OppiDictationProvider()
        let context = VoiceProviderContext(
            locale: Locale(identifier: "en-US"),
            source: "test",
            serverCredentials: nil
        )

        await #expect(throws: VoiceInputError.self) {
            try await provider.prepareSession(context: context)
        }
    }

    @Test func prepareSessionThrowsWithoutConnection() async {
        let provider = OppiDictationProvider()
        // Has credentials but no connection
        let context = VoiceProviderContext(
            locale: Locale(identifier: "en-US"),
            source: "test",
            serverCredentials: ServerCredentials(
                host: "localhost", port: 7749,
                token: "test-token",
                name: "test-server",
                scheme: .http
            )
        )

        await #expect(throws: VoiceInputError.self) {
            try await provider.prepareSession(context: context)
        }
    }

    @Test func makeSessionThrowsWithoutPrepare() {
        let provider = OppiDictationProvider()
        let context = VoiceProviderContext(
            locale: Locale(identifier: "en-US"),
            source: "test"
        )
        let preparation = VoiceProviderPreparation(
            audioFormat: nil,
            pathTag: "test",
            setupMetricTags: [:]
        )

        #expect(throws: VoiceInputError.self) {
            try provider.makeSession(context: context, preparation: preparation)
        }
    }

    @Test func registryIncludesOppiDictationProvider() {
        let registry = VoiceProviderRegistry.makeDefault()
        let provider = registry.provider(for: .serverDictation)
        #expect(provider is OppiDictationProvider)
    }
}

// MARK: - Disconnect Regression Tests

@Suite("Dictation disconnect regression")
@MainActor
struct DictationDisconnectRegressionTests {

    @Test func unexpectedMessageStreamEndSurfacesDisconnectError() async {
        let transport = TestDictationTransport()
        let recordingPair = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: recordingPair.stream
        )

        let errorTask = Task {
            await consumeStreamError(from: session.events)
        }

        session._startMessageListenerForTesting()
        recordingPair.continuation.finish()

        let error = await errorTask.value
        #expect(error?.localizedDescription == "Dictation connection lost")
    }

    @Test func audioDrainSendFailureSurfacesDisconnectError() async {
        let transport = TestDictationTransport()
        transport.onSendAudio = { _ in
            throw WebSocketError.notConnected
        }

        let recordingPair = AsyncStream.makeStream(of: ServerMessage.self)
        let audioPair = AsyncStream.makeStream(of: Data.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: recordingPair.stream
        )

        let errorTask = Task {
            await consumeStreamError(from: session.events)
        }

        session._setPendingAudioStreamForTesting(audioPair.stream)
        session._startAudioDrainTaskForTesting()
        audioPair.continuation.yield(Data([0x01, 0x02]))
        audioPair.continuation.finish()

        let error = await errorTask.value
        #expect(error?.localizedDescription == "Dictation connection lost")
    }

    private func consumeStreamError(
        from events: AsyncThrowingStream<VoiceSessionEvent, Error>
    ) async -> Error? {
        do {
            for try await _ in events {}
            return nil
        } catch {
            return error
        }
    }
}

// MARK: - Crash Regression Tests

@Suite("Dictation crash regression")
@MainActor
struct DictationCrashRegressionTests {

    /// Regression: provider(for:) used fatalError on missing provider,
    /// crashing the app when server returned 404 for /dictation.
    /// Now throws VoiceInputError instead.
    @Test func providerLookupDoesNotCrashOnMissingEngine() {
        let registry = VoiceProviderRegistry(providers: [])
        let provider = registry.provider(for: .serverDictation)
        #expect(provider == nil, "Missing provider should return nil, not crash")
    }

    /// Regression: VoiceInputManager.provider(for:) used fatalError.
    /// Verify it throws a recoverable error instead.
    @Test func managerHandlesMissingProviderGracefully() async throws {
        let emptyRegistry = VoiceProviderRegistry(providers: [])
        let manager = VoiceInputManager(
            providerRegistry: emptyRegistry,
            systemAccess: MockSystemAccess(hasPermissions: true)
        )
        manager.setEngineMode(.remote)

        do {
            try await manager.startRecording(source: "test")
            Issue.record("Expected startRecording to throw for missing provider")
        } catch {
            #expect(manager.state != .recording)
        }
    }
}

// MARK: - Mock System Access (for crash regression tests)

private struct MockSystemAccess: VoiceInputSystemAccessing {
    let hasPermissions: Bool
    var hasMicPermission: Bool { hasPermissions }
    func requestPermissions() async -> Bool { hasPermissions }
    func requestMicPermission() async -> Bool { hasPermissions }
    func activateAudioSession(inAppPlaybackActive _: Bool) throws {}
    func activateBuiltInAudioSession(inAppPlaybackActive _: Bool) throws {}
    func deactivateAudioSession() {}
}

// MARK: - Provider Lifecycle Tests

@Suite("OppiDictationProvider lifecycle")
@MainActor
struct OppiDictationProviderLifecycleTests {

    private static func makeCredentials() -> ServerCredentials {
        ServerCredentials(
            host: "localhost", port: 7749,
            token: "test-token",
            name: "test-server",
            scheme: .http
        )
    }

    private static func makeContextWithConnection() -> (VoiceProviderContext, ServerConnection) {
        let connection = ServerConnection()
        let credentials = makeCredentials()
        _ = connection.configure(credentials: credentials)
        connection.setSplitStreamCapabilitiesForTesting(dictationStream: true)
        connection.focusedSessionStore.focus(sessionId: "s1")
        let context = VoiceProviderContext(
            locale: Locale(identifier: "en-US"),
            source: "test",
            serverCredentials: credentials,
            serverConnection: connection
        )
        return (context, connection)
    }

    // MARK: - prewarm

    @Test func prewarmIsNoOp() async throws {
        let provider = OppiDictationProvider()
        let context = VoiceProviderContext(locale: Locale(identifier: "en-US"), source: "test")
        // Should complete without throwing — it's a no-op for server dictation
        try await provider.prewarm(context: context)
    }

    // MARK: - invalidateCache

    @Test func invalidateCacheDoesNotCrashWhenClean() {
        let provider = OppiDictationProvider()
        // Should not crash when called with no active state
        provider.invalidateCache()
    }

    // MARK: - cancelPreparation

    @Test func cancelPreparationDoesNotCrashWhenClean() {
        let provider = OppiDictationProvider()
        // Should not crash when called with no active preparation
        provider.cancelPreparation()
    }

    @Test func cancelPreparationIsIdempotent() {
        let provider = OppiDictationProvider()
        provider.cancelPreparation()
        provider.cancelPreparation()
        // No crash, no assertion failure — idempotent cleanup
    }

    @Test func invalidateCacheIsIdempotent() {
        let provider = OppiDictationProvider()
        provider.invalidateCache()
        provider.invalidateCache()
        // No crash, no assertion failure — idempotent cleanup
    }

    // MARK: - prepareSession + makeSession happy path

    @Test func prepareSessionUsesServerBoundStreamWithoutCapabilityPreflight() async throws {
        let connection = ServerConnection()
        let credentials = Self.makeCredentials()
        _ = connection.configure(credentials: credentials)
        let context = VoiceProviderContext(
            locale: Locale(identifier: "en-US"),
            source: "test",
            serverCredentials: credentials,
            serverConnection: connection
        )
        let provider = OppiDictationProvider()

        _ = installTestDictationTransport(on: provider)
        let preparation = try await provider.prepareSession(context: context)

        #expect(preparation.setupMetricTags["transport"] == "dictation_stream")
        provider.invalidateCache()
    }

    @Test func prepareSessionOmitsEmptyContextualStrings() async throws {
        let connection = ServerConnection()
        let credentials = Self.makeCredentials()
        _ = connection.configure(credentials: credentials)
        let context = VoiceProviderContext(
            locale: Locale(identifier: "en-US"),
            source: "test",
            serverCredentials: credentials,
            serverConnection: connection,
            contextualStrings: []
        )
        let provider = OppiDictationProvider()
        let transport = installTestDictationTransport(on: provider)
        _ = try await provider.prepareSession(context: context)

        #expect(await waitForMainActorCondition {
            transport.sentMessages.contains { message in
                if case .dictationStart(let phrases) = message {
                    return phrases.isEmpty
                }
                return false
            }
        })
        provider.invalidateCache()
    }

    @Test func prepareSessionSendsPreparedContextualStringsFromContext() async throws {
        let connection = ServerConnection()
        let credentials = Self.makeCredentials()
        _ = connection.configure(credentials: credentials)
        let context = VoiceProviderContext(
            locale: Locale(identifier: "en-US"),
            source: "test",
            serverCredentials: credentials,
            serverConnection: connection,
            contextualStrings: ["  Foo Bar  ", "", "Yuwp"]
        )
        let provider = OppiDictationProvider()
        let transport = installTestDictationTransport(on: provider)
        _ = try await provider.prepareSession(context: context)

        #expect(await waitForMainActorCondition {
            transport.sentMessages.contains { message in
                if case .dictationStart(let phrases) = message {
                    return phrases == ["Foo Bar", "Yuwp"]
                }
                return false
            }
        })
        provider.invalidateCache()
    }

    @Test func prepareSessionReturnsPreparationWithCorrectPathTag() async throws {
        let (context, _) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        _ = installTestDictationTransport(on: provider)

        let preparation = try await provider.prepareSession(context: context)
        #expect(preparation.pathTag == "dictation_audio_ws")
        #expect(preparation.audioFormat == nil)
        #expect(preparation.setupMetricTags["dictation_mode"] == "server")
        #expect(preparation.setupMetricTags["transport"] == "dictation_stream")
        #expect(preparation.setupMetricTags["host"] == "localhost")
        #expect(preparation.setupMetricTags["provider_id"] == "oppi_server_dictation")
        #expect(preparation.setupMetricTags["provider_kind"] == "local_server")

        // Cleanup
        provider.invalidateCache()
    }

    @Test func makeSessionSucceedsAfterPrepare() async throws {
        let (context, _) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        _ = installTestDictationTransport(on: provider)

        let preparation = try await provider.prepareSession(context: context)
        let session = try provider.makeSession(context: context, preparation: preparation)
        #expect(session is OppiDictationSession)

        // After makeSession, internal state should be transferred
        // A second makeSession should fail (readiness task consumed)
        #expect(throws: VoiceInputError.self) {
            try provider.makeSession(context: context, preparation: preparation)
        }

        // Cleanup
        provider.invalidateCache()
    }

    @Test func cancelledTakeCanBeRepreparedWithFreshTransport() async throws {
        let (context, _) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()
        let firstTransport = installTestDictationTransport(on: provider)
        let firstPreparation = try await provider.prepareSession(context: context)
        let first = try provider.makeSession(context: context, preparation: firstPreparation)
        #expect(await waitForMainActorCondition { !firstTransport.sentMessages.isEmpty })
        await first.cancel()
        provider.cancelPreparation()
        #expect(firstTransport.closeCount == 1)

        let secondTransport = installTestDictationTransport(on: provider)
        let secondPreparation = try await provider.prepareSession(context: context)
        let second = try provider.makeSession(context: context, preparation: secondPreparation)
        #expect(await waitForMainActorCondition { !secondTransport.sentMessages.isEmpty })
        #expect(secondTransport.closeCount == 0)
        #expect(firstTransport.closeCount == 1)
        await second.cancel()
        provider.cancelPreparation()
        #expect(secondTransport.closeCount == 1)
    }

    @Test(arguments: [false, true])
    func upstreamEndFinishesRecordingAndReadiness(beforeReady: Bool) async throws {
        let (context, _) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()
        let incoming = AsyncStream<ServerMessage>.makeStream()
        let transport = installTestDictationTransport(on: provider, messages: incoming.stream)
        let preparation = try await provider.prepareSession(context: context)
        let session = try #require(
            provider.makeSession(context: context, preparation: preparation) as? OppiDictationSession
        )
        session._installPCMInputForTesting()
        session._startMessageListenerForTesting()
        session._startAudioDrainTaskForTesting()
        #expect(await waitForMainActorCondition { !transport.sentMessages.isEmpty })
        if !beforeReady {
            incoming.continuation.yield(.dictationReady(provider: nil))
            #expect(session._enqueuePCMForTesting(Data([1])))
            #expect(await waitForMainActorCondition { !transport.sentAudio.isEmpty })
        }
        var failed = false
        let events = Task {
            do { for try await _ in session.events {} }
            catch { failed = true }
        }
        incoming.continuation.finish()
        let didFail = await waitForMainActorCondition { failed }
        #expect(didFail, "Transport EOF must terminate the recording, not leave readiness/final waiting")
        // Cleanup after the assertion is not the source of the failure signal.
        events.cancel()
        await session.cancel()
        provider.cancelPreparation()
    }

    @Test func makeSessionThrowsWhenConnectionMissing() async throws {
        let (context, _) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        _ = installTestDictationTransport(on: provider)
        let preparation = try await provider.prepareSession(context: context)

        // Create context without connection
        let noConnectionContext = VoiceProviderContext(
            locale: Locale(identifier: "en-US"),
            source: "test",
            serverCredentials: Self.makeCredentials()
        )

        #expect(throws: VoiceInputError.self) {
            try provider.makeSession(context: noConnectionContext, preparation: preparation)
        }

        // Cleanup
        provider.invalidateCache()
    }

    // MARK: - invalidateCache after prepare

    @Test func invalidateCacheClearsActiveState() async throws {
        let (context, _) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        _ = installTestDictationTransport(on: provider)
        let preparation = try await provider.prepareSession(context: context)

        // Invalidate clears readiness task and recording state
        provider.invalidateCache()

        // makeSession should now fail because state was cleared
        #expect(throws: VoiceInputError.self) {
            try provider.makeSession(context: context, preparation: preparation)
        }
    }

    // MARK: - cancelPreparation after prepare

    @Test func cancelPreparationClearsActiveState() async throws {
        let (context, _) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        _ = installTestDictationTransport(on: provider)
        let preparation = try await provider.prepareSession(context: context)

        provider.cancelPreparation()

        #expect(throws: VoiceInputError.self) {
            try provider.makeSession(context: context, preparation: preparation)
        }
    }

    // MARK: - metricTags

    @Test func metricTagsIncludeUnknownWhenNoServerInfo() async throws {
        let (context, _) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        _ = installTestDictationTransport(on: provider)
        let preparation = try await provider.prepareSession(context: context)

        // At setup time, stt_backend and model are unknown
        #expect(preparation.setupMetricTags["stt_backend"] == "unknown")
        #expect(preparation.setupMetricTags["model"] == "unknown")
        #expect(preparation.setupMetricTags["live_preview"] == "1")

        provider.invalidateCache()
    }
}

// MARK: - Session Message Listener Tests

@Suite("OppiDictationSession message listener")
@MainActor
struct OppiDictationSessionMessageListenerTests {

    @Test func dictationResultYieldsReplaceFinalTranscript() async {
        let transport = TestDictationTransport()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let collectTask = Task {
            await collectEvents(from: session.events, count: 1)
        }

        session._startMessageListenerForTesting()
        messageCont.yield(.dictationResult(text: "Hello world", snap: false))
        // Send final to cleanly end the stream
        messageCont.yield(.dictationFinal(text: "Hello world"))

        let events = await collectTask.value
        #expect(events.count >= 1)
        #expect(events[0] == .replaceFinalTranscript("Hello world"))
    }

    @Test func dictationResultWithSnapYieldsSnapEvent() async {
        let transport = TestDictationTransport()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let collectTask = Task {
            await collectEvents(from: session.events, count: 1)
        }

        session._startMessageListenerForTesting()
        messageCont.yield(.dictationResult(text: "Snapped text", snap: true))
        messageCont.yield(.dictationFinal(text: "Snapped text"))

        let events = await collectTask.value
        #expect(events.count >= 1)
        #expect(events[0] == .replaceFinalTranscript("Snapped text", snap: true))
    }

    @Test func identicalDictationFinalStillYieldsSettledTranscriptEvent() async {
        let transport = TestDictationTransport()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let collectTask = Task {
            await collectAllEvents(from: session.events)
        }

        session._startMessageListenerForTesting()
        messageCont.yield(.dictationResult(text: "Hello world", snap: false))
        messageCont.yield(.dictationFinal(text: "Hello world"))

        let (events, error) = await collectTask.value
        #expect(error == nil)
        let transcriptEvents = events.filter {
            if case .replaceFinalTranscript = $0 { return true }
            return false
        }
        #expect(transcriptEvents.count == 2)
        #expect(transcriptEvents[0] == .replaceFinalTranscript("Hello world"))
        #expect(transcriptEvents[1] == .replaceFinalTranscript("Hello world", snap: true))
    }

    @Test func dictationFinalYieldsSettledTranscriptAndFinishes() async {
        let transport = TestDictationTransport()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let collectTask = Task {
            await collectAllEvents(from: session.events)
        }

        session._startMessageListenerForTesting()
        messageCont.yield(.dictationFinal(text: "Final transcript"))

        let (events, error) = await collectTask.value
        // Should have received the settled final transcript
        #expect(events.contains(.replaceFinalTranscript("Final transcript", snap: true)))
        // Stream should finish cleanly (no error)
        #expect(error == nil)
    }

    @Test func emptyDictationFinalDoesNotYieldEvent() async {
        let transport = TestDictationTransport()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let collectTask = Task {
            await collectAllEvents(from: session.events)
        }

        session._startMessageListenerForTesting()
        messageCont.yield(.dictationFinal(text: ""))

        let (events, error) = await collectTask.value
        // Empty final text should not produce a transcript event
        #expect(events.isEmpty)
        #expect(error == nil)
    }

    @Test func fatalDictationErrorFinishesWithError() async {
        let transport = TestDictationTransport()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let collectTask = Task {
            await collectAllEvents(from: session.events)
        }

        session._startMessageListenerForTesting()
        messageCont.yield(.dictationError(error: "STT crashed", fatal: true))

        let (_, error) = await collectTask.value
        #expect(error != nil)
        #expect(error?.localizedDescription.contains("STT crashed") == true)
    }

    @Test func nonFatalDictationErrorContinuesStream() async {
        let transport = TestDictationTransport()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let collectTask = Task {
            await collectAllEvents(from: session.events)
        }

        session._startMessageListenerForTesting()
        // Non-fatal error should not end the stream
        messageCont.yield(.dictationError(error: "transient hiccup", fatal: false))
        // Stream should still accept more messages
        messageCont.yield(.dictationResult(text: "After error", snap: false))
        messageCont.yield(.dictationFinal(text: "After error"))

        let (events, error) = await collectTask.value
        #expect(error == nil)
        #expect(events.contains(.replaceFinalTranscript("After error")))
    }

    @Test func dictationReadyDoesNotYieldEvent() async {
        let transport = TestDictationTransport()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let collectTask = Task {
            await collectAllEvents(from: session.events)
        }

        session._startMessageListenerForTesting()
        messageCont.yield(.dictationReady(provider: DictationProviderInfo(sttProvider: "test", sttModel: "test")))
        messageCont.yield(.dictationFinal(text: "Done"))

        let (events, _) = await collectTask.value
        // dictationReady should not produce any VoiceSessionEvent transcript
        let transcriptEvents = events.filter {
            if case .replaceFinalTranscript("Done", _, _, _) = $0 { return false }
            if case .providerMetricTags = $0 { return false }
            return true
        }
        #expect(transcriptEvents.isEmpty)
    }

    @Test func multipleResultsBeforeFinal() async {
        let transport = TestDictationTransport()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let collectTask = Task {
            await collectAllEvents(from: session.events)
        }

        session._startMessageListenerForTesting()
        messageCont.yield(.dictationResult(text: "Hello", snap: false))
        messageCont.yield(.dictationResult(text: "Hello world", snap: false))
        messageCont.yield(.dictationResult(text: "Hello world how", snap: false))
        messageCont.yield(.dictationFinal(text: "Hello world how are you"))

        let (events, error) = await collectTask.value
        #expect(error == nil)
        // Should have 4 replaceFinalTranscript events (3 results + 1 final)
        let transcriptEvents = events.filter {
            if case .replaceFinalTranscript = $0 { return true }
            return false
        }
        #expect(transcriptEvents.count == 4)
    }

    // MARK: - Helpers

    private func collectEvents(
        from events: AsyncThrowingStream<VoiceSessionEvent, Error>,
        count: Int
    ) async -> [VoiceSessionEvent] {
        var collected: [VoiceSessionEvent] = []
        do {
            for try await event in events {
                collected.append(event)
                if collected.count >= count { break }
            }
        } catch {}
        return collected
    }

    private func collectAllEvents(
        from events: AsyncThrowingStream<VoiceSessionEvent, Error>
    ) async -> ([VoiceSessionEvent], Error?) {
        var collected: [VoiceSessionEvent] = []
        do {
            for try await event in events {
                collected.append(event)
            }
            return (collected, nil)
        } catch {
            return (collected, error)
        }
    }
}

// MARK: - Session Audio Drain Tests

@Suite("Dictation first-audio startup")
@MainActor
struct DictationCaptureStartupTests {
    @Test(arguments: TestOrdinaryConversionFailure.allCases, [false, true])
    func ordinaryConversionFailureCannotRecoverOrBecomeSuccessfulStop(
        failureKind: TestOrdinaryConversionFailure, feedAfterFailure: Bool
    ) async throws {
        let transport = TestDictationTransport()
        let incoming = AsyncStream<ServerMessage>.makeStream()
        // Healthy Stop would settle normally. Failed capture must win over this final.
        transport.onSendDictation = { message in
            if case .dictationStop = message { incoming.continuation.yield(.dictationFinal(text: "incomplete")) }
        }
        let session = OppiDictationSession(
            transport: transport, readinessTask: Task { nil }, messages: incoming.stream
        )
        session._installPCMInputForTesting()
        session._startMessageListenerForTesting()
        session._startAudioDrainTaskForTesting()
        let source = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(TestOrdinaryConverter(from: source, to: target))
        converter.failure = failureKind
        var failAllocation = failureKind == .allocation
        func feed(_ buffer: AVAudioPCMBuffer) -> Bool {
            session._feedCaptureBufferForTesting(buffer, converter: converter) { format, capacity in
                failAllocation ? nil : AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
            }
        }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 128))
        buffer.frameLength = 128
        #expect(!feed(buffer))
        converter.failure = nil
        failAllocation = false
        if feedAfterFailure { #expect(!feed(buffer)) }
        await session.stop()
        var failure: Error?
        do { for try await _ in session.events {} }
        catch { failure = error }
        #expect(failure != nil, "A final response must not hide ordinary capture loss")
        if failureKind == .nsError {
            #expect((failure as NSError?)?.domain == "TestOrdinaryConverter")
        }
        #expect(transport.sentAudio.isEmpty)
        #expect(transport.closeCount == 1)
    }

    @Test func bufferedConversionWithoutOutputCanDeliverTheNextBuffer() async throws {
        let audio = AsyncStream<DictationAudioInput>.makeStream()
        let events = AsyncThrowingStream<VoiceSessionEvent, Error>.makeStream()
        let source = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(TestOrdinaryConverter(from: source, to: target))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 128))
        buffer.frameLength = 128
        converter.buffered = true
        #expect(DictationAudioEngineHelper.feedCaptureBuffer(
            buffer, converter: converter, inputFormat: source, targetFormat: target,
            into: audio.continuation, events: events.continuation
        ) == nil)
        converter.buffered = false
        #expect(DictationAudioEngineHelper.feedCaptureBuffer(
            buffer, converter: converter, inputFormat: source, targetFormat: target,
            into: audio.continuation, events: events.continuation
        ) != nil)
        audio.continuation.finish()
        events.continuation.finish()
        do { for try await _ in events.stream {} }
        catch { Issue.record("Buffered/no-output is not a converter failure: \(error)") }
        var delivered = 0
        for await _ in audio.stream { delivered += 1 }
        #expect(delivered == 1)
    }

    @Test func stoppedEngineIsRebuiltBeforeSuccess() async throws {
        var starts = 0
        var stops = 0
        try await DictationAudioEngineHelper.startWithFirstAudio(
            start: { starts += 1 }, hasAudio: { starts == 2 },
            isRunning: { starts == 2 }, stop: { stops += 1 },
            isCancelled: { false }, sleep: { _ in }
        )
        #expect(starts == 2)
        #expect(stops == 1)
    }

    @Test func runningWithoutAudioIsNotSuccess() async {
        var starts = 0
        var stops = 0
        await #expect(throws: (any Error).self) {
            try await DictationAudioEngineHelper.startWithFirstAudio(
                start: { starts += 1 }, hasAudio: { false }, isRunning: { true },
                stop: { stops += 1 }, isCancelled: { false }, sleep: { _ in }
            )
        }
        #expect(starts == 2)
        #expect(stops == 2)
    }

    @Test func firstAudioCompletesWithoutRetry() async throws {
        var starts = 0
        var waits = 0
        try await DictationAudioEngineHelper.startWithFirstAudio(
            start: { starts += 1 }, hasAudio: { waits > 0 }, isRunning: { true },
            stop: { Issue.record("Healthy capture must not stop") },
            isCancelled: { false }, sleep: { _ in waits += 1 }
        )
        #expect(starts == 1)
        #expect(waits > 0)
    }

    @Test func alreadyLatchedPCMDoesNotPoll() async throws {
        try await DictationAudioEngineHelper.startWithFirstAudio(
            start: {}, hasAudio: { true }, isRunning: { true },
            stop: { Issue.record("Healthy capture must not stop") },
            isCancelled: { false },
            sleep: { _ in Issue.record("Latched first PCM must not wait") }
        )
    }

    @Test func firstAudioPollStaysShortEnoughForWarmEnablement() async throws {
        var intervals: [Duration] = []
        try await DictationAudioEngineHelper.startWithFirstAudio(
            start: {}, hasAudio: { !intervals.isEmpty }, isRunning: { true },
            stop: { Issue.record("Healthy capture must not stop") },
            isCancelled: { false }, sleep: { intervals.append($0) }
        )
        #expect(intervals == [.milliseconds(10)])
    }

    @Test func cancellationDuringReadinessStopsWithoutRetry() async {
        var cancelled = false
        var starts = 0
        var stops = 0
        await #expect(throws: CancellationError.self) {
            try await DictationAudioEngineHelper.startWithFirstAudio(
                start: { starts += 1 }, hasAudio: { false }, isRunning: { true },
                stop: { stops += 1 }, isCancelled: { cancelled },
                sleep: { _ in cancelled = true }
            )
        }
        #expect(starts == 1)
        #expect(stops == 1)
    }

    @Test func failedStartsAreBoundedAndCleanedUp() async {
        var starts = 0
        var stops = 0
        await #expect(throws: TestVoiceError.self) {
            try await DictationAudioEngineHelper.startWithFirstAudio(
                start: { starts += 1; throw TestVoiceError("hardware changed") },
                hasAudio: { false }, isRunning: { false }, stop: { stops += 1 },
                isCancelled: { false }, sleep: { _ in }
            )
        }
        #expect(starts == 2)
        #expect(stops == 2)
    }

    @Test func cancellationBeforeStartDoesNotAcquireMicrophone() async {
        await #expect(throws: CancellationError.self) {
            try await DictationAudioEngineHelper.startWithFirstAudio(
                start: { Issue.record("Cancelled capture must not start") },
                hasAudio: { false }, isRunning: { false }, stop: {},
                isCancelled: { true }, sleep: { _ in }
            )
        }
    }
}

@Suite("OppiDictationSession audio drain")
@MainActor
struct OppiDictationSessionAudioDrainTests {

    @Test func delayedReadinessPreservesBeginningAndEveryPCMChunk() async {
        let transport = TestDictationTransport()
        var sent: [Data] = []
        transport.onSendAudio = { sent.append($0) }
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let (messages, _) = AsyncStream<ServerMessage>.makeStream()
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task {
                for await _ in ready { break }
                return nil
            },
            messages: messages
        )
        session._installPCMInputForTesting()
        session._startAudioDrainTaskForTesting()
        // Roughly nine seconds at a 48kHz / 1024-frame tap: inside the 10s
        // readiness budget, but far beyond the old 32-chunk queue.
        let chunks = (0..<420).map { Data(repeating: UInt8($0 % 251), count: 682) }
        for chunk in chunks {
            #expect(session._enqueuePCMForTesting(chunk))
            await Task.yield()
        }
        #expect(sent.isEmpty)
        readyContinuation.yield(())
        readyContinuation.finish()
        await session._waitForAudioDrainForTesting()
        #expect(sent == chunks)
        await session.cancel()
    }

    @Test func transientPCMOverflowCannotResumeAndReportSuccessfulTake() async {
        let transport = TestDictationTransport()
        let (messages, _) = AsyncStream<ServerMessage>.makeStream()
        let session = OppiDictationSession(
            transport: transport, readinessTask: Task { nil }, messages: messages
        )
        session._installPCMInputForTesting()
        for _ in 0..<DictationAudioEngineHelper.pcmBufferLimit {
            #expect(session._enqueuePCMForTesting(Data([1])))
        }
        #expect(!session._enqueuePCMForTesting(Data([2])))
        session._startAudioDrainTaskForTesting()
        await session._waitForAudioDrainForTesting()
        #expect(!session._enqueuePCMForTesting(Data([3])))
        await session.cancel()
        let error = await consumeStreamError(from: session.events)
        #expect(error?.localizedDescription == "Dictation couldn’t continue. Please try again.")
    }

    @Test func preReadyByteBudgetOverflowFailsWithoutSendingTruncatedAudio() async {
        let transport = TestDictationTransport()
        var sent: [Data] = []
        transport.onSendAudio = { sent.append($0) }
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let (messages, _) = AsyncStream<ServerMessage>.makeStream()
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task {
                for await _ in ready { break }
                return nil
            }, messages: messages
        )
        session._installPCMInputForTesting()
        session._startAudioDrainTaskForTesting()
        // Only two queue slots; fail the separate lossless pre-ready byte budget.
        #expect(session._enqueuePCMForTesting(Data(repeating: 1, count: OppiDictationSession.preReadyPCMByteLimit)))
        #expect(session._enqueuePCMForTesting(Data([2])))
        let error = await consumeStreamError(from: session.events)
        #expect(error?.localizedDescription == "Dictation couldn’t continue. Please try again.")
        #expect(!session._enqueuePCMForTesting(Data([3])))
        readyContinuation.yield(())
        readyContinuation.finish()
        await session._waitForAudioDrainForTesting()
        #expect(sent.isEmpty)
        await session.cancel()
    }

    @Test func stopBeforeReadinessFlushesAllAudioBeforeDictationStop() async {
        let transport = TestDictationTransport()
        var sent: [Data] = []
        var stopSent = false
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let (messages, messageContinuation) = AsyncStream<ServerMessage>.makeStream()
        transport.onSendAudio = { sent.append($0) }
        transport.onSendDictation = { message in
            if case .dictationStop = message {
                stopSent = true
                #expect(sent == [Data([1]), Data([2])])
                messageContinuation.yield(.dictationFinal(text: "done"))
            }
        }
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task {
                for await _ in ready { break }
                return nil
            }, messages: messages
        )
        session._installPCMInputForTesting()
        session._startAudioDrainTaskForTesting()
        session._startMessageListenerForTesting()
        #expect(session._enqueuePCMForTesting(Data([1])))
        #expect(session._enqueuePCMForTesting(Data([2])))
        let stopTask = Task { await session.stop() }
        await Task.yield()
        #expect(sent.isEmpty)
        #expect(!stopSent)
        readyContinuation.yield(())
        readyContinuation.finish()
        await stopTask.value
        #expect(stopSent)
    }

    @Test func readinessFailureSurfacesErrorToEventStream() async {
        let transport = TestDictationTransport()
        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let readinessError = VoiceInputError.remoteRequestTimedOut
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task<DictationProviderInfo?, Error> { throw readinessError },
            messages: messageStream
        )

        let errorTask = Task {
            await consumeStreamError(from: session.events)
        }

        session._setPendingAudioStreamForTesting(audioStream)
        session._startAudioDrainTaskForTesting()
        audioCont.finish()

        let error = await errorTask.value
        #expect(error != nil)
    }

    @Test func providerMetricTagsEmittedWhenInfoAvailable() async {
        let transport = TestDictationTransport()
        transport.onSendAudio = { _ in }

        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let info = DictationProviderInfo(sttProvider: "mlx-server", sttModel: "Qwen3-ASR")
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task<DictationProviderInfo?, Error> { info },
            messages: messageStream
        )

        let collectTask = Task { () -> [VoiceSessionEvent] in
            var events: [VoiceSessionEvent] = []
            do {
                for try await event in session.events {
                    events.append(event)
                    // Collect the metric tag event then stop
                    if case .providerMetricTags = event { break }
                }
            } catch {}
            return events
        }

        session._setPendingAudioStreamForTesting(audioStream)
        session._startAudioDrainTaskForTesting()

        // Give drain task time to process readiness
        try? await Task.sleep(for: .milliseconds(50))
        audioCont.finish()
        messageCont.finish()

        let events = await collectTask.value
        let metricEvents = events.filter {
            if case .providerMetricTags = $0 { return true }
            return false
        }
        #expect(metricEvents.count == 1)
        if case .providerMetricTags(let tags) = metricEvents.first {
            #expect(tags["stt_backend"] == "mlx-server")
            #expect(tags["model"] == "Qwen3-ASR")
        }
    }

    @Test func noMetricTagsWhenInfoIsNil() async {
        let transport = TestDictationTransport()
        transport.onSendAudio = { _ in }

        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task<DictationProviderInfo?, Error> { nil },
            messages: messageStream
        )

        session._setPendingAudioStreamForTesting(audioStream)
        session._startAudioDrainTaskForTesting()

        // Give drain task time to process readiness, then close everything
        try? await Task.sleep(for: .milliseconds(50))
        audioCont.finish()

        // End the message stream to finish the session
        session._startMessageListenerForTesting()
        messageCont.yield(.dictationFinal(text: "done"))

        var metricTagCount = 0
        do {
            for try await event in session.events {
                if case .providerMetricTags = event {
                    metricTagCount += 1
                }
            }
        } catch {}
        #expect(metricTagCount == 0)
    }

    @Test func audioChunksForwardedToConnection() async {
        var sentChunks: [Data] = []
        let transport = TestDictationTransport()
        transport.onSendAudio = { data in
            sentChunks.append(data)
        }

        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task<DictationProviderInfo?, Error> { nil },
            messages: messageStream
        )

        session._setPendingAudioStreamForTesting(audioStream)
        session._startAudioDrainTaskForTesting()

        // Yield some audio chunks
        audioCont.yield(Data([0x01, 0x02, 0x03]))
        audioCont.yield(Data([0x04, 0x05]))
        audioCont.finish()

        // Give the drain task time to forward chunks
        try? await Task.sleep(for: .milliseconds(100))

        #expect(sentChunks.count == 2)
        #expect(sentChunks[0] == Data([0x01, 0x02, 0x03]))
        #expect(sentChunks[1] == Data([0x04, 0x05]))
    }

    @Test func audioContinuesAfterCommittedResultUntilStop() async {
        var sentChunks: [Data] = []
        let transport = TestDictationTransport()
        transport.onSendAudio = { data in
            sentChunks.append(data)
        }
        transport.onSendDictation = { _ in }

        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task<DictationProviderInfo?, Error> { nil },
            messages: messageStream
        )
        session._setPendingAudioStreamForTesting(audioStream)
        session._startAudioDrainTaskForTesting()
        session._startMessageListenerForTesting()

        let eventsTask = Task { () -> [VoiceSessionEvent] in
            var events: [VoiceSessionEvent] = []
            do {
                for try await event in session.events {
                    events.append(event)
                }
            } catch {}
            return events
        }

        audioCont.yield(Data([0x01]))
        messageCont.yield(.dictationResult(text: "one", snap: false))
        try? await Task.sleep(for: .milliseconds(30))
        audioCont.yield(Data([0x02]))
        audioCont.yield(Data([0x03]))
        try? await Task.sleep(for: .milliseconds(30))

        #expect(sentChunks == [Data([0x01]), Data([0x02]), Data([0x03])])

        audioCont.finish()
        messageCont.yield(.dictationFinal(text: "one two three"))
        let events = await eventsTask.value
        let transcriptEvents = events.compactMap { event -> String? in
            if case .replaceFinalTranscript(let text, _, _, _) = event {
                return text
            }
            return nil
        }

        #expect(transcriptEvents == ["one", "one two three"])
    }

    private func consumeStreamError(
        from events: AsyncThrowingStream<VoiceSessionEvent, Error>
    ) async -> Error? {
        do {
            for try await _ in events {}
            return nil
        } catch {
            return error
        }
    }
}

// MARK: - Session Cancel / Stop Tests

@Suite("OppiDictationSession cancel and stop")
@MainActor
struct OppiDictationSessionCancelStopTests {

    @Test func cancelSendsDictationCancel() async {
        var sentMessages: [ClientMessage] = []
        let transport = TestDictationTransport()
        transport.onSendDictation = { msg in
            sentMessages.append(msg)
        }

        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        await session.cancel()

        let hasCancelMessage = sentMessages.contains { msg in
            if case .dictationCancel = msg { return true }
            return false
        }
        #expect(hasCancelMessage)
    }

    @Test func cancelIsIdempotent() async {
        var cancelCount = 0
        let transport = TestDictationTransport()
        transport.onSendDictation = { msg in
            if case .dictationCancel = msg { cancelCount += 1 }
        }

        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        await session.cancel()
        await session.cancel()

        // Should only send cancel once (second call is a no-op due to stopped guard)
        #expect(cancelCount == 1)
    }

    @Test func stopSendsDictationStop() async {
        var sentMessages: [ClientMessage] = []
        let transport = TestDictationTransport()
        transport.onSendDictation = { msg in
            sentMessages.append(msg)
        }

        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        // Start message listener so stop() can await it
        session._startMessageListenerForTesting()

        // Stop will send dictation_stop and wait for message listener to finish
        let stopTask = Task {
            await session.stop()
        }

        // Give stop a moment to send the message, then end the stream
        try? await Task.sleep(for: .milliseconds(50))
        messageCont.yield(.dictationFinal(text: "final"))

        await stopTask.value

        let hasStopMessage = sentMessages.contains { msg in
            if case .dictationStop = msg { return true }
            return false
        }
        #expect(hasStopMessage)
    }

    @Test func stopIsIdempotent() async {
        var stopCount = 0
        let transport = TestDictationTransport()
        transport.onSendDictation = { msg in
            if case .dictationStop = msg { stopCount += 1 }
        }

        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        session._startMessageListenerForTesting()

        let stopTask = Task {
            await session.stop()
        }
        try? await Task.sleep(for: .milliseconds(50))
        messageCont.yield(.dictationFinal(text: ""))
        await stopTask.value

        await session.stop()
        #expect(stopCount == 1)
    }
}

// MARK: - Error Surface Tests

@Suite("Dictation error surfacing")
@MainActor
struct DictationErrorSurfacingTests {

    @Test func webSocketNotConnectedMapsToDictationConnectionLost() async {
        let transport = TestDictationTransport()
        transport.onSendAudio = { _ in
            throw WebSocketError.notConnected
        }

        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let errorTask = Task {
            await consumeStreamError(from: session.events)
        }

        session._setPendingAudioStreamForTesting(audioStream)
        session._startAudioDrainTaskForTesting()
        audioCont.yield(Data([0x01]))
        audioCont.finish()

        let error = await errorTask.value
        #expect(error?.localizedDescription == "Dictation connection lost")
    }

    @Test func webSocketSendTimeoutPreservesOriginalError() async {
        let transport = TestDictationTransport()
        transport.onSendAudio = { _ in
            throw WebSocketError.sendTimeout
        }

        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let session = OppiDictationSession(
            transport: transport,
            readinessTask: Task { nil },
            messages: messageStream
        )

        let errorTask = Task {
            await consumeStreamError(from: session.events)
        }

        session._setPendingAudioStreamForTesting(audioStream)
        session._startAudioDrainTaskForTesting()
        audioCont.yield(Data([0x01]))
        audioCont.finish()

        let error = await errorTask.value
        // sendTimeout is NOT notConnected, so it should NOT be mapped to "Dictation connection lost"
        #expect(error != nil)
        #expect(error?.localizedDescription != "Dictation connection lost")
    }

    @Test func cancelledReadinessDoesNotSurfaceError() async {
        let transport = TestDictationTransport()
        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, _) = AsyncStream.makeStream(of: Data.self)

        let readinessTask = Task<DictationProviderInfo?, Error> {
            // Simulate an in-flight readiness probe that is cancelled by the test.
            while true {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let session = OppiDictationSession(
            transport: transport,
            readinessTask: readinessTask,
            messages: messageStream
        )

        session._setPendingAudioStreamForTesting(audioStream)
        session._startAudioDrainTaskForTesting()

        // Cancel the readiness task
        readinessTask.cancel()

        // Give it time to process cancellation
        try? await Task.sleep(for: .milliseconds(100))

        // The event stream should NOT have thrown an error for cancellation
        // (CancellationError is handled as a clean exit)
        // We verify by checking that we can still iterate without getting a thrown error
        var gotError = false
        let checkTask = Task {
            do {
                for try await _ in session.events {
                    break
                }
            } catch {
                gotError = true
            }
        }

        // Give it a moment then cancel the check
        try? await Task.sleep(for: .milliseconds(50))
        checkTask.cancel()
        #expect(!gotError)
    }

    private func consumeStreamError(
        from events: AsyncThrowingStream<VoiceSessionEvent, Error>
    ) async -> Error? {
        do {
            for try await _ in events {}
            return nil
        } catch {
            return error
        }
    }
}

// MARK: - VoiceSessionEvent Equatable (test support)

extension VoiceSessionEvent: @retroactive Equatable {
    public static func == (lhs: VoiceSessionEvent, rhs: VoiceSessionEvent) -> Bool {
        switch (lhs, rhs) {
        case (.partialTranscript(let a), .partialTranscript(let b)):
            return a == b
        case (.appendFinalTranscript(let a), .appendFinalTranscript(let b)):
            return a == b
        case (
            .replaceFinalTranscript(let a, let snapA, let committedA, let activeA),
            .replaceFinalTranscript(let b, let snapB, let committedB, let activeB)
        ):
            return a == b
                && snapA == snapB
                && committedA == committedB
                && activeA == activeB
        case (.remoteChunkTelemetry, .remoteChunkTelemetry):
            return true
        case (.providerMetricTags(let a), .providerMetricTags(let b)):
            return a == b
        default:
            return false
        }
    }
}
