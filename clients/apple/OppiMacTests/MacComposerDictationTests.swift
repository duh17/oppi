import Foundation
import Testing
@testable import Oppi

@Suite("Dictation composer policy")
struct DictationComposerPolicyTests {
    @Test func streamPathIsUnixRouteWithoutTokenOrTLS() {
        #expect(DictationComposerPolicy.streamPath == "/dictation/stream")
        #expect(!DictationComposerPolicy.streamPath.contains("sk_"))
        #expect(!DictationComposerPolicy.streamPath.contains("wss"))
        #expect(!DictationComposerPolicy.streamPath.contains("https"))
    }

    @Test func prefixInsertsASpaceOnlyWhenNeeded() {
        #expect(DictationComposerPolicy.prefix(for: "") == "")
        #expect(DictationComposerPolicy.prefix(for: "hello") == "hello ")
        #expect(DictationComposerPolicy.prefix(for: "hello ") == "hello ")
        #expect(DictationComposerPolicy.prefix(for: "hello\n") == "hello\n")
    }

    @Test func composedDraftAppendsLiveTranscript() {
        #expect(DictationComposerPolicy.composedDraft(prefix: "Hi ", transcript: "there") == "Hi there")
        #expect(DictationComposerPolicy.composedDraft(prefix: "", transcript: "Hello") == "Hello")
    }

    @Test func submissionGateRejectsASecondSendUntilTheFirstFinishes() throws {
        var gate = MacComposerSubmissionGate()

        let firstAttempt = gate.begin()
        let first = try #require(firstAttempt)
        #expect(gate.isActive)
        let rejectedSecond = gate.begin()
        #expect(rejectedSecond == nil)

        gate.finish(UUID())
        #expect(gate.isActive)
        gate.finish(first)
        #expect(!gate.isActive)
        let next = gate.begin()
        #expect(next != nil)

        gate.reset()
        let replacement = gate.begin()
        gate.finish(first)
        #expect(gate.activeID == replacement)
    }
}

@MainActor
@Suite("Mac dictation stream client")
struct MacDictationStreamClientTests {
    @Test func endpointKeepsTokenOutOfTheStreamPath() {
        let endpoint = MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
        #expect(endpoint.streamPath == "/dictation/stream")
        #expect(!endpoint.streamPath.contains("sk_"))
        #expect(!endpoint.socketPath.contains("sk_"))
        #expect(endpoint.authorizationHeader == "Bearer sk_secret")
        #expect(endpoint.ownerHeaders()["Authorization"] == "Bearer sk_secret")
    }

    @Test func sendControlEncodesDictationStartWithoutTheToken() async throws {
        let socket = RecordingDictationWebSocket()
        let client = MacDictationStreamClient(
            endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret"),
            transport: socket
        )
        try await client.connect()
        try await client.sendControl(.dictationStart)
        try await client.sendAudio(Data([0x01, 0x02]))

        #expect(socket.connectCount == 1)
        #expect(socket.sent.count == 2)
        guard case .text(let text) = socket.sent[0] else {
            Issue.record("Expected dictation_start text frame")
            return
        }
        #expect(text.contains("\"type\":\"dictation_start\""))
        #expect(!text.contains("sk_"))
        guard case .data(let audio) = socket.sent[1] else {
            Issue.record("Expected binary audio frame")
            return
        }
        #expect(audio == Data([0x01, 0x02]))
    }
}

