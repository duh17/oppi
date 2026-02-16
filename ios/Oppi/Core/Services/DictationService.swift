import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Dictation")

/// Records audio from the microphone and ships chunks to a configurable
/// OpenAI-compatible STT endpoint for transcription.
///
/// Design:
/// - Uses `AVAudioEngine` for low-latency mic capture.
/// - Buffers audio into chunks of configurable duration.
/// - Ships each chunk as WAV to `POST /v1/audio/transcriptions`.
/// - Delivers partial transcription results via a callback.
/// - Silence detection auto-stops after configurable timeout.
///
/// The service is intentionally decoupled from any specific STT provider.
/// Any endpoint implementing the OpenAI audio transcriptions API works.
@MainActor @Observable
final class DictationService {

    enum State: Equatable {
        case idle
        case requesting     // requesting mic permission
        case recording
        case processing     // final chunk being transcribed
        case error(String)
    }

    private(set) var state: State = .idle

    /// Accumulated transcription text from all chunks in this session.
    private(set) var transcribedText: String = ""

    /// Called on main actor whenever new text is transcribed.
    var onTranscription: ((String) -> Void)?

    private var config: DictationConfig = .default
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private var chunkTimer: Task<Void, Never>?
    private var silenceTimer: Task<Void, Never>?
    private var activeTasks: [Task<Void, Never>] = []

    /// RMS threshold below which audio is considered silence.
    private let silenceRMSThreshold: Float = 0.01

    /// Audio sample rate for recording (16kHz is standard for STT models).
    private let sampleRate: Double = 16_000

    // MARK: - Public API

    /// Start dictation with the given config.
    func start(config: DictationConfig) {
        guard state == .idle || state == .error("") || isErrorState else {
            logger.warning("Dictation start ignored — state: \(String(describing: self.state))")
            return
        }

        self.config = config
        transcribedText = ""

        guard config.hasValidEndpoint else {
            state = .error("No STT endpoint configured")
            return
        }

        state = .requesting
        Task {
            await requestPermissionAndRecord()
        }
    }

    /// Stop dictation, transcribe remaining audio, and finalize.
    func stop() {
        guard state == .recording else { return }
        state = .processing

        chunkTimer?.cancel()
        chunkTimer = nil
        silenceTimer?.cancel()
        silenceTimer = nil

        // Transcribe remaining buffer
        let remaining = flushBuffer()
        stopAudioEngine()

        if !remaining.isEmpty {
            let task = Task {
                let text = await transcribeAudio(remaining)
                guard !Task.isCancelled else { return }
                appendTranscription(text)
                state = .idle
            }
            activeTasks.append(task)
        } else {
            state = .idle
        }
    }

    /// Cancel dictation immediately without transcribing remaining audio.
    func cancel() {
        chunkTimer?.cancel()
        chunkTimer = nil
        silenceTimer?.cancel()
        silenceTimer = nil
        for task in activeTasks { task.cancel() }
        activeTasks.removeAll()
        stopAudioEngine()
        audioBuffer.removeAll()
        transcribedText = ""
        state = .idle
    }

    var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }

    // MARK: - Audio Recording

    private func requestPermissionAndRecord() async {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { result in
                    continuation.resume(returning: result)
                }
            }
        }

        guard granted else {
            state = .error("Microphone permission denied")
            return
        }

        do {
            try startAudioEngine()
            state = .recording
            startChunkTimer()
            resetSilenceTimer()
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            state = .error("Mic unavailable: \(error.localizedDescription)")
        }
    }

    private func startAudioEngine() throws {
        let engine = AVAudioEngine()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Convert to mono 16kHz for STT
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "DictationService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create target audio format",
            ])
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "DictationService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create audio converter",
            ])
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Convert to target format
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
            else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil,
                  let channelData = convertedBuffer.floatChannelData
            else { return }

            let samples = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(convertedBuffer.frameLength)
            ))

            Task { @MainActor [weak self] in
                self?.audioBuffer.append(contentsOf: samples)
                self?.checkSilence(samples)
            }
        }

        try engine.start()
        audioEngine = engine
    }

    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func flushBuffer() -> [Float] {
        let samples = audioBuffer
        audioBuffer.removeAll(keepingCapacity: true)
        return samples
    }

    // MARK: - Chunk Timer

    private func startChunkTimer() {
        chunkTimer?.cancel()
        let interval = config.effectiveChunkDuration
        chunkTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, state == .recording else { break }
                shipCurrentChunk()
            }
        }
    }

    private func shipCurrentChunk() {
        let samples = flushBuffer()
        guard !samples.isEmpty else { return }

        let task = Task {
            let text = await transcribeAudio(samples)
            guard !Task.isCancelled else { return }
            appendTranscription(text)
        }
        activeTasks.append(task)
    }

    // MARK: - Silence Detection

    private func checkSilence(_ samples: [Float]) {
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(max(samples.count, 1)))
        if rms > silenceRMSThreshold {
            resetSilenceTimer()
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        let timeout = config.effectiveSilenceTimeout
        silenceTimer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, state == .recording else { return }
            logger.info("Silence timeout — auto-stopping dictation")
            stop()
        }
    }

    // MARK: - Transcription

    private func transcribeAudio(_ samples: [Float]) async -> String {
        guard let url = config.transcriptionURL else { return "" }

        // Encode as WAV
        let wavData = encodeWAV(samples: samples, sampleRate: Int(sampleRate))

        // Build multipart form request
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        // File field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        appendField("model", config.model)
        if !config.language.isEmpty {
            appendField("language", config.language)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Dictation: non-HTTP response")
                return ""
            }

            guard httpResponse.statusCode == 200 else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                logger.error("Dictation STT error \(httpResponse.statusCode): \(bodyStr)")
                return ""
            }

            // Parse OpenAI-compatible response: { "text": "..." }
            struct TranscriptionResponse: Decodable {
                let text: String
            }
            let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            return result.text
        } catch {
            if !Task.isCancelled {
                logger.error("Dictation transcription failed: \(error.localizedDescription)")
            }
            return ""
        }
    }

    private func appendTranscription(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !transcribedText.isEmpty {
            transcribedText += " "
        }
        transcribedText += trimmed
        onTranscription?(transcribedText)
    }

    // MARK: - WAV Encoding

    private func encodeWAV(samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        let headerSize = 44

        var data = Data(capacity: headerSize + dataSize)

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLittleEndian32(&data, UInt32(headerSize + dataSize - 8))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLittleEndian32(&data, 16) // chunk size
        appendLittleEndian16(&data, 1)  // PCM
        appendLittleEndian16(&data, 1)  // mono
        appendLittleEndian32(&data, UInt32(sampleRate))
        appendLittleEndian32(&data, UInt32(sampleRate * bytesPerSample))
        appendLittleEndian16(&data, UInt16(bytesPerSample)) // block align
        appendLittleEndian16(&data, 16) // bits per sample

        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLittleEndian32(&data, UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767)
            appendLittleEndian16(&data, UInt16(bitPattern: int16))
        }

        return data
    }

    private func appendLittleEndian32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func appendLittleEndian16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
}
