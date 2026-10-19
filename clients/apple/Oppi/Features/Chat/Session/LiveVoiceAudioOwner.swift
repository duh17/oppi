import Accelerate
@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Duplex capture owner for Live Voice. Mute stops the input tap.
///
/// This is not the dictation stream. PCM is handed to the Live Voice call
/// channel so the server Yuwp adapter can commit utterances.
@MainActor
protocol LiveVoiceAudioOwning: AnyObject {
    var isCapturing: Bool { get }
    var openedDictationStream: Bool { get }
    var onPCM: (@MainActor (Data) -> Void)? { get set }
    /// True while the agent's reply is playing, false once it has gone quiet.
    var onPlaybackActiveChange: (@MainActor (Bool) -> Void)? { get set }
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
    var onPlaybackActiveChange: (@MainActor (Bool) -> Void)? { get set }
    func play(_ pcm: Data)
    func stopPlayback()
    func teardown()
}

@MainActor
final class LiveVoiceAudioOwner: LiveVoiceAudioOwning {
    private(set) var isCapturing = false
    let openedDictationStream = false
    var onPCM: (@MainActor (Data) -> Void)?
    var onPlaybackActiveChange: (@MainActor (Bool) -> Void)? {
        get { playback?.onPlaybackActiveChange }
        set { playback?.onPlaybackActiveChange = newValue }
    }

    private let engine: LiveVoiceCaptureEngine
    private let playback: LiveVoicePlaybackEngine?
    private var started = false
    private var muted = false

    init(
        engine: LiveVoiceCaptureEngine,
        playback: LiveVoicePlaybackEngine? = nil
    ) {
        self.engine = engine
        self.playback = playback ?? (engine as? LiveVoicePlaybackEngine)
    }

