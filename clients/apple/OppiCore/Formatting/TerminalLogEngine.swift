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
    private let live: Bool
    private var lastByte: UInt8?
    private var committed: [(rows: Int, text: String)] = []
    private var committedRows = 0
    private var boundary: GhosttyTrackedGridRef?

    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let result: GhosttyResult
        var description: String { "Terminal \(operation) failed (\(result.rawValue))" }
    }

    init(live: Bool = false) throws {
        self.live = live
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
            if live {
                var lines = 1976 // active 24 + scrollback = 2000 physical rows
                try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines), "history lines")
            } else {
                try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, nil), "history lines")
            }
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
        ghostty_tracked_grid_ref_free(boundary)
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

    /// Byte feed retains parser state across UTF-8 and escape-sequence splits.
    /// No source history is retained.
    func feed(_ bytes: Data) throws {
        try bytes.withUnsafeBytes { buffer in
            let base = buffer.bindMemory(to: UInt8.self)
            var offset = 0
            while offset < base.count {
                try Task.checkCancellation()
                let count = min(64 * 1024, base.count - offset)
                ghostty_terminal_vt_write(terminal, base.baseAddress?.advanced(by: offset), count)
                offset += count
            }
        }
        if let byte = bytes.last { lastByte = byte }
    }

    /// Format immutable history only once; the cursor-addressable active area
    /// (including a soft-wrapped prefix in history) is always formatted fresh.
    /// Tracked boundary movement detects pruning even when row count plateaus.
    func paint() throws -> String {
        var history: UInt64 = 0
        var total: UInt64 = 0
        try check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &history), "history rows")
        try check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total), "total rows")
        if let boundary {
            var point = GhosttyPointCoordinate()
            if ghostty_tracked_grid_ref_point(boundary, GHOSTTY_POINT_TAG_SCREEN, &point) != GHOSTTY_SUCCESS
                || Int(point.y) > committedRows {
                committed.removeAll(keepingCapacity: true)
                committedRows = 0
            } else {
                var removed = committedRows - Int(point.y)
                while removed > 0, !committed.isEmpty {
                    removed -= committed.removeFirst().rows
                }
                if removed != 0 { // pruning cut a logical soft-wrapped line
                    committed.removeAll(keepingCapacity: true)
                    committedRows = 0
                } else {
                    committedRows = Int(point.y)
                }
            }
        }
        if Int(history) < committedRows {
            committed.removeAll(keepingCapacity: true)
            committedRows = 0
        }
        var rowStart = committedRows
        var y = rowStart
        while y < Int(history) {
            var ref = try gridRef(x: 0, y: y)
            var row = GhosttyRow()
            try check(ghostty_grid_ref_row(&ref, &row), "row")
            var wraps = false
            try check(ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, &wraps), "wrap")
            y += 1
            if !wraps {
                let text = try formatRows(rowStart..<y)
                committed.append((rows: y - rowStart, text: text))
                rowStart = y
            }
        }
        committedRows = rowStart
        ghostty_tracked_grid_ref_free(boundary)
        boundary = nil
        if committedRows < Int(total) {
            try check(ghostty_terminal_grid_ref_track(terminal, point(x: 0, y: committedRows), &boundary), "track")
        }
        let active = try formatRows(committedRows..<Int(total))
        formatted = (committed.map(\.text) + [active]).joined(separator: "\n")
        // Selection formatting retains selected trailing blank rows; match the
        // one-shot formatter's omission of empty terminal padding.
        while formatted.hasSuffix("\n") { formatted.removeLast() }
        if lastByte == 0x0A { formatted += "\n" }
        if live {
            let lines = formatted.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 2000 { formatted = lines.suffix(2000).joined(separator: "\n") }
        }
        return formatted
    }

    var memoryUsage: GhosttyTerminalMemoryUsage {
        var usage = GhosttyTerminalMemoryUsage()
        usage.size = MemoryLayout<GhosttyTerminalMemoryUsage>.size
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &usage)
        return usage
    }

    private func point(x: UInt16, y: Int) -> GhosttyPoint {
        var value = GhosttyPointValue()
        value.coordinate = GhosttyPointCoordinate(x: x, y: UInt32(y))
        return GhosttyPoint(tag: GHOSTTY_POINT_TAG_SCREEN, value: value)
    }

    private func gridRef(x: UInt16, y: Int) throws -> GhosttyGridRef {
        var ref = GhosttyGridRef()
        try check(ghostty_terminal_grid_ref(terminal, point(x: x, y: y), &ref), "grid reference")
        return ref
    }

    private func formatRows(_ rows: Range<Int>) throws -> String {
        guard !rows.isEmpty else { return "" }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = try gridRef(x: 0, y: rows.lowerBound)
        selection.end = try gridRef(x: Self.columns - 1, y: rows.upperBound - 1)
        // The selection convenience API emits palette/terminal extras for VT.
        // Use the configurable formatter so only text and SGR reach UIKit.
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_VT
        options.unwrap = true
        options.trim = true
        return try withUnsafePointer(to: &selection) { pointer in
            options.selection = pointer
            var length = 0
            var output: UnsafeMutablePointer<UInt8>?
            var regionFormatter: GhosttyFormatter?
            try check(ghostty_formatter_terminal_new(nil, &regionFormatter, terminal, options), "region formatter")
            defer { ghostty_formatter_free(regionFormatter) }
            try check(ghostty_formatter_format_alloc(regionFormatter, nil, &output, &length), "selection formatting")
            defer { ghostty_free(nil, output, length) }
            return (output.map { String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self) } ?? "")
                .replacingOccurrences(of: "\r\n", with: "\n")
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
