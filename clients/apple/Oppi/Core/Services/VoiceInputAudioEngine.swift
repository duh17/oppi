import Accelerate
@preconcurrency import AVFoundation
import Foundation
import Speech

/// Single-consumer FIFO between the microphone and SpeechAnalyzer. Route rebuilds
/// replace the producer, not this queue. Never block the tap waiting for ASR, drop
/// an old/new buffer, or reset the budget on a route change. Eight seconds covers
/// normal analyzer/route stalls; duration, bytes and count independently cap memory.
final class AnalyzerInputBuffer: AsyncSequence, @unchecked Sendable {
    typealias Element = AnalyzerInput
    static let maxAudioSeconds = 8.0
    static let maxBytes = 4 * 1_024 * 1_024
    static let maxBuffers = 2_048

    struct AsyncIterator: AsyncIteratorProtocol {
        let owner: AnalyzerInputBuffer
        mutating func next() async -> AnalyzerInput? {
            let owner = owner
            return await withTaskCancellationHandler {
                await withCheckedContinuation { owner.take($0) }
            } onCancel: {
                owner.finish(discard: true)
            }
        }
    }

    private struct Entry {
        let input: AnalyzerInput
        let seconds: Double
        let bytes: Int
        let queuedAt: ContinuousClock.Instant
    }

    // All state (including finish/failure publication) is serialized by this lock.
    // No suspension, ASR work, or wait for consumption occurs under it.
    private let lock = NSLock()
    private var entries = [Entry?](repeating: nil, count: AnalyzerInputBuffer.maxBuffers)
    private var head = 0
    private var count = 0
    private var bytes = 0
    private var seconds = 0.0
    private var peakSeconds = 0.0
    private var underPressure = false
    private var recoveries = 0
    private var closed = false
    private var failed = false
    private var deadlineTask: Task<Void, Never>?
    private var waiter: CheckedContinuation<AnalyzerInput?, Never>?
    private let events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    private let now: @Sendable () -> ContinuousClock.Instant
    private let diagnostic: @Sendable ([String: String]) -> Void
    private let onFailure: @Sendable () -> Void
    private let byteLimit: Int

    init(
        events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation,
        byteLimit: Int = AnalyzerInputBuffer.maxBytes,
        onFailure: @escaping @Sendable () -> Void = {},
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        diagnostic: @escaping @Sendable ([String: String]) -> Void = {
            ClientLog.info("VoiceInput", "Dictation analyzer input pressure", metadata: $0)
        }
    ) {
        self.events = events
        self.byteLimit = Swift.min(Self.maxBytes, Swift.max(1, byteLimit))
        self.onFailure = onFailure
        self.now = now
        self.diagnostic = diagnostic
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(owner: self) }

