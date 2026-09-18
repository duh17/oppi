import Foundation

/// One UTF-8 window of a full tool-output sidecar.
///
/// `endByteOffset` is exclusive and already closed on a codepoint boundary.
struct ToolOutputSidecarWindow: Sendable, Equatable {
    let text: String
    let endByteOffset: Int
    let totalBytes: Int

    var isComplete: Bool { endByteOffset >= totalBytes }
}

/// Loads sidecar windows without materializing `?full=true` JSON for large output.
struct ToolOutputSidecarWindowSource: Sendable {
    let loadFirst: @Sendable () async throws -> ToolOutputSidecarWindow?
    let loadNext: @Sendable (_ startByte: Int) async throws -> ToolOutputSidecarWindow?
}

/// Expand vs copy fetch policy for tool-output sidecars.
///
/// Expand paints from a HEAD+Range first window (or an already-held preview).
/// Copy still materializes `?full=true` JSON so the clipboard is complete.
enum ExpandedToolOutputFetch {
    struct Result: Equatable, ExpressibleByStringLiteral, Sendable {
        let text: String
        let previewOnly: Bool
        let totalBytes: Int?

        init(text: String, previewOnly: Bool = false, totalBytes: Int? = nil) {
            self.text = text
            self.previewOnly = previewOnly
            self.totalBytes = previewOnly ? totalBytes : nil
        }

        init(stringLiteral value: String) {
            self.init(text: value)
        }

        init(_ window: ToolOutputSidecarWindow) {
            self.init(
                text: window.text,
                previewOnly: !window.isComplete,
                totalBytes: window.totalBytes
            )
        }
    }

    static func isShellSidecarTool(_ tool: String) -> Bool {
        ToolCallFormatting.isBashTool(tool)
            || ToolCallFormatting.isGrepTool(tool)
            || ToolCallFormatting.isFindTool(tool)
            || ToolCallFormatting.isLsTool(tool)
    }

    static func shouldSkipExpandFetch(
        tool: String,
        hasCompleteOutput: Bool,
        storedPreview: String
    ) -> Bool {
        if hasCompleteOutput {
            return true
        }
        return isShellSidecarTool(tool) && !storedPreview.isEmpty
    }

    static func fetchForExpand(
        tool: String,
        apiClient: APIClient,
        scope: SessionRouteScope,
        sessionId: String,
        toolCallId: String
    ) async throws -> Result {
        if isShellSidecarTool(tool) {
            if let window = try await apiClient.openFullToolOutputSidecar(
                scope: scope,
                sessionId: sessionId,
                toolCallId: toolCallId
            ) {
                return Result(window)
            }
            return ""
        }

        return Result(
            text: try await apiClient.getNonEmptyToolOutput(
                scope: scope,
                sessionId: sessionId,
                toolCallId: toolCallId
            ) ?? ""
        )
    }

    static func fetchForCopy(
        apiClient: APIClient,
        scope: SessionRouteScope,
        sessionId: String,
        toolCallId: String
    ) async throws -> String? {
        try await apiClient.getNonEmptyFullToolOutput(
            scope: scope,
            sessionId: sessionId,
            toolCallId: toolCallId
        )
    }
}

enum ToolOutputSidecarHTTP {
    static let firstWindowBytes = 128 * 1024

    static func parseContentRange(_ value: String?) -> (start: Int, end: Int, total: Int)? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = trimmed.dropFirst("bytes ".count).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int(parts[1]), total >= 0 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), start >= 0, end >= start else {
            return nil
        }
        return (start, end, total)
    }
}
