import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "APIClient")

// MARK: - Tool Output & Session Attachments

extension APIClient {
    /// Fetch the full tool output for a specific tool call ID from the session's JSONL trace.
    ///
    /// Used to lazy-load evicted tool output when the user expands an old tool call row.
    private func getToolOutput(scope: SessionRouteScope, sessionId: String, toolCallId: String) async throws -> (output: String, isError: Bool) {
        struct Response: Decodable { let output: String; let isError: Bool }
        let response = try await get(
            "\(focusedSessionPath(scope: scope, sessionId: sessionId))/tool-output/\(toolCallId)",
            as: Response.self
        )
        return (response.output, response.isError)
    }

    /// Fetch full tool output and return nil if it is empty/whitespace-only.
    func getNonEmptyToolOutput(scope: SessionRouteScope, sessionId: String, toolCallId: String) async throws -> String? {
        let (output, _) = try await getToolOutput(scope: scope, sessionId: sessionId, toolCallId: toolCallId)
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : output
    }

    /// Fetch raw full (untruncated) tool output from the server temp-file side channel.
    ///
    /// Returns nil when the server no longer has the backing temp file (404).
    private func getFullToolOutput(scope: SessionRouteScope, sessionId: String, toolCallId: String) async throws -> String? {
        do {
            struct Response: Decodable { let output: String }
            return try await get(
                "\(focusedSessionPath(scope: scope, sessionId: sessionId))/tool-output/\(toolCallId)?full=true",
                as: Response.self
            ).output
        } catch let APIError.server(status, _) where status == 404 {
            return nil
        }
    }

    /// Fetch full untruncated tool output and return nil if empty/whitespace-only.
    func getNonEmptyFullToolOutput(scope: SessionRouteScope, sessionId: String, toolCallId: String) async throws -> String? {
        guard let output = try await getFullToolOutput(scope: scope, sessionId: sessionId, toolCallId: toolCallId) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : output
    }

    func headFullToolOutput(
        scope: SessionRouteScope,
        sessionId: String,
        toolCallId: String
    ) async throws -> Int? {
        let path = fullToolOutputPath(scope: scope, sessionId: sessionId, toolCallId: toolCallId)
        do {
            let (data, response) = try await request("HEAD", path: path)
            try checkStatus(response, data: data)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard let lengthValue = http.value(forHTTPHeaderField: "Content-Length"),
                  let length = Int(lengthValue),
                  length >= 0 else {
                return nil
            }
            return length
        } catch let APIError.server(status, _) where status == 404 {
            return nil
        }
    }