    @discardableResult
    func enqueue(_ input: AnalyzerInput) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            // Keep the PCM object alive: on newer Speech runtimes `buffer`
            // returns a new copy, so pointers read from a temporary are unsafe.
            let pcm = input.buffer
            let duration = Double(pcm.frameLength) / pcm.format.sampleRate
            let size = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                .reduce(0) { $0 + Int($1.mDataByteSize) }
            guard duration.isFinite, duration > 0, size > 0 else { return false }
            let instant = now()
            let oldestAge = entries[head].map { $0.queuedAt.duration(to: instant) } ?? .zero
            let reason: String?
            if oldestAge >= .seconds(Self.maxAudioSeconds) { reason = "age_limit" }
            else if seconds + duration > Self.maxAudioSeconds { reason = "audio_limit" }
            else if size > byteLimit - bytes { reason = "byte_limit" }
            else if count == Self.maxBuffers { reason = "count_limit" }
            else { reason = nil }
            if let reason {
                report(status: "exhausted", reason: reason)
                failLocked(VoiceInputError.captureBufferOverflow)
                return false
            }
            do {
                // Older runtimes retain the supplied PCM. Own its samples before
                // the engine can recycle the tap buffer (including passthrough).
                let copy = try Self.copyPCM(pcm)
                let owned = AnalyzerInput(buffer: copy, bufferStartTime: input.bufferStartTime)
                if let pending = waiter {
                    waiter = nil
                    pending.resume(returning: owned)
                } else {
                    entries[(head + count) % Self.maxBuffers] = Entry(
                        input: owned, seconds: duration, bytes: size, queuedAt: instant
                    )
                    count += 1
                    // One watchdog per input lifetime, not one task/timer per
                    // tap when a fast consumer briefly empties the FIFO.
                    if deadlineTask == nil {
                        deadlineTask = Task.detached { [weak self] in
                            while !Task.isCancelled {
                                do { try await Task.sleep(for: .milliseconds(250)) }
                                catch { return }
                                guard self?.checkDeadline() == true else { return }
                            }
                        }
                    }
                    bytes += size
                    seconds += duration
                    peakSeconds = Swift.max(peakSeconds, seconds)
                    if !underPressure, seconds >= 0.5 {
                        underPressure = true
                        report(status: "buffering")
                    }
                }
                return true
            } catch {
                failLocked(error)
                return false
            }
        }
    }

    private func take(_ continuation: CheckedContinuation<AnalyzerInput?, Never>) {
        lock.withLock {
            if let entry = entries[head] {
                if entry.queuedAt.duration(to: now()) >= .seconds(Self.maxAudioSeconds) {
                    report(status: "exhausted", reason: "age_limit")
                    failLocked(VoiceInputError.captureBufferOverflow)
                    continuation.resume(returning: nil)
                    return
                }
                entries[head] = nil
                head = (head + 1) % Self.maxBuffers
                count -= 1
                if closed, count == 0 {
                    deadlineTask?.cancel()
                    deadlineTask = nil
                }
                bytes -= entry.bytes
                seconds = Swift.max(0, seconds - entry.seconds)
                if underPressure, seconds < 0.1 {
                    underPressure = false
                    recoveries += 1
                    report(status: "recovered")
                }
                continuation.resume(returning: entry.input)
            } else if closed {
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
            }
        }
    }

    /// Also runs after graceful input finish: Stop must not wait forever for an
    /// analyzer that stopped asking for queued audio. Closing and draining (or
    /// cancellation/deinit) retires the single watchdog.
    @discardableResult
    func checkDeadline() -> Bool {
        lock.withLock {
            guard let oldest = entries[head] else { return !closed }
            guard oldest.queuedAt.duration(to: now()) < .seconds(Self.maxAudioSeconds) else {
                report(status: "exhausted", reason: "age_limit")
                failLocked(VoiceInputError.captureBufferOverflow)
                return false
            }
            return true
        }
    }

    func finish(discard: Bool = false) {
        lock.withLock { finishLocked(discard: discard) }
    }

    func fail(_ error: Error) {
        lock.withLock { failLocked(error) }
    }

    private func failLocked(_ error: Error) {
        guard !failed else { return }
        failed = true
        // Must precede input completion, even during stop/converter flush.
        events.finish(throwing: error)
        finishLocked(discard: true)
        onFailure()
    }

    private func finishLocked(discard: Bool) {
        closed = true
        if discard {
            entries = [Entry?](repeating: nil, count: Self.maxBuffers)
            count = 0
            bytes = 0
            seconds = 0
        }
        if count == 0 {
            deadlineTask?.cancel()
            deadlineTask = nil
        }
        waiter?.resume(returning: nil)
        waiter = nil
    }

    deinit { deadlineTask?.cancel() }

    private func report(status: String, reason: String = "none") {
        let tags = [
            "status": status, "reason": reason,
            "buffered_ms": String(Int(seconds * 1_000)),
            "buffered_bytes": String(bytes), "buffered_buffers": String(count),
            "peak_buffered_ms": String(Int(peakSeconds * 1_000)),
            "recoveries": String(recoveries),
        ]
        diagnostic(tags)
        events.yield(.providerMetricTags([
            "analyzer_input_peak_ms": tags["peak_buffered_ms"] ?? "0",
            "analyzer_pressure_recoveries": String(recoveries),
        ]))
    }

    private static func copyPCM(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw VoiceInputError.internalError("Cannot allocate microphone input buffer")
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let sourceData = from.mData, let destinationData = to.mData,
                  from.mDataByteSize <= to.mDataByteSize else {
                throw VoiceInputError.internalError("Cannot copy microphone input buffer")
            }
            destinationData.copyMemory(from: sourceData, byteCount: Int(from.mDataByteSize))
        }
        return copy
    }
}

protocol AnalyzerInputFeeding: AnyObject {
    @discardableResult
    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) -> Bool
    func flush()
}

protocol OnDeviceAudioCapture: AnyObject {
    var audioLevels: AsyncStream<Float> { get }
    var isRunning: Bool { get }
    func stop()
    func stopAndFinishInput(flush: Bool)
}