@MainActor
@Suite("Mac composer dictation")
struct MacComposerDictationControllerTests {
    @Test func deniedMicrophoneFailsClosedWithoutOpeningTheStream() async {
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = MacComposerDictationController(
            microphone: FakeDictationMicrophone(granted: false),
            makeTransport: { _ in transport },
            makeAudioCapture: { audio }
        )

        await #expect(throws: MacComposerDictationError.microphoneDenied) {
            try await controller.start(
                baseText: "Hello",
                endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
            )
        }
        #expect(transport.connectCount == 0)
        #expect(transport.controls.isEmpty)
        #expect(audio.startCount == 0)
        #expect(controller.lastError == DictationComposerPolicy.microphoneDeniedMessage)
        #expect(controller.state == .error(DictationComposerPolicy.microphoneDeniedMessage))
    }

    @Test func startSendsDictationStartOnTheUnixStream() async throws {
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = makeController(transport: transport, audio: audio)

        try await controller.start(
            baseText: "Hi",
            endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
        )

        #expect(transport.connectCount == 1)
        #expect(transport.controls.map(\.typeLabel) == ["dictation_start"])
        #expect(controller.isRecording)
        #expect(controller.composedDraft == "Hi ")
        await controller.cancel()
    }

    @Test func liveResultReplacesTheComposerTranscript() async throws {
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = makeController(transport: transport, audio: audio)

        try await controller.start(
            baseText: "Hi",
            endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
        )
        transport.yield(.dictationReady(provider: nil))
        transport.yield(.dictationResult(text: "there", snap: false))
        #expect(await waitUntil { controller.transcript == "there" })
        #expect(controller.composedDraft == "Hi there")
        await controller.cancel()
    }

    @Test func audioWaitsForReadyThenSendsBinaryFrames() async throws {
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = makeController(transport: transport, audio: audio)

        try await controller.start(
            baseText: "",
            endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
        )
        audio.yield(Data([0x11, 0x22]))
        #expect(transport.audio.isEmpty)
        transport.yield(.dictationReady(provider: nil))
        #expect(await waitUntil { transport.audio == [Data([0x11, 0x22])] })
        await controller.cancel()
    }

    @Test func stopSendsDictationStopAndCommitsFinalText() async throws {
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = makeController(transport: transport, audio: audio)

        try await controller.start(
            baseText: "",
            endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
        )
        transport.yield(.dictationReady(provider: nil))
        transport.yield(.dictationResult(text: "draft", snap: false))
        #expect(await waitUntil { controller.transcript == "draft" })

        let stopTask = Task { await controller.stop() }
        #expect(await waitUntil { transport.controls.contains { $0.typeLabel == "dictation_stop" } })
        transport.yield(.dictationFinal(text: "final text"))
        await stopTask.value
        #expect(controller.transcript == "final text")
        #expect(controller.composedDraft == "final text")
        #expect(controller.state == .idle)
    }

    @Test func secondSubmissionIsRejectedWhileDictationWaitsForFinalText() async throws {
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = makeController(transport: transport, audio: audio)
        let submission = ComposerSubmissionTestState()

        try await controller.start(
            baseText: "",
            endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
        )
        transport.yield(.dictationReady(provider: nil))
        transport.yield(.dictationResult(text: "interim", snap: false))
        #expect(await waitUntil { controller.transcript == "interim" })

        let firstAttempt = submission.begin()
        let first = try #require(firstAttempt)
        let firstTask = Task { @MainActor in
            await controller.stop()
            submission.sentDrafts.append(controller.composedDraft)
            submission.finish(first)
        }
        #expect(await waitUntil {
            transport.controls.contains { $0.typeLabel == "dictation_stop" }
        })

        let rejectedSecond = submission.begin()
        #expect(rejectedSecond == nil)
        #expect(submission.sentDrafts.isEmpty)

        transport.yield(.dictationFinal(text: "final text"))
        await firstTask.value
        #expect(submission.sentDrafts == ["final text"])
        #expect(!submission.gate.isActive)
    }

    @Test func cancelSendsDictationCancelAndDropsTranscript() async throws {
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = makeController(transport: transport, audio: audio)

        try await controller.start(
            baseText: "Keep",
            endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
        )
        transport.yield(.dictationResult(text: "gone", snap: false))
        #expect(await waitUntil { controller.transcript == "gone" })
        await controller.cancel()
        #expect(transport.controls.contains { $0.typeLabel == "dictation_cancel" })
        #expect(controller.transcript.isEmpty)
        #expect(controller.composedDraft == "Keep ")
        #expect(!controller.composedDraft.contains("gone"))
        #expect(controller.state == .idle)
    }

    @Test func sessionChangeResetDropsTheOldComposedDraftImmediately() async throws {
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = makeController(transport: transport, audio: audio)

        try await controller.start(
            baseText: "Session A",
            endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
        )
        transport.yield(.dictationResult(text: "private transcript", snap: false))
        #expect(await waitUntil { controller.transcript == "private transcript" })

        controller.resetForSessionChange()

        #expect(controller.state == .idle)
        #expect(!controller.isLive)
        #expect(controller.composedDraft.isEmpty)
        #expect(await waitUntil {
            transport.controls.contains { $0.typeLabel == "dictation_cancel" }
        })
    }

    @Test func sessionChangeDuringPermissionPreventsTheOldStartFromReviving() async throws {
        let microphone = DeferredDictationMicrophone()
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = MacComposerDictationController(
            microphone: microphone,
            makeTransport: { _ in transport },
            makeAudioCapture: { audio }
        )

        let startTask = Task {
            try await controller.start(
                baseText: "Session A",
                endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
            )
        }
        #expect(await waitUntil { controller.state == .requestingPermission })

        controller.resetForSessionChange()
        await microphone.resolve(granted: true)
        try await startTask.value

        #expect(controller.state == .idle)
        #expect(controller.composedDraft.isEmpty)
        #expect(transport.connectCount == 0)
        #expect(audio.startCount == 0)
    }

    @Test func sessionChangeDuringConnectPreventsTheOldStartFromReviving() async throws {
        let transport = DeferredConnectDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = MacComposerDictationController(
            microphone: FakeDictationMicrophone(granted: true),
            makeTransport: { _ in transport },
            makeAudioCapture: { audio }
        )

        let startTask = Task {
            try await controller.start(
                baseText: "Session A",
                endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
            )
        }
        #expect(await waitUntil {
            controller.state == .connecting && transport.connectCount == 1
        })

        controller.resetForSessionChange()
        transport.finishConnect()
        try await startTask.value

        #expect(controller.state == .idle)
        #expect(controller.composedDraft.isEmpty)
        #expect(!transport.controls.contains { $0.typeLabel == "dictation_start" })
        #expect(audio.startCount == 0)
    }

    @Test func stopBeforeReadyCancelsWithoutWaitingForReadyTimeout() async throws {
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = MacComposerDictationController(
            microphone: FakeDictationMicrophone(granted: true),
            makeTransport: { _ in transport },
            makeAudioCapture: { audio },
            readyTimeout: .seconds(2),
            finalTimeout: .seconds(2)
        )

        try await controller.start(
            baseText: "Hi",
            endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
        )
        #expect(controller.state == .recording)

        let clock = ContinuousClock()
        let started = clock.now
        await controller.stop()
        #expect(clock.now - started < .seconds(1))
        #expect(controller.state == .idle)
        #expect(controller.lastError == nil)
        #expect(transport.controls.map(\.typeLabel) == ["dictation_start", "dictation_cancel"])
        #expect(controller.composedDraft == "Hi ")
    }

    @Test func fatalServerErrorFailsClosedWithVisibleMessage() async throws {
        let transport = FakeDictationTransport()
        let audio = FakeDictationAudioCapture()
        let controller = makeController(transport: transport, audio: audio)

        try await controller.start(
            baseText: "",
            endpoint: MacDictationEndpoint(socketPath: "/tmp/oppi.sock", token: "sk_secret")
        )
        transport.yield(.dictationError(error: "STT backend unreachable", fatal: true))
        #expect(await waitUntil { controller.lastError == "STT backend unreachable" })
        #expect(controller.state == .error("STT backend unreachable"))
    }

    private func makeController(
        transport: FakeDictationTransport,
        audio: FakeDictationAudioCapture
    ) -> MacComposerDictationController {
        MacComposerDictationController(
            microphone: FakeDictationMicrophone(granted: true),
            makeTransport: { _ in transport },
            makeAudioCapture: { audio },
            readyTimeout: .seconds(2),
            finalTimeout: .seconds(2)
        )
    }
}

