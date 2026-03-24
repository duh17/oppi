import Accelerate
@preconcurrency import AVFoundation
import Foundation
import Speech

enum AudioEngineHelper {
    static func startEngine(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat?
    ) throws -> (AVAudioEngine, AsyncStream<Float>) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let converter: AVAudioConverter?
        if let targetFormat, inputFormat != targetFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = UInt(buffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, frameLength)
                let level = min(1.0, rms * 25.0)
                levelContinuation.yield(level)
            }

            let outputBuffer: AVAudioPCMBuffer
            if let converter, let targetFormat {
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
                outputBuffer = converted
            } else {
                outputBuffer = buffer
            }

            inputBuilder.yield(AnalyzerInput(buffer: outputBuffer))
        }

        engine.prepare()
        try engine.start()

        return (engine, levelStream)
    }
}

enum RemoteAudioEngineHelper {
    static func startEngine(
        transcriber: RemoteASRTranscriber,
        sampleRate: Int
    ) throws -> (AVAudioEngine, AsyncStream<Float>) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceInputError.internalError("Cannot create 16kHz mono format")
        }

        let converter: AVAudioConverter?
        if inputFormat != targetFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak transcriber] buffer, _ in
            guard let transcriber else { return }

            let outputBuffer: AVAudioPCMBuffer
            if let converter {
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
                outputBuffer = converted
            } else {
                outputBuffer = buffer
            }

            if let channelData = outputBuffer.floatChannelData?[0] {
                let frameLength = UInt(outputBuffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, frameLength)
                let level = min(1.0, rms * 25.0)
                levelContinuation.yield(level)
            }

            transcriber.appendAudio(buffer: outputBuffer)
        }

        engine.prepare()
        try engine.start()
        return (engine, levelStream)
    }
}