    func start() async throws {
        started = true
        muted = false
        // Same process-wide claim dictation holds: read aloud and media autoplay
        // stay quiet while the call owns the microphone and speaker.
        AudioPlayerService.beginProcessCaptureInterruption(owner: self)
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
        AudioPlayerService.endProcessCaptureInterruption(owner: self)
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

/// Jitter buffer for Live Voice playback, kept apart from AVFoundation so it is testable.
///
/// Network audio arrives in uneven chunks. Playing each one the moment it lands turns every
/// late chunk into an audible gap, so a reply starts only once `primeFrames` are queued (or
/// `primeWait` has passed, for short replies), and the queue re-primes whenever it runs dry.
struct LiveVoicePlaybackScheduler {
    enum Decision: Equatable {
        /// Keep the chunk until the queue is primed.
        case hold
        /// Play everything held so far, then this chunk.
        case startWithHeld
        /// Already playing: queue the chunk behind the others.
        case schedule
    }

    /// One call's playback, logged when the call's audio stops.
    struct Stats: Equatable {
        var chunks = 0
        var receivedFrames = 0
        /// Longest wait between two chunks of the same reply, in milliseconds.
        var maxGapMs = 0
        /// The queue ran dry and more audio of the same reply arrived soon after.
        var underruns = 0
        /// Queued audio dropped because the user talked over the reply.
        var flushes = 0
    }

    static let sampleRate = 24_000
    static let primeFrames = sampleRate * 180 / 1000
    static let primeWait: TimeInterval = 0.3
    /// Gaps longer than this are a pause between replies, not jitter.
    static let replyGap: TimeInterval = 1.0

    private(set) var stats = Stats()
    /// A reply is on its way out of the speaker: started and not yet drained or flushed.
    var isPlaying: Bool { !priming }
    private var priming = true
    private var heldFrames = 0
    private var queuedFrames = 0
    private var lastArrival: TimeInterval?
    private var drainedAt: TimeInterval?

    mutating func receive(frames: Int, at now: TimeInterval) -> Decision {
        stats.chunks += 1
        stats.receivedFrames += frames
        if let lastArrival, now - lastArrival < Self.replyGap {
            stats.maxGapMs = max(stats.maxGapMs, Int(((now - lastArrival) * 1000).rounded()))
        }
        lastArrival = now
        guard priming else {
            queuedFrames += frames
            return .schedule
        }
        if heldFrames == 0, let drainedAt, now - drainedAt < Self.replyGap {
            stats.underruns += 1
        }
        heldFrames += frames
        guard heldFrames >= Self.primeFrames else { return .hold }
        startHeld()
        return .startWithHeld
    }

    /// The prime wait ran out; true when held audio should start now.
    mutating func primeTimedOut() -> Bool {
        guard priming, heldFrames > 0 else { return false }
        startHeld()
        return true
    }

    mutating func played(frames: Int, at now: TimeInterval) {
        queuedFrames = max(0, queuedFrames - frames)
        guard !priming, queuedFrames == 0 else { return }
        priming = true
        drainedAt = now
    }

    /// Drops held and queued audio. Only a drop the user caused counts as a flush.
    mutating func flush(userTalked: Bool) {
        if userTalked, heldFrames > 0 || queuedFrames > 0 { stats.flushes += 1 }
        priming = true
        heldFrames = 0
        queuedFrames = 0
        drainedAt = nil
        lastArrival = nil
    }

    private mutating func startHeld() {
        priming = false
        queuedFrames += heldFrames
        heldFrames = 0
    }
}

/// The call's latest mic and playback spectra for the composer's orb.
///
/// The audio taps write it on their own threads, with the same analyzer dictation uses and
/// no allocation; the orb reads it once per drawn frame. Nothing here waits on the UI, so a
/// call in the background or with the screen off does the same audio work as before.
final class LiveVoiceAudioMeter: Sendable {
    struct Levels: Equatable, Sendable {
        var mic = VoiceSpectrumFrame.zero
        var playback = VoiceSpectrumFrame.zero
    }

    private let levels = Mutex(Levels())

    var current: Levels { levels.withLock { $0 } }

    func publishMic(_ frame: VoiceSpectrumFrame) {
        levels.withLock { $0.mic = frame }
    }

    func publishPlayback(_ frame: VoiceSpectrumFrame) {
        levels.withLock { $0.playback = frame }
    }

    func reset() {
        levels.withLock { $0 = Levels() }
    }
}

/// One play-and-record session so Live Voice capture can coexist with playback.
@MainActor
final class LiveVoiceDuplexCaptureEngine: LiveVoiceCaptureEngine, LiveVoicePlaybackEngine {
    /// A pause this long ends a reply. Shorter gaps fall between two sentences of one reply.
    private static let quietAfterReply: Duration = .milliseconds(600)

    private(set) var isCapturing = false
    var onPlaybackActiveChange: (@MainActor (Bool) -> Void)?
    private let meter: LiveVoiceAudioMeter
    private var reportedPlaying = false
    private var quietTask: Task<Void, Never>?
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var tapInstalled = false
    private var scheduler = LiveVoicePlaybackScheduler()
    private var held: [AVAudioPCMBuffer] = []
    /// Bumped on every flush so callbacks from dropped buffers are ignored.
    private var generation = 0
    private var primeTimer: Task<Void, Never>?
    private var echoCancellation = false
    private var onPCM: (@Sendable (Data) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var recoveries = 0

    init(meter: LiveVoiceAudioMeter) {
        self.meter = meter
    }

    func start(onPCM: @escaping @Sendable (Data) -> Void) throws {
        // The session is set up here, once per capture start, never per played chunk.
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
        self.onPCM = onPCM
        observeAudioChanges(of: engine)
        enableEchoCancellation(on: engine)
        // Install the mic tap on a bare engine. Attaching the 24 kHz playback
        // graph first makes inputNode.outputFormat report 0 Hz on device.
        try LiveVoiceCaptureEngineHelper.installTap(engine: engine, meter: meter, onPCM: onPCM)
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
        // A removed tap sends no more frames; the orb must not hold the last word.
        meter.publishMic(.zero)
    }

    func stopPlayback() {
        dropPlayback(userTalked: true)
    }

    private func dropPlayback(userTalked: Bool) {
        generation &+= 1
        primeTimer?.cancel()
        primeTimer = nil
        held.removeAll()
        scheduler.flush(userTalked: userTalked)
        player?.stop()
        player?.reset()
        // Dropped audio is over now, not after the quiet delay: the user is talking.
        quietTask?.cancel()
        quietTask = nil
        setPlaybackActive(false)
    }

    /// Reports a reply starting at once and ending only after `quietAfterReply` of silence,
    /// so the gap between two sentences does not flip the call back to listening.
    private func reportPlaybackActivity() {
        if scheduler.isPlaying {
            quietTask?.cancel()
            quietTask = nil
            setPlaybackActive(true)
            return
        }
        guard reportedPlaying, quietTask == nil else { return }
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: Self.quietAfterReply)
            guard let self, !Task.isCancelled else { return }
            self.quietTask = nil
            if !self.scheduler.isPlaying { self.setPlaybackActive(false) }
        }
    }

    private func setPlaybackActive(_ active: Bool) {
        guard reportedPlaying != active else { return }
        reportedPlaying = active
        onPlaybackActiveChange?(active)
    }

    func teardown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        onPCM = nil
        stopCapture()
        let stats = scheduler.stats
        stopPlayback()
        audioEngine?.stop()
        if let player {
            player.removeTap(onBus: 0)
            audioEngine?.detach(player)
        }
        player = nil
        playbackFormat = nil
        audioEngine = nil
        meter.reset()
        Self.logCallAudio(stats, echoCancellation: echoCancellation, recoveries: recoveries)
        scheduler = LiveVoicePlaybackScheduler()
        echoCancellation = false
        recoveries = 0
    }