private struct FakeDictationMicrophone: MacDictationMicrophoneAuthorizing {
    let granted: Bool
    func requestAccess() async -> Bool { granted }
}

private actor DeferredDictationMicrophone: MacDictationMicrophoneAuthorizing {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolvedAccess: Bool?

    func requestAccess() async -> Bool {
        if let resolvedAccess { return resolvedAccess }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(granted: Bool) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: granted)
        } else {
            resolvedAccess = granted
        }
    }
}

@MainActor
private final class FakeDictationAudioCapture: MacDictationAudioCapturing {
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var startCount = 0

    func start() throws -> AsyncStream<Data> {
        startCount += 1
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func yield(_ data: Data) {
        continuation?.yield(data)
    }
}

@MainActor
private final class FakeDictationTransport: MacDictationTransporting {
    private(set) var connectCount = 0
    private(set) var controls: [ClientMessage] = []
    private(set) var audio: [Data] = []
    private var incoming: [ServerMessage] = []
    private var waiters: [CheckedContinuation<ServerMessage, Error>] = []
    private var finishedError: Error?

    func connect() async throws {
        connectCount += 1
    }

    func sendControl(_ message: ClientMessage) async throws {
        controls.append(message)
    }

    func sendAudio(_ data: Data) async throws {
        audio.append(data)
    }

