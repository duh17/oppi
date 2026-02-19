import SwiftUI

/// Settings page for configuring the dictation (speech-to-text) backend.
///
/// Supports any OpenAI-compatible `/v1/audio/transcriptions` endpoint.
/// Common backends: MLX Server (Qwen3-ASR), OpenAI Whisper API, local Whisper.
struct DictationSettingsView: View {
    @State private var config = DictationConfig.load()
    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        List {
            Section {
                Toggle("Enable Dictation", isOn: $config.enabled)
                    .onChange(of: config.enabled) { _, _ in save() }
            } header: {
                Text("Dictation")
            } footer: {
                Text("Shows a microphone button in the composer. Requires a speech-to-text server.")
            }

            if config.enabled {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server URL")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                        TextField("http://mac-studio:8321", text: $config.endpointURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onSubmit { save() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                        TextField("default", text: $config.model)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onSubmit { save() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Language (optional)")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                        TextField("en", text: $config.language)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onSubmit { save() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key (optional)")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                        SecureField("Bearer token", text: $config.apiKey)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onSubmit { save() }
                    }
                } header: {
                    Text("STT Endpoint")
                } footer: {
                    Text("Any OpenAI-compatible `/v1/audio/transcriptions` endpoint.\nExamples: MLX Server, OpenAI API, local Whisper server.")
                }

                Section {
                    HStack {
                        Text("Chunk Duration")
                        Spacer()
                        Text("\(config.chunkDurationSeconds, specifier: "%.1f")s")
                            .foregroundStyle(.themeComment)
                            .monospacedDigit()
                    }
                    Slider(value: $config.chunkDurationSeconds, in: 1.0...10.0, step: 0.5)
                        .onChange(of: config.chunkDurationSeconds) { _, _ in save() }

                    HStack {
                        Text("Silence Timeout")
                        Spacer()
                        Text("\(config.silenceTimeoutSeconds, specifier: "%.1f")s")
                            .foregroundStyle(.themeComment)
                            .monospacedDigit()
                    }
                    Slider(value: $config.silenceTimeoutSeconds, in: 1.0...10.0, step: 0.5)
                        .onChange(of: config.silenceTimeoutSeconds) { _, _ in save() }
                } header: {
                    Text("Timing")
                } footer: {
                    Text("Chunk duration: how often audio is sent for transcription. Shorter = more responsive.\nSilence timeout: auto-stop after this many seconds of silence.")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Testing…")
                            } else {
                                Image(systemName: "network")
                                Text("Test Connection")
                            }
                        }
                    }
                    .disabled(isTesting || !config.hasValidEndpoint)

                    if let testResult {
                        switch testResult {
                        case .success(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.themeGreen)
                                .font(.caption)
                        case .failure(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.themeRed)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        config.save()
    }

    func testConnection() async {
        save()
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        guard let url = config.transcriptionURL else {
            testResult = .failure("Invalid endpoint URL")
            return
        }

        // Send a tiny silent WAV to test the endpoint
        let silentWAV = generateSilentWAV(durationMs: 500)

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(silentWAV)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        body.append(Data("\(config.model)\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        do {
            let start = ContinuousClock.now
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = ContinuousClock.now - start
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)

            guard let httpResponse = response as? HTTPURLResponse else {
                testResult = .failure("Non-HTTP response")
                return
            }

            if httpResponse.statusCode == 200 {
                struct Response: Decodable { let text: String }
                if let r = try? JSONDecoder().decode(Response.self, from: data) {
                    testResult = .success("Connected (\(ms)ms) — \"\(r.text.prefix(50))\"")
                } else {
                    testResult = .success("Connected (\(ms)ms)")
                }
            } else {
                let bodyStr = String(data: data.prefix(200), encoding: .utf8) ?? ""
                testResult = .failure("HTTP \(httpResponse.statusCode): \(bodyStr)")
            }
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    private func generateSilentWAV(durationMs: Int) -> Data {
        let sampleRate = 16000
        let numSamples = sampleRate * durationMs / 1000
        let dataSize = numSamples * 2
        let headerSize = 44

        var data = Data(capacity: headerSize + dataSize)

        // RIFF header
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE32(&data, UInt32(headerSize + dataSize - 8))
        data.append(contentsOf: Array("WAVE".utf8))

        // fmt
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE32(&data, 16)
        appendLE16(&data, 1)  // PCM
        appendLE16(&data, 1)  // mono
        appendLE32(&data, UInt32(sampleRate))
        appendLE32(&data, UInt32(sampleRate * 2))
        appendLE16(&data, 2)  // block align
        appendLE16(&data, 16) // bits

        // data
        data.append(contentsOf: Array("data".utf8))
        appendLE32(&data, UInt32(dataSize))
        data.append(Data(count: dataSize)) // silence

        return data
    }

    private func appendLE32(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 24) & 0xFF))
    }

    private func appendLE16(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
    }
}