    /// Sidecar raw Range. Do not decode/re-encode these bytes: invalid UTF-8
    /// still occupies wire offsets.
    func getTerminalOutputRange(
        scope: SessionRouteScope, sessionId: String, toolCallId: String, range: Range<Int>
    ) async throws -> TerminalOutputRange {
        guard !range.isEmpty, range.lowerBound >= 0 else { throw APIError.invalidResponse }
        let path = fullToolOutputPath(scope: scope, sessionId: sessionId, toolCallId: toolCallId)
        let (data, response) = try await performAuthorized {
            var req = try URLRequest(url: self.makeURL(path: path))
            req.httpMethod = "GET"
            req.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            return req
        }
        try checkStatus(response, data: data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let parsed = ToolOutputSidecarHTTP.parseContentRange(http.value(forHTTPHeaderField: "Content-Range")),
              parsed.end < parsed.total, data.count == parsed.end - parsed.start + 1 else {
            throw APIError.invalidResponse
        }
        return TerminalOutputRange(data: data, start: parsed.start, end: parsed.end + 1, totalBytes: parsed.total)
    }

    func getFullToolOutputSidecarWindow(
        scope: SessionRouteScope,
        sessionId: String,
        toolCallId: String,
        startByte: Int,
        maxBytes: Int = ToolOutputSidecarHTTP.firstWindowBytes
    ) async throws -> ToolOutputSidecarWindow? {
        guard startByte >= 0, maxBytes > 0 else { return nil }
        let endByte = startByte + maxBytes - 1
        let path = fullToolOutputPath(scope: scope, sessionId: sessionId, toolCallId: toolCallId)
        do {
            let (data, response) = try await performAuthorized {
                var req = try URLRequest(url: self.makeURL(path: path))
                req.httpMethod = "GET"
                req.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")
                logger.debug("GET \(path) Range bytes=\(startByte)-\(endByte)")
                return req
            }
            try checkStatus(response, data: data)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard let parsed = ToolOutputSidecarHTTP.parseContentRange(
                http.value(forHTTPHeaderField: "Content-Range")
            ) else {
                throw APIError.invalidResponse
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw APIError.invalidResponse
            }
            return ToolOutputSidecarWindow(
                text: text,
                endByteOffset: parsed.end + 1,
                totalBytes: parsed.total
            )
        } catch let APIError.server(status, _) where status == 404 {
            return nil
        }
    }

    /// First sidecar window: HEAD + Range for large output, JSON for small.
    /// HEAD miss uses Range without decoding `?full=true` JSON.
    func openFullToolOutputSidecar(
        scope: SessionRouteScope,
        sessionId: String,
        toolCallId: String
    ) async throws -> ToolOutputSidecarWindow? {
        if let total = try await headFullToolOutput(
            scope: scope,
            sessionId: sessionId,
            toolCallId: toolCallId
        ) {
            if total == 0 { return nil }
            if total <= ToolOutputSidecarHTTP.firstWindowBytes {
                guard let text = try await getFullToolOutput(
                    scope: scope,
                    sessionId: sessionId,
                    toolCallId: toolCallId
                ) else {
                    return nil
                }
                let bytes = text.utf8.count
                return ToolOutputSidecarWindow(
                    text: text,
                    endByteOffset: bytes,
                    totalBytes: max(total, bytes)
                )
            }
            return try await getFullToolOutputSidecarWindow(
                scope: scope,
                sessionId: sessionId,
                toolCallId: toolCallId,
                startByte: 0
            )
        }

        // HEAD miss: Range without Content-Length. Do not JSON-decode a large sidecar.
        return try await getFullToolOutputSidecarWindow(
            scope: scope,
            sessionId: sessionId,
            toolCallId: toolCallId,
            startByte: 0
        )
    }

    private func fullToolOutputPath(
        scope: SessionRouteScope,
        sessionId: String,
        toolCallId: String
    ) -> String {
        "\(focusedSessionPath(scope: scope, sessionId: sessionId))/tool-output/\(toolCallId)?full=true"
    }

    /// Fetch a generated session attachment by id.
    ///
    /// Session attachments are server-owned artifacts (for example, voice_speak audio)
    /// stored in the Oppi data directory rather than the workspace checkout.
    func fetchSessionAttachment(
        scope: SessionRouteScope?,
        sessionId: String,
        attachmentId: String
    ) async throws -> Data {
        let pathSegments: [String]
        if scope == .control {
            pathSegments = ["control-sessions", sessionId, "attachments", attachmentId]
        } else {
            pathSegments = ["sessions", sessionId, "attachments", attachmentId]
        }
        let url = try makeURL(pathSegments: pathSegments)
        logger.debug("GET \(url.path)")

        let (data, response) = try await performAuthorized {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            req.httpMethod = "GET"
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            return req
        }
        try checkStatus(response, data: data)
        try checkCompleteSessionAttachmentResponse(response, data: data)
        return data
    }

    private func checkCompleteSessionAttachmentResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard http.statusCode != 206 else {
            throw APIError.server(status: http.statusCode, message: "Attachment response was partial")
        }
        guard let contentLengthValue = http.value(forHTTPHeaderField: "Content-Length"),
              let expectedBytes = Int(contentLengthValue),
              expectedBytes >= 0 else {
            return
        }
        guard data.count == expectedBytes else {
            throw APIError.server(
                status: http.statusCode,
                message: "Attachment download was incomplete (\(data.count)/\(expectedBytes) bytes)"
            )
        }
    }
}