enum AudioEngineHelper {
    final class RunningCapture: OnDeviceAudioCapture {
        let engine: AVAudioEngine
        let audioLevels: AsyncStream<Float>
        private let feed: any AnalyzerInputFeeding
        private let inputBuilder: AnalyzerInputBuffer
        private let levelContinuation: AsyncStream<Float>.Continuation
        private var didFinish = false
        private var didStop = false

        var isRunning: Bool { engine.isRunning }

        /// A failed startup attempt must not finish the analyzer's input stream.
        func stop() {
            guard !didStop else { return }
            didStop = true
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            levelContinuation.finish()
        }

        fileprivate init(
            engine: AVAudioEngine,
            audioLevels: AsyncStream<Float>,
            levelContinuation: AsyncStream<Float>.Continuation,
            feed: any AnalyzerInputFeeding,
            inputBuilder: AnalyzerInputBuffer
        ) {
            self.engine = engine
            self.audioLevels = audioLevels
            self.levelContinuation = levelContinuation
            self.feed = feed
            self.inputBuilder = inputBuilder
        }

        /// Stops the mic tap and engine. `flush` drains leftover converter frames
        /// into the analyzer sequence before finishing it. Cancel passes `false`.
        func stopAndFinishInput(flush: Bool) {
            guard !didFinish else { return }
            didFinish = true
            stop()
            if flush {
                feed.flush()
            }
            inputBuilder.finish(discard: !flush)
        }

        deinit {
            // Do not finish input here: a retry can replace this capture while
            // the same analyzer still owns the sequence.
            if !didStop {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            levelContinuation.finish()
        }
    }

    static func startEngine(
        inputBuilder: AnalyzerInputBuffer,
        targetFormat: AVAudioFormat?,
        events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    ) throws -> RunningCapture {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        try validateInputFormat(inputFormat)

        let feed = try makeFeed(
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            inputBuilder: inputBuilder,
            events: events
        )

        let (levelStream, levelContinuation) = AsyncStream.makeStream(of: Float.self)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, time in
            guard buffer.frameLength > 0 else { return }
            // Levels follow successfully queued analyzer input, not raw RMS.
            // Conversion loss fails the take immediately, rather than timing out.
            guard feed.feed(buffer, at: time) else { return }
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = UInt(buffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, frameLength)
                let level = min(1.0, rms * 25.0)
                levelContinuation.yield(level)
            }
        }

        engine.prepare()
        ClientLog.info(
            "VoiceInput",
            "Dictation audio engine starting",
            metadata: DictationAudioEngineHelper.captureMetadata(engine: engine)
        )
        do {
            try engine.start()
        } catch {
            var metadata = DictationAudioEngineHelper.captureMetadata(engine: engine)
            metadata["error_domain"] = (error as NSError).domain
            metadata["error_code"] = String((error as NSError).code)
            ClientLog.error("VoiceInput", "Dictation audio engine start failed", metadata: metadata)
            // RunningCapture hasn't taken ownership yet; release the failed
            // engine's tap and hardware before the manager retries capture.
            inputNode.removeTap(onBus: 0)
            engine.stop()
            levelContinuation.finish()
            throw error
        }
        ClientLog.info(
            "VoiceInput",
            "Dictation audio engine started",
            metadata: DictationAudioEngineHelper.captureMetadata(engine: engine)
        )

        return RunningCapture(
            engine: engine,
            audioLevels: levelStream,
            levelContinuation: levelContinuation,
            feed: feed,
            inputBuilder: inputBuilder
        )
    }

    static func validateInputFormat(_ format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceInputError.internalError("Microphone input format unavailable")
        }
    }

    /// Drains converter remainder after the mic tap is gone. Bounded so a stuck
    /// converter cannot hang stop. Used on iOS 26 and as the Xcode 26.6 fallback.
    static func flushPendingAnalyzerInputs(
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat?,
        into inputBuilder: AnalyzerInputBuffer,
        events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    ) {
        guard let converter, let targetFormat else { return }

        do {
            for _ in 0..<8 {
                guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4_096) else {
                    throw VoiceInputError.internalError("Cannot allocate microphone converter flush buffer")
                }
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, outStatus in
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if let error { throw error }
                guard status != .error else {
                    throw VoiceInputError.internalError("Microphone audio converter flush failed")
                }
                if output.frameLength > 0 {
                    guard enqueueCaptureInput(AnalyzerInput(buffer: output), into: inputBuilder, events: events) else {
                        return
                    }
                }
                if status != .haveData { return }
            }
            throw VoiceInputError.internalError("Microphone audio converter did not finish flushing")
        } catch {
            failCaptureConversion(error, into: inputBuilder, events: events, flushing: true)
        }
    }

