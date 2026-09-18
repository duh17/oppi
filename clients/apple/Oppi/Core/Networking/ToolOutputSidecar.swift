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
