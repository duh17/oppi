import Accelerate
@preconcurrency import AVFoundation
import Foundation
import Speech

private protocol AnalyzerInputFeeding: AnyObject {
    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?)
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
        private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
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
            inputBuilder: AsyncStream<AnalyzerInput>.Continuation
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
            inputBuilder.finish()
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
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat?
    ) throws -> RunningCapture {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        try validateInputFormat(inputFormat)

        let feed = try makeFeed(
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            inputBuilder: inputBuilder
        )

        let (levelStream, levelContinuation) = AsyncStream.makeStream(of: Float.self)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, time in
            guard buffer.frameLength > 0 else { return }
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = UInt(buffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, frameLength)
                let level = min(1.0, rms * 25.0)
                levelContinuation.yield(level)
            }

            feed.feed(buffer, at: time)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // RunningCapture hasn't taken ownership yet; release the failed
            // engine's tap and hardware before the manager retries capture.
            inputNode.removeTap(onBus: 0)
            engine.stop()
            levelContinuation.finish()
            throw error
        }

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
        into inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) {
        guard let converter, let targetFormat else { return }

        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4_096) else {
                return
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if error != nil { return }
            if output.frameLength > 0 {
                inputBuilder.yield(AnalyzerInput(buffer: output))
            }
            if status != .haveData {
                return
            }
        }
    }

#if compiler(>=6.4)
    @available(iOS 27, *)
    static func flushPendingAnalyzerInputs(
        converter: AnalyzerInputConverter,
        into inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) {
        do {
            for input in try converter.flush() {
                inputBuilder.yield(input)
            }
        } catch {
            return
        }
    }
#endif

    private static func makeFeed(
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat?,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) throws -> any AnalyzerInputFeeding {
#if compiler(>=6.4)
        if #available(iOS 27, *) {
            let format = targetFormat ?? inputFormat
            return SpeechConverterFeed(
                converter: AnalyzerInputConverter(analyzerFormat: format),
                inputBuilder: inputBuilder
            )
        }
#endif
        return try makeLegacyFeed(
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            inputBuilder: inputBuilder
        )
    }

    private static func makeLegacyFeed(
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat?,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) throws -> any AnalyzerInputFeeding {
        guard let targetFormat, inputFormat != targetFormat else {
            return PassthroughFeed(inputBuilder: inputBuilder)
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceInputError.internalError("Cannot create microphone audio converter")
        }
        return LegacyConverterFeed(
            converter: converter,
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            inputBuilder: inputBuilder
        )
    }

    private final class PassthroughFeed: AnalyzerInputFeeding {
        private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation

        init(inputBuilder: AsyncStream<AnalyzerInput>.Continuation) {
            self.inputBuilder = inputBuilder
        }

        func feed(_ buffer: AVAudioPCMBuffer, at _: AVAudioTime?) {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
        }

        func flush() {}
    }

    private final class LegacyConverterFeed: AnalyzerInputFeeding {
        private let converter: AVAudioConverter
        private let inputFormat: AVAudioFormat
        private let targetFormat: AVAudioFormat
        private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation

        init(
            converter: AVAudioConverter,
            inputFormat: AVAudioFormat,
            targetFormat: AVAudioFormat,
            inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        ) {
            self.converter = converter
            self.inputFormat = inputFormat
            self.targetFormat = targetFormat
            self.inputBuilder = inputBuilder
        }

        func feed(_ buffer: AVAudioPCMBuffer, at _: AVAudioTime?) {
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
            )
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCapacity
            ) else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if error != nil { return }
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        }

        func flush() {
            AudioEngineHelper.flushPendingAnalyzerInputs(
                converter: converter,
                targetFormat: targetFormat,
                into: inputBuilder
            )
        }
    }

#if compiler(>=6.4)
    @available(iOS 27, *)
    private final class SpeechConverterFeed: AnalyzerInputFeeding {
        private let converter: AnalyzerInputConverter
        private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation

        init(
            converter: AnalyzerInputConverter,
            inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        ) {
            self.converter = converter
            self.inputBuilder = inputBuilder
        }

        func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
            do {
                for input in try converter.convert(buffer, at: time) {
                    inputBuilder.yield(input)
                }
            } catch {
                return
            }
        }

        func flush() {
            AudioEngineHelper.flushPendingAnalyzerInputs(
                converter: converter,
                into: inputBuilder
            )
        }
    }
#endif
}
