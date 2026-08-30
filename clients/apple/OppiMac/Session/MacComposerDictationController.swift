import Foundation
import Observation
import OSLog

private let macComposerDictationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacComposerDictation"
)

enum MacComposerDictationError: Error, Equatable, LocalizedError {
    case microphoneDenied
    case notConnected
    case transport(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            DictationComposerPolicy.microphoneDeniedMessage
        case .notConnected:
            DictationComposerPolicy.unavailableMessage
        case .transport(let message), .server(let message):
            message
        }
    }
}

/// Starts and stops server dictation for the Mac composer send field.
@MainActor
@Observable
final class MacComposerDictationController {
    enum State: Equatable {
        case idle
        case requestingPermission
        case connecting
        case recording
        case stopping
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var prefix = ""
    private(set) var transcript = ""
    private(set) var lastError: String?

    var composedDraft: String {
        DictationComposerPolicy.composedDraft(prefix: prefix, transcript: transcript)
    }

    var isRecording: Bool { state == .recording }

    var isLive: Bool {
        switch state {
        case .requestingPermission, .connecting, .recording, .stopping:
            true
        case .idle, .error:
            false
        }
    }

    private let microphone: any MacDictationMicrophoneAuthorizing
    private let makeTransport: (MacDictationEndpoint) -> any MacDictationTransporting
    private let makeAudioCapture: () -> any MacDictationAudioCapturing
    private let readyTimeout: Duration
    private let finalTimeout: Duration

    private var transport: (any MacDictationTransporting)?
    private var audioCapture: (any MacDictationAudioCapturing)?
    private var receiveTask: Task<Void, Never>?
    private var audioDrainTask: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var finalTimeoutTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var finalContinuation: CheckedContinuation<Void, Never>?
    private var isReady = false
    /// Invalidates work suspended in permission, connect, or timeout awaits.
    /// A session switch must not let an older dictation lifecycle mutate the
    /// newly selected session's composer.
    private var lifecycleGeneration: UInt64 = 0

    init(
        microphone: any MacDictationMicrophoneAuthorizing = MacDictationMicrophoneAuthorization(),
        makeTransport: @escaping (MacDictationEndpoint) -> any MacDictationTransporting = {
            MacDictationStreamClient(endpoint: $0)
        },
        makeAudioCapture: @escaping () -> any MacDictationAudioCapturing = {
            MacDictationAudioCapture()
        },
        readyTimeout: Duration = .seconds(10),
        finalTimeout: Duration = .seconds(10)
    ) {
        self.microphone = microphone
        self.makeTransport = makeTransport
        self.makeAudioCapture = makeAudioCapture
        self.readyTimeout = readyTimeout
        self.finalTimeout = finalTimeout
    }

    func start(baseText: String, endpoint: MacDictationEndpoint) async throws {
        guard !isLive else { return }
        let generation = advanceLifecycleGeneration()
        lastError = nil
        prefix = DictationComposerPolicy.prefix(for: baseText)
        transcript = ""
        isReady = false
        state = .requestingPermission

        let hasMicrophoneAccess = await microphone.requestAccess()
        guard isCurrentLifecycle(generation) else { return }
        guard hasMicrophoneAccess else {
            fail(.microphoneDenied)
            throw MacComposerDictationError.microphoneDenied
        }

        state = .connecting
        let transport = makeTransport(endpoint)
        self.transport = transport
        do {
            try await transport.connect()
        } catch {
            guard isCurrentLifecycle(generation) else {
                transport.close()
                return
            }
            fail(.transport(error.localizedDescription))
            throw MacComposerDictationError.transport(error.localizedDescription)
        }
        guard isCurrentLifecycle(generation) else {
            transport.close()
            return
        }

        startReceiveLoop(transport, generation: generation)
        do {
            try await transport.sendControl(.dictationStart)
        } catch {
            guard isCurrentLifecycle(generation) else {
                transport.close()
                return
            }
            fail(.transport(error.localizedDescription))
            throw MacComposerDictationError.transport(error.localizedDescription)
        }
        guard isCurrentLifecycle(generation) else {
            transport.close()
            return
        }

        let capture = makeAudioCapture()
        audioCapture = capture
        let audioStream: AsyncStream<Data>
        do {
            audioStream = try capture.start()
        } catch {
            fail(.transport(error.localizedDescription))
            throw MacComposerDictationError.transport(error.localizedDescription)
        }

        startReadyTimeout(generation: generation)
        startAudioDrain(stream: audioStream, generation: generation)
        state = .recording
        macComposerDictationLogger.info("Composer dictation recording")
    }

