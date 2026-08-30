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

}
