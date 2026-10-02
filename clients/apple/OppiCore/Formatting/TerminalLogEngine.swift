// Shared terminal state code, linked only by the iOS app in this slice.
// OppiMac does not yet link the VT library or consume this owner.
#if canImport(GhosttyVt)
import Foundation
import GhosttyVt

/// Interprets passive tool logs, not an interactive PTY. Own on one executor;
/// native views never access borrowed Ghostty storage. Terminal effects remain
/// disabled: untrusted output cannot write the clipboard, open URLs or send input.
final class TerminalLogEngine {
    // Pipes do not carry terminal geometry. Keep interpretation stable while
    // the native reader wraps/reflows its presentation independently.
    static let columns: UInt16 = 120
    private var terminal: GhosttyTerminal?
    private var formatter: GhosttyFormatter?
    private var sourceBytes: [UInt8] = []
    private var formatted = ""

    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let result: GhosttyResult
        var description: String { "Terminal \(operation) failed (\(result.rawValue))" }
    }

    init() throws {
        try check(ghostty_terminal_new(nil, &terminal, Self.columns, 24), "creation")
        do {
            // Pipe LF means a fresh line at column zero. Use a mode default
            // rather than rewriting bytes (which would corrupt string controls).
            // GHOSTTY_MODE_LINEFEED is a function-like C macro, not imported
            // by Swift. Its documented encoding is ANSI mode 20.
            var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(20, true), value: true)
            try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &mode), "newline mode")
            // The source is already retained by the tool-output store. Do not
            // silently prune complete reader history at Ghostty's default cap.
            // Large render jobs are one-shot owners; avoid synchronous full
            // compression scans immediately before the formatter decompresses.
            try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil), "history bytes")
            try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, nil), "history lines")
            var options = GhosttyFormatterTerminalOptions()
            options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_VT
            options.unwrap = true
            options.trim = true
            // No screen/terminal extras: only resolved text and cell styles are
            // passed to the existing native SGR painter/chunk layout machinery.
            try check(ghostty_formatter_terminal_new(nil, &formatter, terminal, options), "formatter")
        } catch {
            ghostty_terminal_free(terminal)
            terminal = nil
            throw error
        }
    }

    deinit {
        ghostty_formatter_free(formatter)
        ghostty_terminal_free(terminal)
    }

    /// Cumulative input today; byte offsets/snapshots belong to the next protocol
    /// slice. Exact byte-prefix comparison is required, not Unicode equivalence.
    /// Non-append replacement tails reset the state; missing prior bytes cannot
    /// be recovered by any client-only renderer.
    func update(_ source: String) throws -> String {
        let bytes = Array(source.utf8)
        if bytes == sourceBytes { return formatted }
        let appending = bytes.starts(with: sourceBytes)
        if !appending {
            ghostty_terminal_reset(terminal)
            sourceBytes.removeAll(keepingCapacity: true)
        }
        do {
            let start = sourceBytes.count
            try bytes.withUnsafeBufferPointer { buffer in
                var offset = start
                while offset < buffer.count {
                    try Task.checkCancellation()
                    let count = min(128 * 1024, buffer.count - offset)
                    ghostty_terminal_vt_write(terminal, buffer.baseAddress?.advanced(by: offset), count)
                    offset += count
                }
            }
            var length = 0
            var output: UnsafeMutablePointer<UInt8>?
            try check(ghostty_formatter_format_alloc(formatter, nil, &output, &length), "formatting")
            defer { ghostty_free(nil, output, length) }
            let text = output.map { String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self) } ?? ""
            // Formatter line separators are CRLF. Native text layout needs LF;
            // no raw control data is being rewritten here. Keep a final pipe LF
            // because the formatter deliberately omits trailing blank rows.
            formatted = text.replacingOccurrences(of: "\r\n", with: "\n")
            if bytes.last == 0x0A, !formatted.hasSuffix("\n") { formatted += "\n" }
            sourceBytes = bytes
            return formatted
        } catch {
            ghostty_terminal_reset(terminal)
            sourceBytes.removeAll(keepingCapacity: true)
            throw error
        }
    }

    /// Used by detached reader/large-row jobs. Each job owns its engine, so
    /// cancellation and row reuse cannot reorder mutations on a shared engine.
    static func render(_ source: String) throws -> String {
        try TerminalLogEngine().update(source)
    }

    static func plainText(_ source: String) throws -> String {
        ANSIParser.strip(try render(source))
    }

    private func check(_ result: GhosttyResult, _ operation: String) throws {
        guard result == GHOSTTY_SUCCESS else { throw Failure(operation: operation, result: result) }
    }
}
#endif
