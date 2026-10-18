import Accelerate
@preconcurrency import AVFoundation
import Foundation

/// Duplex capture owner for Live Voice. Mute stops the input tap.
///
/// This is not the dictation stream. PCM is handed to the Live Voice call
/// channel so the server Yuwp adapter can commit utterances.
@MainActor
protocol LiveVoiceAudioOwning: AnyObject {
    var isCapturing: Bool { get }
    var openedDictationStream: Bool { get }
    var onPCM: (@MainActor (Data) -> Void)? { get set }
    func start() async throws
    func setMuted(_ muted: Bool)
    func play(_ pcm: Data)
    func stopPlayback()
    func stop()
}

@MainActor
protocol LiveVoiceCaptureEngine: AnyObject {
    var isCapturing: Bool { get }
    func start(onPCM: @escaping @Sendable (Data) -> Void) throws
    func stopCapture()
}

@MainActor
protocol LiveVoicePlaybackEngine: AnyObject {
    func play(_ pcm: Data)
    func stopPlayback()
    func teardown()
}

@MainActor
final class LiveVoiceAudioOwner: LiveVoiceAudioOwning {
    private(set) var isCapturing = false
    let openedDictationStream = false
    var onPCM: (@MainActor (Data) -> Void)?

    private let engine: LiveVoiceCaptureEngine
    private let playback: LiveVoicePlaybackEngine?
    private var started = false
    private var muted = false

    init(
        engine: LiveVoiceCaptureEngine = LiveVoiceDuplexCaptureEngine(),
        playback: LiveVoicePlaybackEngine? = nil
    ) {
        self.engine = engine
        self.playback = playback ?? (engine as? LiveVoicePlaybackEngine)
    }

    func start() async throws {
        started = true
        muted = false
        try beginCapture()
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        if muted {
            engine.stopCapture()
            isCapturing = false
            return
        }
        guard started else { return }
        try? beginCapture()
    }

    func play(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        playback?.play(pcm)
    }

    func stopPlayback() {
        playback?.stopPlayback()
    }

    func stop() {
        started = false
        muted = false
        playback?.teardown()
        engine.stopCapture()
        isCapturing = false
    }

    private func beginCapture() throws {
        try engine.start { [weak self] data in
            Task { @MainActor in
                self?.forward(data)
            }
        }
        isCapturing = engine.isCapturing
    }

    private func forward(_ data: Data) {
        guard started, !muted, isCapturing, !data.isEmpty else { return }
        onPCM?(data)
    }
}

/// One play-and-record session so Live Voice capture can coexist with playback.
@MainActor
final class LiveVoiceDuplexCaptureEngine: LiveVoiceCaptureEngine, LiveVoicePlaybackEngine {
    private(set) var isCapturing = false
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var tapInstalled = false

    func start(onPCM: @escaping @Sendable (Data) -> Void) throws {
        try activateSession()
        if audioEngine == nil {
            audioEngine = AVAudioEngine()
        }
        guard let engine = audioEngine else {
            throw VoiceInputError.internalError("Live Voice audio engine is unavailable")
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Install the mic tap on a bare engine. Attaching the 24 kHz playback
        // graph first makes inputNode.outputFormat report 0 Hz on device.
        try LiveVoiceCaptureEngineHelper.installTap(engine: engine, onPCM: onPCM)
        tapInstalled = true
        try attachPlayback(to: engine)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        isCapturing = true
    }

    func stopCapture() {
        if tapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isCapturing = false
    }

    func stopPlayback() {
        player?.stop()
        player?.reset()
    }

    func teardown() {
        stopCapture()
        stopPlayback()
        audioEngine?.stop()
        if let player {
            audioEngine?.detach(player)
        }
        player = nil
        playbackFormat = nil
        audioEngine = nil
    }

    func play(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        do {
            try activateSession()
            if audioEngine == nil {
                audioEngine = AVAudioEngine()
            }
            guard let engine = audioEngine else { return }
            try attachPlayback(to: engine)
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            return
        }
        guard let player, let format = playbackFormat,
              let buffer = LiveVoiceCaptureEngineHelper.pcm16LEBuffer(data: pcm, format: format) else {
            return
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer)
    }

    private func activateSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setPreferredSampleRate(16_000)
        try session.setActive(true)
        #endif
    }

    private func attachPlayback(to engine: AVAudioEngine) throws {
        guard player == nil else { return }
        let playerNode = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1) else {
            throw VoiceInputError.internalError("Cannot create Live Voice playback format")
        }
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        player = playerNode
        playbackFormat = format
    }
}

/// Non-actor helper so the input tap does not inherit MainActor isolation.
enum LiveVoiceCaptureEngineHelper {
    static func resolvedHardwareFormat(
        outputFormat: AVAudioFormat,
        inputFormat: AVAudioFormat
    ) throws -> AVAudioFormat {
        if outputFormat.sampleRate > 0, outputFormat.channelCount > 0 {
            return outputFormat
        }
        if inputFormat.sampleRate > 0, inputFormat.channelCount > 0 {
            return inputFormat
        }
        throw VoiceInputError.internalError("Microphone input format unavailable")
    }

    static func installTap(engine: AVAudioEngine, onPCM: @escaping @Sendable (Data) -> Void) throws {
        let inputNode = engine.inputNode
        let inputFormat = try resolvedHardwareFormat(
            outputFormat: inputNode.outputFormat(forBus: 0),
            inputFormat: inputNode.inputFormat(forBus: 0)
        )

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceInputError.internalError("Cannot create Live Voice 16kHz mono format")
        }

        let converter: AVAudioConverter?
        if inputFormat != targetFormat {
            guard let audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw VoiceInputError.internalError("Cannot create Live Voice audio converter")
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

            let pcmData = OppiDictationSession.convertToInt16PCM(buffer: outputBuffer)
            guard !pcmData.isEmpty else { return }
            onPCM(pcmData)
        }
    }

    static func pcm16LEBuffer(data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = Int(format.channelCount)
        guard channels > 0, data.count >= channels * 2 else { return nil }
        let frameCount = data.count / (channels * 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let floatChannels = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let byteOffset = (frame * channels + channel) * 2
                    let sample = Int16(bitPattern: UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8))
                    floatChannels[channel][frame] = max(-1, Float(sample) / 32768.0)
                }
            }
        }
        return buffer
    }
}
