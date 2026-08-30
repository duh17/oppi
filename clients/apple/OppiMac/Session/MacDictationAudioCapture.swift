@preconcurrency import AVFoundation
import Foundation

protocol MacDictationMicrophoneAuthorizing: Sendable {
    func requestAccess() async -> Bool
}

/// Microphone TCC for composer dictation. Fail closed on denied/unknown.
struct MacDictationMicrophoneAuthorization: MacDictationMicrophoneAuthorizing {
    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }
}

@MainActor
protocol MacDictationAudioCapturing: AnyObject {
    func start() throws -> AsyncStream<Data>
    func stop()
}

/// Captures 16 kHz 16-bit mono PCM for `/dictation/stream`.
///
/// The tap runs off the main actor. Do not call this type from OppiCore.
@MainActor
final class MacDictationAudioCapture: MacDictationAudioCapturing {
    private var engine: AVAudioEngine?
    private var audioContinuation: AsyncStream<Data>.Continuation?

    func start() throws -> AsyncStream<Data> {
        stop()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        audioContinuation = continuation
        engine = try MacDictationAudioEngineHelper.start(audioContinuation: continuation)
        return stream
    }

    func stop() {
        audioContinuation?.finish()
        audioContinuation = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }
}

/// Starts AVAudioEngine outside any actor so the tap is not MainActor-isolated.
enum MacDictationAudioEngineHelper {
    static func start(
        audioContinuation: AsyncStream<Data>.Continuation
    ) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MacComposerDictationError.transport("Microphone input format unavailable")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw MacComposerDictationError.transport("Cannot create 16kHz mono format")
        }

        let converter: AVAudioConverter?
        if inputFormat != targetFormat {
            guard let audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw MacComposerDictationError.transport("Cannot create dictation audio converter")
            }
            converter = audioConverter
        } else {
            converter = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
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

            let pcmData = convertToInt16PCM(buffer: outputBuffer)
            guard !pcmData.isEmpty else { return }
            audioContinuation.yield(pcmData)
        }

        engine.prepare()
        try engine.start()
        return engine
    }

    static func convertToInt16PCM(buffer: AVAudioPCMBuffer) -> Data {
        guard let floatData = buffer.floatChannelData?[0] else { return Data() }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return Data() }

        var data = Data(count: frameLength * 2)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frameLength {
                let sample = max(-1.0, min(1.0, floatData[i]))
                int16Ptr[i] = Int16(sample * Float(Int16.max))
            }
        }
        return data
    }
}