#if compiler(>=6.4)
    @available(iOS 27, *)
    static func flushPendingAnalyzerInputs(
        converter: AnalyzerInputConverter,
        into inputBuilder: AnalyzerInputBuffer,
        events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    ) {
        do {
            for input in try converter.flush() {
                guard enqueueCaptureInput(input, into: inputBuilder, events: events) else { return }
            }
        } catch {
            failCaptureConversion(error, into: inputBuilder, events: events, flushing: true)
        }
    }
#endif

    static func failCaptureConversion(
        _ error: Error,
        into inputBuilder: AnalyzerInputBuffer,
        events _: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation,
        flushing: Bool = false
    ) {
        inputBuilder.fail(error)
        var metadata = DictationAudioEngineHelper.sessionRouteMetadata()
        metadata["error_domain"] = (error as NSError).domain
        metadata["error_code"] = String((error as NSError).code)
        ClientLog.error("VoiceInput", flushing
            ? "Microphone audio converter flush failed"
            : "Microphone audio conversion failed", metadata: metadata)
    }

    static func failCaptureConversion<Element: Sendable>(
        _ error: Error,
        into continuation: AsyncStream<Element>.Continuation,
        events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation,
        flushing: Bool = false
    ) {
        // Publish before closing input: analyzer/server finalization must not win
        // with a successful but incomplete transcript. Closing input also prevents
        // a later healthy buffer from restoring this take's delivery heartbeat.
        events.finish(throwing: error)
        continuation.finish()
        var metadata = DictationAudioEngineHelper.sessionRouteMetadata()
        metadata["error_domain"] = (error as NSError).domain
        metadata["error_code"] = String((error as NSError).code)
        ClientLog.error("VoiceInput", flushing
            ? "Microphone audio converter flush failed"
            : "Microphone audio conversion failed", metadata: metadata)
    }

    /// A zero-length result is legitimate converter buffering, not lost audio.
    /// NSError, `.error` (even without NSError), and allocation failure are fatal.
    static func convertCaptureBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        allocateBuffer: (AVAudioFormat, AVAudioFrameCount) -> AVAudioPCMBuffer?
    ) throws -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let frameCapacity = AVAudioFrameCount(ceil(
            Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
        ))
        guard let converted = allocateBuffer(targetFormat, frameCapacity) else {
            throw VoiceInputError.internalError("Cannot allocate microphone conversion buffer")
        }
        var error: NSError?
        // AVAudioConverter invokes this synchronously within convert; each tap
        // buffer is supplied once, then noDataNow lets it retain buffered frames.
        nonisolated(unsafe) var suppliedInput = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !suppliedInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard status != .error else {
            throw VoiceInputError.internalError("Microphone audio conversion failed")
        }
        return converted.frameLength > 0 ? converted : nil
    }

    private static func makeFeed(
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat?,
        inputBuilder: AnalyzerInputBuffer,
        events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    ) throws -> any AnalyzerInputFeeding {
#if compiler(>=6.4)
        if #available(iOS 27, *) {
            let format = targetFormat ?? inputFormat
            return SpeechConverterFeed(
                converter: AnalyzerInputConverter(analyzerFormat: format),
                inputBuilder: inputBuilder,
                events: events
            )
        }