    func play(_ pcm: Data) {
        // Audio before the call's engine exists has nowhere to play.
        guard !pcm.isEmpty, let player, let format = playbackFormat,
              let buffer = LiveVoiceCaptureEngineHelper.pcm16LEBuffer(data: pcm, format: format) else {
            return
        }
        switch scheduler.receive(frames: Int(buffer.frameLength), at: ProcessInfo.processInfo.systemUptime) {
        case .hold:
            held.append(buffer)
            armPrimeTimer()
        case .startWithHeld:
            held.append(buffer)
            startHeld()
        case .schedule:
            schedule(buffer, on: player)
        }
    }

    private func armPrimeTimer() {
        guard primeTimer == nil else { return }
        let generation = generation
        primeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LiveVoicePlaybackScheduler.primeWait))
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.primeTimer = nil
            if self.scheduler.primeTimedOut() { self.startHeld() }
        }
    }

    private func startHeld() {
        primeTimer?.cancel()
        primeTimer = nil
        guard let player else { return }
        // A restart that failed earlier left the engine stopped; a stopped player plays nothing.
        if audioEngine?.isRunning == false { restartEngine(reason: "stopped_at_reply") }
        let buffers = held
        held.removeAll()
        for buffer in buffers { schedule(buffer, on: player) }
        if !player.isPlaying { player.play() }
        reportPlaybackActivity()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode) {
        let generation = generation
        let frames = Int(buffer.frameLength)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.scheduler.played(frames: frames, at: ProcessInfo.processInfo.systemUptime)
                self.reportPlaybackActivity()
            }
        }
    }

    /// AirPods connecting, a phone call or Siri, or a speaker change stops the engine, and no
    /// more audio plays or records until it restarts. Restart it with the same graph.
    private func observeAudioChanges(of engine: AVAudioEngine) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover(reason: "configuration_change") }
        })
        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
            MainActor.assumeIsolated { self?.recover(reason: "interruption_ended") }
        })
        #endif
    }

    private func recover(reason: String) {
        guard let engine = audioEngine else { return }
        recoveries += 1
        // Queued audio was lost with the stopped engine; start the next reply primed.
        dropPlayback(userTalked: false)
        if isCapturing, let onPCM {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            tapInstalled = false
            do {
                try LiveVoiceCaptureEngineHelper.installTap(engine: engine, meter: meter, onPCM: onPCM)
                tapInstalled = true
            } catch {
                Self.logRestartFailure(reason: reason, step: "mic_tap", error: error)
            }
        }
        // Playback restarts even if the mic could not; the next reply retries a failed start.
        restartEngine(reason: reason)
    }

    private func restartEngine(reason: String) {
        guard let engine = audioEngine, !engine.isRunning else { return }
        do {
            try activateSession()
            engine.prepare()
            try engine.start()
        } catch {
            Self.logRestartFailure(reason: reason, step: "engine", error: error)
        }
    }

    private static func logRestartFailure(reason: String, step: String, error: Error) {
        ClientLog.warning("LiveVoice", "Audio restart failed", metadata: [
            "reason": reason,
            "step": step,
            "error_domain": (error as NSError).domain,
            "error_code": String((error as NSError).code),
        ])
    }

    /// Voice processing cancels the speaker's echo from the mic. Without it the server hears
    /// Grok's own voice, takes it for the user talking over the reply, and cuts the reply off.
    private func enableEchoCancellation(on engine: AVAudioEngine) {
        // Voice processing can only change on a stopped engine (unmute restarts capture on a
        // running one).
        guard !engine.isRunning, !engine.inputNode.isVoiceProcessingEnabled else { return }
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            echoCancellation = true
        } catch {
            ClientLog.warning("LiveVoice", "Echo cancellation unavailable", metadata: [
                "error_domain": (error as NSError).domain,
                "error_code": String((error as NSError).code),
            ])
        }
    }

    private static func logCallAudio(
        _ stats: LiveVoicePlaybackScheduler.Stats,
        echoCancellation: Bool,
        recoveries: Int
    ) {
        ClientLog.info("LiveVoice", "Call playback", metadata: [
            "chunks": String(stats.chunks),
            "received_ms": String(stats.receivedFrames * 1000 / LiveVoicePlaybackScheduler.sampleRate),
            "max_gap_ms": String(stats.maxGapMs),
            "underruns": String(stats.underruns),
            "flushes": String(stats.flushes),
            "echo_cancellation": String(echoCancellation),
            "audio_restarts": String(recoveries),
        ], flush: true)
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
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(LiveVoicePlaybackScheduler.sampleRate),
            channels: 1
        ) else {
            throw VoiceInputError.internalError("Cannot create Live Voice playback format")
        }
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try LiveVoiceCaptureEngineHelper.installPlaybackTap(player: playerNode, format: format, meter: meter)
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

    /// The agent's voice as it leaves the speaker, measured like the mic so the orb moves
    /// with whichever side is talking.
    static func installPlaybackTap(
        player: AVAudioPlayerNode,
        format: AVAudioFormat,
        meter: LiveVoiceAudioMeter
    ) throws {
        let spectrum = try VoiceSpectrumAnalyzer()
        player.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            meter.publishPlayback(spectrum.analyze(buffer))
        }
    }

    static func installTap(
        engine: AVAudioEngine,
        meter: LiveVoiceAudioMeter,
        onPCM: @escaping @Sendable (Data) -> Void
    ) throws {
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
        // Spectrum from the native-rate tap, as dictation measures it.
        let spectrum = try VoiceSpectrumAnalyzer()

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
            meter.publishMic(spectrum.analyze(buffer))
            let outputBuffer: AVAudioPCMBuffer
            if let converter {
                let frameCapacity = AVAudioFrameCount(ceil(
                    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
                ))
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCapacity
                ) else { return }

                var error: NSError?
                // Supply each tap buffer once. Returning it on every request repeats mic
                // audio to the server whenever the converter asks for more input.
                nonisolated(unsafe) var suppliedInput = false
                converter.convert(to: converted, error: &error) { _, outStatus in
                    guard !suppliedInput else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    suppliedInput = true
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
