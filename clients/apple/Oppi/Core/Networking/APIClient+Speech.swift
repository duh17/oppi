import Foundation

// MARK: - Read aloud

extension APIClient {
    /// `POST /speech`: read `text` aloud with the server's TTS provider. Returns
    /// when the first passage is synthesized and response headers arrive; the
    /// remaining audio follows on `chunks` as the server synthesizes it.
    func speech(text: String) async throws -> SpeechAudioStream {
        struct Body: Encodable { let text: String }
        let body = try JSONEncoder().encode(Body(text: text))
        let (bytes, response) = try await performAuthorizedBytes {
            var req = try URLRequest(url: self.makeURL(path: "/speech"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            // The server goes quiet while it synthesizes each passage.
            req.timeoutInterval = 300
            return req
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 16_384 { break }
            }
            bytes.task.cancel()
            try checkStatus(response, data: data)
            throw APIError.invalidResponse
        }

        let audioBytes = bytes
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let reader = Task {
                do {
                    // Each passage arrives as one large write; hand it on in pieces.
                    var piece = Data()
                    for try await byte in audioBytes {
                        piece.append(byte)
                        if piece.count >= 16_384 {
                            continuation.yield(piece)
                            piece = Data()
                        }
                    }
                    if !piece.isEmpty { continuation.yield(piece) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                audioBytes.task.cancel()
            }
        }
        return SpeechAudioStream(
            sampleRate: Double(http.value(forHTTPHeaderField: "X-Oppi-Sample-Rate") ?? "") ?? 0,
            channels: Int(http.value(forHTTPHeaderField: "X-Oppi-Channels") ?? "") ?? 0,
            chunks: chunks
        )
    }
}