#endif
        return try makeLegacyFeed(
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            inputBuilder: inputBuilder,
            events: events
        )
    }

    private static func makeLegacyFeed(
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat?,
        inputBuilder: AnalyzerInputBuffer,
        events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    ) throws -> any AnalyzerInputFeeding {
        guard let targetFormat, inputFormat != targetFormat else {
            return PassthroughFeed(inputBuilder: inputBuilder, events: events)
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceInputError.internalError("Cannot create microphone audio converter")
        }
        return LegacyConverterFeed(
            converter: converter,
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            inputBuilder: inputBuilder,
            events: events
        )
    }

    private final class PassthroughFeed: AnalyzerInputFeeding {
        private let inputBuilder: AnalyzerInputBuffer
        private let events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation

        init(
            inputBuilder: AnalyzerInputBuffer,
            events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
        ) {
            self.inputBuilder = inputBuilder
            self.events = events
        }

        func feed(_ buffer: AVAudioPCMBuffer, at _: AVAudioTime?) -> Bool {
            AudioEngineHelper.enqueueCaptureInput(AnalyzerInput(buffer: buffer), into: inputBuilder, events: events)
        }

        func flush() {}
    }

    final class LegacyConverterFeed: AnalyzerInputFeeding {
        private let converter: AVAudioConverter
        private let inputFormat: AVAudioFormat
        private let targetFormat: AVAudioFormat
        private let allocateBuffer: (AVAudioFormat, AVAudioFrameCount) -> AVAudioPCMBuffer?
        private let inputBuilder: AnalyzerInputBuffer
        private let events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation

        init(
            converter: AVAudioConverter,
            inputFormat: AVAudioFormat,
            targetFormat: AVAudioFormat,
            inputBuilder: AnalyzerInputBuffer,
            events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation,
            allocateBuffer: @escaping (AVAudioFormat, AVAudioFrameCount) -> AVAudioPCMBuffer? = {
                AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: $1)
            }
        ) {
            self.converter = converter
            self.inputFormat = inputFormat
            self.targetFormat = targetFormat
            self.allocateBuffer = allocateBuffer
            self.inputBuilder = inputBuilder
            self.events = events
        }

        func feed(_ buffer: AVAudioPCMBuffer, at _: AVAudioTime?) -> Bool {
            do {
                guard let converted = try AudioEngineHelper.convertCaptureBuffer(
                    buffer, converter: converter, inputFormat: inputFormat,
                    targetFormat: targetFormat, allocateBuffer: allocateBuffer
                ) else { return false }
                return AudioEngineHelper.enqueueCaptureInput(
                    AnalyzerInput(buffer: converted), into: inputBuilder, events: events
                )
            } catch {
                AudioEngineHelper.failCaptureConversion(error, into: inputBuilder, events: events)
                return false
            }
        }

        func flush() {
            AudioEngineHelper.flushPendingAnalyzerInputs(
                converter: converter,
                targetFormat: targetFormat,
                into: inputBuilder,
                events: events
            )
        }
    }

#if compiler(>=6.4)
    @available(iOS 27, *)
    private final class SpeechConverterFeed: AnalyzerInputFeeding {
        private let converter: AnalyzerInputConverter
        private let inputBuilder: AnalyzerInputBuffer
        private let events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation

        init(
            converter: AnalyzerInputConverter,
            inputBuilder: AnalyzerInputBuffer,
            events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
        ) {
            self.converter = converter
            self.inputBuilder = inputBuilder
            self.events = events
        }

        func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) -> Bool {
            do {
                var enqueuedAudio = false
                for input in try converter.convert(buffer, at: time) {
                    guard AudioEngineHelper.enqueueCaptureInput(input, into: inputBuilder, events: events) else {
                        return false
                    }
                    enqueuedAudio = true
                }
                return enqueuedAudio
            } catch {
                AudioEngineHelper.failCaptureConversion(error, into: inputBuilder, events: events)
                return false
            }
        }

        func flush() {
            AudioEngineHelper.flushPendingAnalyzerInputs(
                converter: converter,
                into: inputBuilder,
                events: events
            )
        }
    }
#endif

    static var captureOverflowError: VoiceInputError {
        .captureBufferOverflow
    }

    static func enqueueCaptureInput(
        _ input: AnalyzerInput,
        into inputBuilder: AnalyzerInputBuffer,
        events _: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    ) -> Bool {
        inputBuilder.enqueue(input)
    }

    static func enqueueCaptureInput<Element: Sendable>(
        _ input: Element,
        into continuation: AsyncStream<Element>.Continuation,
        events: AsyncThrowingStream<VoiceSessionEvent, Error>.Continuation
    ) -> Bool {
        switch continuation.yield(input) {
        case .enqueued:
            return true
        case .dropped:
            // Lost speech cannot be repaired by rebuilding a microphone. Latch
            // the failure now; a consumer that resumes must not revive this take.
            // Publish the error before ending analyzer input; otherwise its
            // results task could win the race by finishing events successfully.
            events.finish(throwing: captureOverflowError)
            continuation.finish()
            return false
        case .terminated:
            return false
        @unknown default:
            events.finish(throwing: captureOverflowError)
            continuation.finish()
            return false
        }
    }

}