    func receive() async throws -> ServerMessage {
        try await withCheckedThrowingContinuation { continuation in
            if let finishedError {
                continuation.resume(throwing: finishedError)
                return
            }
            if !incoming.isEmpty {
                continuation.resume(returning: incoming.removeFirst())
                return
            }
            waiters.append(continuation)
        }
    }

    func close() {
        finishedError = WebSocketTransportError.cancelled
        let waiters = waiters
        self.waiters = []
        waiters.forEach { $0.resume(throwing: WebSocketTransportError.cancelled) }
    }

    func yield(_ message: ServerMessage) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: message)
        } else {
            incoming.append(message)
        }
    }
}

@MainActor
private final class DeferredConnectDictationTransport: MacDictationTransporting {
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private(set) var connectCount = 0
    private(set) var controls: [ClientMessage] = []

    func connect() async throws {
        connectCount += 1
        await withCheckedContinuation { continuation in
            connectContinuation = continuation
        }
    }

    func finishConnect() {
        let continuation = connectContinuation
        connectContinuation = nil
        continuation?.resume()
    }

    func sendControl(_ message: ClientMessage) async throws {
        controls.append(message)
    }

    func sendAudio(_ data: Data) async throws {}

    func receive() async throws -> ServerMessage {
        throw WebSocketTransportError.cancelled
    }

    func close() {}
}

private final class RecordingDictationWebSocket: MacDictationSocketTransporting, @unchecked Sendable {
    private(set) var connectCount = 0
    private(set) var sent: [WebSocketTransportMessage] = []
    private var incoming: [WebSocketTransportMessage] = []
    private var waiters: [CheckedContinuation<WebSocketTransportMessage, Error>] = []

    func connect() async throws {
        connectCount += 1
    }

    func send(_ message: WebSocketTransportMessage) async throws {
        sent.append(message)
    }

    func receive() async throws -> WebSocketTransportMessage {
        try await withCheckedThrowingContinuation { continuation in
            if !incoming.isEmpty {
                continuation.resume(returning: incoming.removeFirst())
                return
            }
            waiters.append(continuation)
        }
    }

    func ping() async throws {}

    func close(code: UInt16, reason: Data?) async {
        cancel()
    }

    func cancel() {
        let waiters = waiters
        self.waiters = []
        waiters.forEach { $0.resume(throwing: WebSocketTransportError.cancelled) }
    }
}

@MainActor
private final class ComposerSubmissionTestState {
    var gate = MacComposerSubmissionGate()
    var sentDrafts: [String] = []

    func begin() -> UUID? {
        gate.begin()
    }

    func finish(_ id: UUID) {
        gate.finish(id)
    }
}

@MainActor
private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        await Task.yield()
    }
    return false
}