    func stop() async {
        guard state == .recording || state == .connecting else { return }
        let generation = lifecycleGeneration
        if !isReady {
            await cancel()
            return
        }
        state = .stopping
        audioCapture?.stop()
        await audioDrainTask?.value
        audioDrainTask = nil
        guard isCurrentLifecycle(generation), state == .stopping else { return }
        do {
            try await transport?.sendControl(.dictationStop)
        } catch {
            guard isCurrentLifecycle(generation) else { return }
            fail(.transport(error.localizedDescription))
            return
        }
        guard isCurrentLifecycle(generation) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if state != .stopping {
                continuation.resume()
                return
            }
            finalContinuation = continuation
            finalTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: self?.finalTimeout ?? .seconds(10))
                } catch {
                    return
                }
                guard let self, self.isCurrentLifecycle(generation) else { return }
                self.finishSession()
            }
        }
    }

    func cancel() async {
        let detached = detachCurrentSession(
            discardComposedDraft: false,
            clearError: false
        )
        guard detached.wasLive else { return }
        await sendCancelAndClose(detached.transport)
    }

    /// Synchronously clears composer-visible state, then closes the previous
    /// stream in the background. This is intentionally distinct from the mic
    /// button's cancel behavior, which preserves the user's typed prefix.
    func resetForSessionChange() {
        let detached = detachCurrentSession(
            discardComposedDraft: true,
            clearError: true
        )
        guard detached.wasLive else { return }
        Task { @MainActor in
            await sendCancelAndClose(detached.transport)
        }
    }

    private func detachCurrentSession(
        discardComposedDraft: Bool,
        clearError: Bool
    ) -> (wasLive: Bool, transport: (any MacDictationTransporting)?) {
        lifecycleGeneration &+= 1
        let wasLive = isLive
        let detachedTransport = transport

        // Flip `isLive` before changing composedDraft so a SwiftUI observer
        // cannot paint the old prefix into a newly selected session.
        if wasLive || discardComposedDraft {
            state = .idle
        }
        if discardComposedDraft {
            prefix = ""
        }
        if clearError {
            lastError = nil
        }
        transcript = ""
        audioCapture?.stop()
        audioCapture = nil
        audioDrainTask?.cancel()
        audioDrainTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        resumeReady(.failure(CancellationError()))
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        finalTimeoutTask?.cancel()
        finalTimeoutTask = nil
        transport = nil
        isReady = false
        let pendingFinal = finalContinuation
        finalContinuation = nil
        pendingFinal?.resume()
        return (wasLive, detachedTransport)
    }

    private func sendCancelAndClose(_ transport: (any MacDictationTransporting)?) async {
        guard let transport else { return }
        do {
            try await transport.sendControl(.dictationCancel)
        } catch {
            macComposerDictationLogger.debug(
                "Failed to send dictation_cancel: \(error.localizedDescription, privacy: .public)"
            )
        }
        transport.close()
    }

    private func startReceiveLoop(
        _ transport: any MacDictationTransporting,
        generation: UInt64
    ) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await transport.receive()
                    guard let self,
                          !Task.isCancelled,
                          self.isCurrentLifecycle(generation) else { return }
                    self.handle(message)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          !Task.isCancelled,
                          self.isCurrentLifecycle(generation) else { return }
                    if self.state == .stopping {
                        self.finishSession()
                        return
                    }
                    if self.isLive {
                        self.fail(.transport(DictationComposerPolicy.disconnectMessage))
                    }
                    return
                }
            }
        }
    }

    private func startAudioDrain(stream: AsyncStream<Data>, generation: UInt64) {
        audioDrainTask = Task { [weak self] in
            do {
                try await self?.waitUntilReady()
            } catch is CancellationError {
                return
            } catch {
                await self?.failFromDrain(error, generation: generation)
                return
            }

            for await chunk in stream {
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentLifecycle(generation) else { break }
                do {
                    try await self.transport?.sendAudio(chunk)
                } catch is CancellationError {
                    return
                } catch {
                    await self.failFromDrain(error, generation: generation)
                    return
                }
            }
        }
    }

    private func waitUntilReady() async throws {
        if isReady { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if isReady {
                continuation.resume()
                return
            }
            readyContinuation = continuation
        }
    }

    private func startReadyTimeout(generation: UInt64) {
        readyTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.readyTimeout ?? .seconds(10))
            } catch {
                return
            }
            guard let self,
                  self.isCurrentLifecycle(generation),
                  !self.isReady,
                  self.isLive else { return }
            self.fail(.transport(DictationComposerPolicy.readyTimeoutMessage))
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .dictationReady:
            isReady = true
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            if let readyContinuation {
                self.readyContinuation = nil
                readyContinuation.resume()
            }

        case .dictationResult(let text, _, _):
            guard !text.isEmpty else { return }
            transcript = text

        case .dictationFinal(let text, _):
            if !text.isEmpty {
                transcript = text
            }
            finishSession()

        case .dictationError(let error, let fatal):
            if fatal {
                fail(.server(error))
            } else {
                lastError = error
            }

        default:
            break
        }
    }

    private func failFromDrain(_ error: Error, generation: UInt64) {
        guard isCurrentLifecycle(generation), !(error is CancellationError) else { return }
        if let dictationError = error as? MacComposerDictationError {
            fail(dictationError)
        } else {
            fail(.transport(error.localizedDescription))
        }
    }

    private func fail(_ error: MacComposerDictationError) {
        guard isLive || state == .stopping else { return }
        let message = error.localizedDescription
        macComposerDictationLogger.error("Composer dictation failed: \(message, privacy: .public)")
        lastError = message
        resumeReady(.failure(error))
        audioCapture?.stop()
        audioDrainTask?.cancel()
        audioDrainTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        transport?.close()
        transport = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        finalTimeoutTask?.cancel()
        finalTimeoutTask = nil
        let pendingFinal = finalContinuation
        finalContinuation = nil
        state = .error(message)
        pendingFinal?.resume()
    }

    private func finishSession() {
        resumeReady(.failure(CancellationError()))
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        finalTimeoutTask?.cancel()
        finalTimeoutTask = nil
        audioCapture?.stop()
        audioCapture = nil
        audioDrainTask?.cancel()
        audioDrainTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        transport?.close()
        transport = nil
        let pendingFinal = finalContinuation
        finalContinuation = nil
        if isLive || state == .stopping {
            state = .idle
        }
        pendingFinal?.resume()
    }

    private func advanceLifecycleGeneration() -> UInt64 {
        lifecycleGeneration &+= 1
        return lifecycleGeneration
    }

    private func isCurrentLifecycle(_ generation: UInt64) -> Bool {
        lifecycleGeneration == generation
    }

    private func resumeReady(_ result: Result<Void, Error>) {
        guard let readyContinuation else { return }
        self.readyContinuation = nil
        switch result {
        case .success:
            readyContinuation.resume()
        case .failure(let error):
            readyContinuation.resume(throwing: error)
        }
    }
}
