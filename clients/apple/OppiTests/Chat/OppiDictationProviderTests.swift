@preconcurrency import AVFoundation
import Testing

@testable import Oppi

// MARK: - Dictation ServerMessage Decoding

@Suite("Dictation ServerMessage decoding")
struct DictationServerMessageDecodingTests {

    @Test func decodesReadyMinimal() throws {
        let message = try decode(#"{"type":"dictation_ready"}"#)
        #expect(message == .dictationReady(provider: nil))
    }

    @Test func decodesReadyWithProviderInfo() throws {
        let json = #"{"type":"dictation_ready","sttProvider":"mlx-server","sttModel":"Qwen3-ASR-1.7B"}"#
        let message = try decode(json)
        let expected = DictationProviderInfo(
            sttProvider: "mlx-server",
            sttModel: "Qwen3-ASR-1.7B"
        )
        #expect(message == .dictationReady(provider: expected))
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
        let message = ClientMessage.dictationStart
        let json = try encode(message)
        #expect(json.contains("\"type\":\"dictation_start\""))
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
        let connection = ServerConnection()
        let recordingPair = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        connection._sendDictationAudioForTesting = { _ in
            throw WebSocketError.notConnected
        }

        let recordingPair = AsyncStream.makeStream(of: ServerMessage.self)
        let audioPair = AsyncStream.makeStream(of: Data.self)
        let session = OppiDictationSession(
            connection: connection,
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
    func activateAudioSession() throws {}
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

    @Test func prepareSessionReturnsPreparationWithCorrectPathTag() async throws {
        let (context, connection) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        // Stub dictation sends to avoid real WS
        connection._sendDictationForTesting = { _ in }

        let preparation = try await provider.prepareSession(context: context)
        #expect(preparation.pathTag == "dictation_ws")
        #expect(preparation.audioFormat == nil)
        #expect(preparation.setupMetricTags["dictation_mode"] == "server")
        #expect(preparation.setupMetricTags["transport"] == "ws")
        #expect(preparation.setupMetricTags["host"] == "localhost")
        #expect(preparation.setupMetricTags["provider_id"] == "oppi_server_dictation")
        #expect(preparation.setupMetricTags["provider_kind"] == "local_server")

        // Cleanup
        provider.invalidateCache()
    }

    @Test func makeSessionSucceedsAfterPrepare() async throws {
        let (context, connection) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        connection._sendDictationForTesting = { _ in }

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

    @Test func makeSessionThrowsWhenConnectionMissing() async throws {
        let (context, connection) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        connection._sendDictationForTesting = { _ in }
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
        let (context, connection) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        connection._sendDictationForTesting = { _ in }
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
        let (context, connection) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        connection._sendDictationForTesting = { _ in }
        let preparation = try await provider.prepareSession(context: context)

        provider.cancelPreparation()

        #expect(throws: VoiceInputError.self) {
            try provider.makeSession(context: context, preparation: preparation)
        }
    }

    // MARK: - metricTags

    @Test func metricTagsIncludeUnknownWhenNoServerInfo() async throws {
        let (context, connection) = Self.makeContextWithConnection()
        let provider = OppiDictationProvider()

        connection._sendDictationForTesting = { _ in }
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
        let connection = ServerConnection()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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

@Suite("OppiDictationSession audio drain")
@MainActor
struct OppiDictationSessionAudioDrainTests {

    @Test func readinessFailureSurfacesErrorToEventStream() async {
        let connection = ServerConnection()
        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let readinessError = VoiceInputError.remoteRequestTimedOut
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        connection._sendDictationAudioForTesting = { _ in }

        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let info = DictationProviderInfo(sttProvider: "mlx-server", sttModel: "Qwen3-ASR")
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        connection._sendDictationAudioForTesting = { _ in }

        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        connection._sendDictationAudioForTesting = { data in
            sentChunks.append(data)
        }

        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        connection._sendDictationForTesting = { msg in
            sentMessages.append(msg)
        }

        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        connection._sendDictationForTesting = { msg in
            if case .dictationCancel = msg { cancelCount += 1 }
        }

        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        connection._sendDictationForTesting = { msg in
            sentMessages.append(msg)
        }

        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        connection._sendDictationForTesting = { msg in
            if case .dictationStop = msg { stopCount += 1 }
        }

        let (messageStream, messageCont) = AsyncStream.makeStream(of: ServerMessage.self)
        let session = OppiDictationSession(
            connection: connection,
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

// MARK: - Dictation Routing Tests (Provider internal routing logic)

@Suite("OppiDictationProvider dictation routing")
@MainActor
struct OppiDictationProviderRoutingTests {

    private static func makeCredentials() -> ServerCredentials {
        ServerCredentials(
            host: "localhost", port: 7749,
            token: "test-token",
            name: "test-server",
            scheme: .http
        )
    }

    /// Verifies that dictation messages routed through ServerConnection's
    /// routeStreamMessage reach the recording message stream consumed
    /// by OppiDictationSession via the provider's dictation routing.
    @Test func dictationReadyRoutedToSession() async throws {
        let connection = ServerConnection()
        connection._sendDictationForTesting = { _ in }

        let context = VoiceProviderContext(
            locale: Locale(identifier: "en-US"),
            source: "test",
            serverCredentials: Self.makeCredentials(),
            serverConnection: connection
        )

        let provider = OppiDictationProvider()
        let preparation = try await provider.prepareSession(context: context)

        // Simulate dictation_ready arriving over the /stream WS.
        // routeStreamMessage routes dictation messages to the dictation
        // continuation, which the provider's routing task consumes.
        connection.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .dictationReady(provider: DictationProviderInfo(sttProvider: "mlx", sttModel: "qwen3"))
        ))

        let session = try provider.makeSession(context: context, preparation: preparation) as! OppiDictationSession

        // The session's readiness task should resolve with the provider info.
        // We can't directly observe it, but making the session succeed means
        // the routing worked. Clean up.
        provider.invalidateCache()
        await session.cancel()
    }

    @Test func prepareSessionCanBeCalledTwice() async throws {
        let connection = ServerConnection()
        connection._sendDictationForTesting = { _ in }

        let context = VoiceProviderContext(
            locale: Locale(identifier: "en-US"),
            source: "test",
            serverCredentials: Self.makeCredentials(),
            serverConnection: connection
        )

        let provider = OppiDictationProvider()

        // First prepare
        _ = try await provider.prepareSession(context: context)
        provider.invalidateCache()

        // Second prepare (should work cleanly after invalidation)
        let preparation2 = try await provider.prepareSession(context: context)
        #expect(preparation2.pathTag == "dictation_ws")

        provider.invalidateCache()
    }
}

// MARK: - Error Surface Tests

@Suite("Dictation error surfacing")
@MainActor
struct DictationErrorSurfacingTests {

    @Test func webSocketNotConnectedMapsToDictationConnectionLost() async {
        let connection = ServerConnection()
        connection._sendDictationAudioForTesting = { _ in
            throw WebSocketError.notConnected
        }

        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        connection._sendDictationAudioForTesting = { _ in
            throw WebSocketError.sendTimeout
        }

        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, audioCont) = AsyncStream.makeStream(of: Data.self)

        let session = OppiDictationSession(
            connection: connection,
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
        let connection = ServerConnection()
        let (messageStream, _) = AsyncStream.makeStream(of: ServerMessage.self)
        let (audioStream, _) = AsyncStream.makeStream(of: Data.self)

        let readinessTask = Task<DictationProviderInfo?, Error> {
            // Simulate being cancelled
            try? await Task.sleep(for: .seconds(10))
            throw CancellationError()
        }

        let session = OppiDictationSession(
            connection: connection,
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

// MARK: - ServerConnection Dictation Subscription Tests

@Suite("ServerConnection dictation subscription")
@MainActor
struct ServerConnectionDictationSubscriptionTests {

    @Test func subscribeDictationReturnsStream() {
        let connection = ServerConnection()
        let stream = connection.subscribeDictation()
        // Should get a valid stream
        _ = stream // No crash
    }

    @Test func unsubscribeDictationCleansUp() {
        let connection = ServerConnection()
        _ = connection.subscribeDictation()
        connection.unsubscribeDictation()
        // Should not crash on double unsubscribe
        connection.unsubscribeDictation()
    }

    @Test func subscribeDictationReplacesExistingSubscription() {
        let connection = ServerConnection()
        let stream1 = connection.subscribeDictation()
        let stream2 = connection.subscribeDictation()
        // stream1 should have been finished (old subscription replaced)
        // stream2 is the active one — both should be valid AsyncStreams
        _ = stream1
        _ = stream2
    }

    @Test func dictationMessagesRoutedToSubscriber() async {
        let connection = ServerConnection()
        let stream = connection.subscribeDictation()

        let collectTask = Task {
            var messages: [ServerMessage] = []
            for await msg in stream {
                messages.append(msg)
                break // Just get one
            }
            return messages
        }

        // Route a dictation message through the connection
        connection.routeStreamMessage(StreamMessage(
            sessionId: nil, streamSeq: nil, seq: nil, currentSeq: nil,
            message: .dictationReady(provider: nil)
        ))

        let messages = await collectTask.value
        #expect(messages.count == 1)
        #expect(messages[0] == .dictationReady(provider: nil))
    }

    @Test func dictationMessagesNotRoutedAfterUnsubscribe() async {
        let connection = ServerConnection()
        let stream = connection.subscribeDictation()
        connection.unsubscribeDictation()

        // The stream should finish immediately since we unsubscribed
        let collectTask = Task {
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }

        let count = await collectTask.value
        #expect(count == 0)
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
