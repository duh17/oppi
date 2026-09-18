import Foundation

enum ANSIParser {

    // MARK: - Control Sequence Boundaries

    /// Return the byte after a CSI sequence, or `nil` when the sequence is
    /// incomplete in the current buffer.
    static func csiEnd<Buffer: RandomAccessCollection>(
        in buffer: Buffer,
        from start: Buffer.Index
    ) -> Buffer.Index? where Buffer.Element == UInt8 {
        var index = start
        while index != buffer.endIndex {
            let byte = buffer[index]
            if byte >= 0x40 && byte <= 0x7E {
                return buffer.index(after: index)
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    /// Return the byte after an OSC/string control sequence. OSC terminates
    /// with BEL, ST (`ESC\\`), or either raw/UTF-8 encoded C1 ST.
    private static func isEscStringControl(_ byte: UInt8) -> Bool {
        byte == 0x5D || byte == 0x50 || byte == 0x58 || byte == 0x5E || byte == 0x5F
    }

    private static func isC1StringControl(_ byte: UInt8) -> Bool {
        byte == 0x90 || byte == 0x98 || byte == 0x9D || byte == 0x9E || byte == 0x9F
    }

    private static func hasStringControl(_ input: String) -> Bool {
        input.contains("\u{001B}]")
            || input.contains("\u{001B}P")
            || input.contains("\u{001B}X")
            || input.contains("\u{001B}^")
            || input.contains("\u{001B}_")
            || input.unicodeScalars.contains { scalar in
                scalar.value <= 0xFF && isC1StringControl(UInt8(scalar.value))
            }
    }

    /// Remove OSC/DCS/SOS/PM/APC payloads while preserving SGR/CSI for the
    /// renderer below. This keeps string-control payloads out of both display
    /// and clipboard text without making every SGR scan understand them.
    static func stripStringControls(_ input: String) -> String {
        guard hasStringControl(input) else { return input }

        let buf = Array(input.utf8)
        let count = buf.count
        var result = [UInt8]()
        result.reserveCapacity(count)
        var i = 0

        while i < count {
            if buf[i] == 0x1B,
               i + 1 < count,
               isEscStringControl(buf[i + 1]) {
                i = oscEnd(
                    in: buf,
                    from: i + 2,
                    allowsBEL: buf[i + 1] == 0x5D
                ) ?? count
                continue
            }
            if buf[i] == 0xC2,
               i + 1 < count,
               isC1StringControl(buf[i + 1]) {
                i = oscEnd(
                    in: buf,
                    from: i + 2,
                    allowsBEL: buf[i + 1] == 0x9D
                ) ?? count
                continue
            }
            result.append(buf[i])
            i += 1
        }

        return String(decoding: result, as: UTF8.self)
    }

    static func oscEnd<Buffer: RandomAccessCollection>(
        in buffer: Buffer,
        from start: Buffer.Index,
        allowsBEL: Bool = true
    ) -> Buffer.Index? where Buffer.Element == UInt8 {
        var index = start
        while index != buffer.endIndex {
            let byte = buffer[index]
            if allowsBEL, byte == 0x07 { // BEL terminates OSC only
                return buffer.index(after: index)
            }
            if byte == 0x1B {
                let next = buffer.index(after: index)
                if next != buffer.endIndex, buffer[next] == 0x5C { // ESC \\
                    return buffer.index(after: next)
                }
            }
            if byte == 0xC2 {
                let next = buffer.index(after: index)
                if next != buffer.endIndex, buffer[next] == 0x9C { // UTF-8 C1 ST
                    return buffer.index(after: next)
                }
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    // MARK: - Incremental Stripper

    /// Tracks state for incremental ANSI stripping of monotonically growing content.
    ///
    /// During streaming, each chunk delivers the full accumulated output. Calling
    /// `strip()` on the whole string every time creates O(n^2) total work.
    /// `IncrementalStripper` only processes new bytes, keeping each update O(delta).
    ///
    /// Usage:
    /// ```
    /// var stripper = ANSIParser.IncrementalStripper()
    /// // On each streaming chunk (fullOutput grows monotonically):
    /// if let delta = stripper.delta(fullOutput) {
    ///     label.text?.append(delta)
    /// }
    /// ```
    struct IncrementalStripper {

        /// Input byte count fully processed so far.
        private(set) var processedInputBytes: Int = 0

        /// UTF-16 length of all stripped output produced so far.
        private(set) var strippedUTF16Length: Int = 0

        /// Whether the last processed byte was inside an incomplete escape sequence.
        private var pendingEscapeStart: Int = -1

        /// Return stripped delta text from new bytes in a growing input.
        ///
        /// Returns `nil` when the input hasn't grown (or only added bytes
        /// inside an incomplete escape sequence at the tail).
        mutating func delta(_ fullInput: String) -> String? {
            // Use withUTF8 for contiguous access without copying.
            var result: String?
            var input = fullInput
            input.withUTF8 { buffer in
                result = processDelta(buffer)
            }
            return result
        }

        /// Reset state. Call when the input is replaced (not just appended),
        /// e.g., cell reuse for a different tool's output.
        mutating func reset() {
            processedInputBytes = 0
            strippedUTF16Length = 0
            pendingEscapeStart = -1
        }

        // MARK: - Private

        private mutating func processDelta(
            _ buf: UnsafeBufferPointer<UInt8>
        ) -> String? {
            let count = buf.count
            guard count > processedInputBytes else { return nil }

            // Start scanning from where we left off.
            // If there was a pending incomplete escape, re-scan from its start.
            let scanStart: Int
            if pendingEscapeStart >= 0 {
                scanStart = pendingEscapeStart
            } else {
                scanStart = processedInputBytes
            }
            pendingEscapeStart = -1

            // Only emit bytes at or past the processedInputBytes boundary.
            let emitBoundary = processedInputBytes

            var out = [UInt8]()
            out.reserveCapacity(count - scanStart)

            var i = scanStart
            while i < count {
                if buf[i] == 0x1B {
                    // Incomplete escape introducer at chunk boundary.
                    if i + 1 >= count {
                        pendingEscapeStart = i
                        processedInputBytes = i
                        break
                    }

                    if buf[i + 1] == 0x5B || ANSIParser.isEscStringControl(buf[i + 1]) {
                        let sequenceStart = i + 2
                        let end = buf[i + 1] == 0x5B
                            ? ANSIParser.csiEnd(in: buf, from: sequenceStart)
                            : ANSIParser.oscEnd(
                                in: buf,
                                from: sequenceStart,
                                allowsBEL: buf[i + 1] == 0x5D
                            )
                        if let end {
                            i = end
                            continue
                        }
                        // Incomplete escape — save position for re-scan.
                        pendingEscapeStart = i
                        processedInputBytes = i
                        break
                    }

                    // Unsupported / standalone ESC byte. Drop it and keep scanning.
                    i += 1
                    continue
                }

                if buf[i] == 0xC2 {
                    guard i + 1 < count else {
                        pendingEscapeStart = i
                        processedInputBytes = i
                        break
                    }
                    if buf[i + 1] == 0x9B || ANSIParser.isC1StringControl(buf[i + 1]) {
                        let sequenceStart = i + 2
                        let end = buf[i + 1] == 0x9B
                            ? ANSIParser.csiEnd(in: buf, from: sequenceStart)
                            : ANSIParser.oscEnd(
                                in: buf,
                                from: sequenceStart,
                                allowsBEL: buf[i + 1] == 0x9D
                            )
                        if let end {
                            i = end
                            continue
                        }
                        pendingEscapeStart = i
                        processedInputBytes = i
                        break
                    }
                }

                // Scan forward through non-ESC/control bytes.
                let start = i
                while i < count && buf[i] != 0x1B {
                    if buf[i] == 0xC2,
                       i + 1 < count,
                       buf[i + 1] == 0x9B || ANSIParser.isC1StringControl(buf[i + 1]) {
                        break
                    }
                    i += 1
                }
                // Only emit bytes past the boundary.
                let emitStart = max(start, emitBoundary)
                if emitStart < i {
                    for idx in emitStart..<i {
                        out.append(buf[idx])
                    }
                }
            }

            if pendingEscapeStart < 0 {
                processedInputBytes = count
            }

            guard !out.isEmpty else { return nil }
            let delta = String(decoding: out, as: UTF8.self)
            strippedUTF16Length += (delta as NSString).length
            return delta
        }
    }

    /// Strip ANSI codes from at most `maxInputBytes` of the input.
    ///
    /// O(min(n, maxInputBytes)) — safe for main-thread use on any input size.
    /// Returns the stripped prefix; the result may end mid-character if the
    /// byte boundary falls inside a multi-byte UTF-8 sequence, but
    /// `String(decoding:as:)` handles that gracefully.
    static func stripPrefix(_ input: String, maxInputBytes: Int) -> String {
        guard maxInputBytes > 0 else { return "" }
        var result: String = ""
        var mutableInput = input
        mutableInput.withUTF8 { buffer in
            let limit = min(buffer.count, maxInputBytes)
            guard limit > 0 else { return }
            // Fast path: no ANSI introducer in the prefix region.
            var hasEsc = false
            for idx in 0..<limit {
                if buffer[idx] == 0x1B
                    || (buffer[idx] == 0xC2 && idx + 1 < limit
                        && (buffer[idx + 1] == 0x9B || Self.isC1StringControl(buffer[idx + 1]))) {
                    hasEsc = true
                    break
                }
            }
            guard hasEsc else {
                result = String(decoding: buffer[..<limit], as: UTF8.self)
                return
            }
            var out = [UInt8]()
            out.reserveCapacity(limit)
            var i = 0
            while i < limit {
                if buffer[i] == 0x1B {
                    if i + 1 < limit, buffer[i + 1] == 0x5B || Self.isEscStringControl(buffer[i + 1]) {
                        let sequenceStart = i + 2
                        let end = buffer[i + 1] == 0x5B
                            ? Self.csiEnd(in: buffer, from: sequenceStart)
                            : Self.oscEnd(
                                in: buffer,
                                from: sequenceStart,
                                allowsBEL: buffer[i + 1] == 0x5D
                            )
                        i = end ?? limit
                    } else {
                        // Drop unsupported / standalone ESC byte.
                        i += 1
                    }
                    continue
                }

                if buffer[i] == 0xC2,
                   i + 1 < limit,
                   buffer[i + 1] == 0x9B || Self.isC1StringControl(buffer[i + 1]) {
                    let sequenceStart = i + 2
                    let end = buffer[i + 1] == 0x9B
                        ? Self.csiEnd(in: buffer, from: sequenceStart)
                        : Self.oscEnd(
                            in: buffer,
                            from: sequenceStart,
                            allowsBEL: buffer[i + 1] == 0x9D
                        )
                    i = end ?? limit
                    continue
                }

                let start = i
                while i < limit {
                    if buffer[i] == 0x1B {
                        break
                    }
                    if buffer[i] == 0xC2,
                       i + 1 < limit,
                       buffer[i + 1] == 0x9B || Self.isC1StringControl(buffer[i + 1]) {
                        break
                    }
                    i += 1
                }
                for idx in start..<i {
                    out.append(buffer[idx])
                }
            }
            result = String(decoding: out, as: UTF8.self)
        }
        return result
    }

    /// Strip all ANSI escape sequences, returning plain text.
    static func strip(_ input: String) -> String {
        let sanitizedInput = Self.stripStringControls(input)
        // Fast path: no ESC/OSC/CSI introducer means no ANSI codes.
        guard sanitizedInput.utf8.contains(0x1B)
            || sanitizedInput.unicodeScalars.contains(where: { scalar in
                scalar.value == 0x9B || scalar.value == 0x9D
            }) else { return sanitizedInput }

        let buf = Array(sanitizedInput.utf8)
        let count = buf.count
        var result = [UInt8]()
        result.reserveCapacity(count)

        var i = 0
        while i < count {
            if buf[i] == 0x1B {
                if i + 1 < count, buf[i + 1] == 0x5B || buf[i + 1] == 0x5D {
                    let sequenceStart = i + 2
                    let end = buf[i + 1] == 0x5B
                        ? Self.csiEnd(in: buf, from: sequenceStart)
                        : Self.oscEnd(in: buf, from: sequenceStart)
                    i = end ?? count
                } else {
                    // Drop unsupported / standalone ESC byte.
                    i += 1
                }
                continue
            }

            if buf[i] == 0xC2,
               i + 1 < count,
               buf[i + 1] == 0x9B || buf[i + 1] == 0x9D {
                let sequenceStart = i + 2
                let end = buf[i + 1] == 0x9B
                    ? Self.csiEnd(in: buf, from: sequenceStart)
                    : Self.oscEnd(in: buf, from: sequenceStart)
                i = end ?? count
                continue
            }

            // Scan forward through non-ESC/control bytes in bulk.
            let start = i
            while i < count {
                if buf[i] == 0x1B {
                    break
                }
                if buf[i] == 0xC2,
                   i + 1 < count,
                   buf[i + 1] == 0x9B || buf[i + 1] == 0x9D {
                    break
                }
                i += 1
            }
            result.append(contentsOf: buf[start..<i])
        }

        return String(decoding: result, as: UTF8.self)
    }

    // MARK: - Terminal chunk indexing

    struct TerminalChunk: Sendable, Equatable {
        let rawByteRange: Range<Int>
        let displayedUTF16Range: Range<Int>
        let leadingSGR: String
        let displayedStartLine: Int
        let lineColumnCounts: [Int]
        /// Bounded slice retained to make arbitrary tail rendering O(chunk),
        /// rather than walking a variable-width Swift String from its start.
        let rawText: String

        var rawByteCount: Int { rawByteRange.count }
    }

    struct TerminalChunkIndex: Sendable, Equatable {
        let chunks: [TerminalChunk]
        let displayedUTF16Count: Int
        let widestLineColumnCount: Int

        /// Resolve a document-level selection even when it spans several
        /// mounted chunks. Ranges use the ANSI-stripped UTF-16 coordinate space
        /// used by UITextView.
        func displayedText(inUTF16Range range: Range<Int>) -> String {
            guard !range.isEmpty else { return "" }
            var result = ""
            for chunk in chunks {
                let lower = max(range.lowerBound, chunk.displayedUTF16Range.lowerBound)
                let upper = min(range.upperBound, chunk.displayedUTF16Range.upperBound)
                guard lower < upper else { continue }
                let displayed = ANSIParser.strip(chunk.rawText) as NSString
                let local = NSRange(
                    location: lower - chunk.displayedUTF16Range.lowerBound,
                    length: upper - lower
                )
                guard NSMaxRange(local) <= displayed.length else { continue }
                result += displayed.substring(with: local)
            }
            return result
        }

        static func build(
            from source: String,
            maxLines: Int = 160,
            maxBytes: Int = 32 * 1024
        ) -> TerminalChunkIndex {
            precondition(maxLines > 0 && maxBytes > 0)
            let bytes = Array(source.utf8)
            var chunks: [TerminalChunk] = []
            chunks.reserveCapacity(max(1, bytes.count / maxBytes))
            var style = TerminalSGRCarry()
            var leadingStyle = style
            var chunkStart = 0
            var lineCount = 0
            var chunkStartLine = 1
            var displayedStart = 0
            var widest = 0
            var currentLineColumns = 0
            var index = 0

            func makeLineColumns(_ text: String) -> [Int] {
                var result: [Int] = []
                var columns = 0
                for character in text {
                    if character == "\n" {
                        result.append(columns)
                        columns = 0
                    } else if character == "\t" {
                        columns += 4
                    } else {
                        columns += 1
                    }
                }
                if !text.hasSuffix("\n") || result.isEmpty {
                    result.append(columns)
                }
                return result
            }

            func finishChunk(at end: Int) {
                guard end > chunkStart else { return }
                let raw = String(decoding: bytes[chunkStart..<end], as: UTF8.self)
                let displayed = ANSIParser.strip(raw)
                let displayedLength = (displayed as NSString).length
                let columns = makeLineColumns(displayed)
                chunks.append(TerminalChunk(
                    rawByteRange: chunkStart..<end,
                    displayedUTF16Range: displayedStart..<(displayedStart + displayedLength),
                    leadingSGR: leadingStyle.escapeSequence,
                    displayedStartLine: chunkStartLine,
                    lineColumnCounts: columns,
                    rawText: raw
                ))
                displayedStart += displayedLength
                chunkStart = end
                leadingStyle = style
                chunkStartLine += lineCount
                lineCount = 0
            }

            while index < bytes.count {
                if bytes[index] == 0x1B, index + 1 < bytes.count, bytes[index + 1] == 0x5B {
                    let sequenceStart = index + 2
                    if let end = ANSIParser.csiEnd(in: bytes, from: sequenceStart) {
                        if bytes[end - 1] == 0x6D {
                            style.apply(bytes, from: sequenceStart, to: end - 1)
                        }
                        index = end
                    } else {
                        index = bytes.count
                    }
                } else if bytes[index] == 0x1B,
                          index + 1 < bytes.count,
                          ANSIParser.isEscStringControl(bytes[index + 1]) {
                    index = ANSIParser.oscEnd(
                        in: bytes,
                        from: index + 2,
                        allowsBEL: bytes[index + 1] == 0x5D
                    ) ?? bytes.count
                } else if bytes[index] == 0xC2,
                          index + 1 < bytes.count,
                          bytes[index + 1] == 0x9B {
                    let sequenceStart = index + 2
                    if let end = ANSIParser.csiEnd(in: bytes, from: sequenceStart) {
                        if bytes[end - 1] == 0x6D {
                            style.apply(bytes, from: sequenceStart, to: end - 1)
                        }
                        index = end
                    } else {
                        index = bytes.count
                    }
                } else if bytes[index] == 0xC2,
                          index + 1 < bytes.count,
                          ANSIParser.isC1StringControl(bytes[index + 1]) {
                    index = ANSIParser.oscEnd(
                        in: bytes,
                        from: index + 2,
                        allowsBEL: bytes[index + 1] == 0x9D
                    ) ?? bytes.count
                } else {
                    if bytes[index] == 0x0A {
                        lineCount += 1
                        widest = max(widest, currentLineColumns)
                        currentLineColumns = 0
                    } else if bytes[index] == 0x09 {
                        currentLineColumns += 4
                    } else {
                        currentLineColumns += 1
                    }
                    let scalarLength: Int
                    switch bytes[index] {
                    case 0x00..<0x80: scalarLength = 1
                    case 0xC0..<0xE0: scalarLength = 2
                    case 0xE0..<0xF0: scalarLength = 3
                    default: scalarLength = 4
                    }
                    index = min(bytes.count, index + scalarLength)
                }

                if lineCount >= maxLines || index - chunkStart >= maxBytes {
                    finishChunk(at: index)
                }
            }
            finishChunk(at: bytes.count)
            widest = max(widest, currentLineColumns)

            return TerminalChunkIndex(
                chunks: chunks,
                displayedUTF16Count: displayedStart,
                widestLineColumnCount: widest
            )
        }
    }

    private struct TerminalSGRCarry {
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var foreground: [Int]?
        var background: [Int]?

        var escapeSequence: String {
            var codes: [Int] = []
            if bold { codes.append(1) }
            if dim { codes.append(2) }
            if italic { codes.append(3) }
            if underline { codes.append(4) }
            if let foreground { codes.append(contentsOf: foreground) }
            if let background { codes.append(contentsOf: background) }
            guard !codes.isEmpty else { return "" }
            return "\u{1B}[" + codes.map(String.init).joined(separator: ";") + "m"
        }

        mutating func apply(_ bytes: [UInt8], from start: Int, to end: Int) {
            let parameterText = String(decoding: bytes[start..<end], as: UTF8.self)
            let parameters = parameterText.isEmpty
                ? [0]
                : parameterText.split(separator: ";", omittingEmptySubsequences: false).map {
                    Int($0) ?? 0
                }
            var index = 0
            while index < parameters.count {
                let code = parameters[index]
                switch code {
                case 0:
                    self = TerminalSGRCarry()
                case 1: bold = true
                case 2: dim = true
                case 3: italic = true
                case 4: underline = true
                case 22: bold = false; dim = false
                case 23: italic = false
                case 24: underline = false
                case 30...37, 90...97:
                    foreground = [code]
                case 39:
                    foreground = nil
                case 40...47, 100...107:
                    background = [code]
                case 49:
                    background = nil
                case 38, 48:
                    let targetIsForeground = code == 38
                    if index + 2 < parameters.count, parameters[index + 1] == 5 {
                        let value = [code, 5, parameters[index + 2]]
                        if targetIsForeground { foreground = value } else { background = value }
                        index += 2
                    } else if index + 4 < parameters.count, parameters[index + 1] == 2 {
                        let value = [code, 2, parameters[index + 2], parameters[index + 3], parameters[index + 4]]
                        if targetIsForeground { foreground = value } else { background = value }
                        index += 4
                    }
                default:
                    break
                }
                index += 1
            }
        }
    }

}
