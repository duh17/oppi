import Foundation

/// One undoable change to an editor buffer.
///
/// `range` is UTF-16 in the text before the change; `selection` is UTF-16 in
/// the text after it. The editor applies `replacement` as a single replace so
/// the whole command is one undo step.
struct CodeTextEdit: Equatable, Sendable {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

/// How one indent level is typed.
struct CodeIndentation: Equatable, Sendable {
    var usesTabs: Bool
    /// Columns per level. Tabs still use it to find tab stops for spaces.
    var width: Int

    var unit: String { usesTabs ? "\t" : String(repeating: " ", count: width) }

    static let standard = CodeIndentation(usesTabs: false, width: 4)

    /// The file's own style from its indented lines. Tab-led lines outnumbering
    /// space-led lines means tabs. Otherwise the most common step between
    /// neighboring space indents (2, 4, or 8) is the width. A file with no
    /// indented lines keeps `fallback`.
    static func detect(in text: NSString, fallback: CodeIndentation) -> CodeIndentation {
        var tabLines = 0
        var spaceLines = 0
        var steps: [Int: Int] = [:]
        var previousSpaces = 0
        var lineStart = 0
        var scanned = 0
        let length = text.length
        while lineStart < length, scanned < 4_000 {
            var next = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &next, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            scanned += 1
            var index = lineStart
            var spaces = 0
            var sawTab = false
            while index < contentsEnd {
                let unit = text.character(at: index)
                if unit == CodeText.space {
                    spaces += 1
                } else if unit == CodeText.tab {
                    sawTab = true
                } else {
                    break
                }
                index += 1
            }
            let blank = index == contentsEnd
            if !blank {
                if text.length > lineStart, text.character(at: lineStart) == CodeText.tab {
                    tabLines += 1
                } else if spaces > 0, !sawTab {
                    spaceLines += 1
                }
                if !sawTab {
                    let step = abs(spaces - previousSpaces)
                    if step >= 2 { steps[step, default: 0] += 1 }
                    previousSpaces = spaces
                }
            }
            if next <= lineStart { break }
            lineStart = next
        }
        if tabLines == 0, spaceLines == 0 { return fallback }
        if tabLines > spaceLines {
            return CodeIndentation(usesTabs: true, width: fallback.width)
        }
        let width = [2, 4, 8].max { (steps[$0] ?? 0) < (steps[$1] ?? 0) } ?? fallback.width
        return CodeIndentation(usesTabs: false, width: (steps[width] ?? 0) > 0 ? width : fallback.width)
    }
}

/// UTF-16 code units the editor commands look for.
enum CodeText {
    static let newline: unichar = 0x0A
    static let carriageReturn: unichar = 0x0D
    static let space: unichar = 0x20
    static let tab: unichar = 0x09

    static func isLineBreak(_ unit: unichar) -> Bool {
        unit == newline || unit == carriageReturn || unit == 0x2029
    }

    static func isBlank(_ unit: unichar) -> Bool {
        unit == space || unit == tab
    }
}

/// Start offsets of every logical line, for line numbers and Ln/Col.
///
/// Breaks on LF, CR, CRLF (one break), and U+2029, the same paragraphs the
/// text view lays out. A trailing break starts one more, empty line.
struct CodeLineIndex: Equatable, Sendable {
    private(set) var starts: [Int]

    init(_ text: NSString) {
        var starts = [0]
        let length = text.length
        let chunk = 4_096
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var location = 0
        var pendingCR = false
        while location < length {
            let count = min(chunk, length - location)
            text.getCharacters(buffer, range: NSRange(location: location, length: count))
            for index in 0..<count {
                let unit = buffer[index]
                if pendingCR {
                    pendingCR = false
                    if unit == CodeText.newline {
                        starts[starts.count - 1] = location + index + 1
                        continue
                    }
                }
                if unit == CodeText.newline || unit == 0x2029 {
                    starts.append(location + index + 1)
                } else if unit == CodeText.carriageReturn {
                    starts.append(location + index + 1)
                    pendingCR = true
                }
            }
            location += count
        }
        self.starts = starts
    }

    var lineCount: Int { starts.count }

    /// Update after `text` changed in `editedRange` (new coordinates) by
    /// `changeInLength`, as `NSTextStorage` reports it. Rescans only the
    /// edited lines plus one unit on each side, so a CR and LF meeting at the
    /// edge still count as one break; later starts shift by the change. A full
    /// rescan of a 1 MiB buffer is tens of milliseconds, this is microseconds.
    mutating func apply(editedRange: NSRange, changeInLength delta: Int, in text: NSString) {
        let length = text.length
        let windowStart = max(0, editedRange.location - 1)
        let newWindowEnd = min(length, NSMaxRange(editedRange) + 1)
        let oldWindowEnd = min(length - delta, NSMaxRange(editedRange) - delta + 1)

        // Starts in (windowStart, oldWindowEnd] came from breaks in the window.
        let first = firstIndex(greaterThan: windowStart)
        let afterRemoved = firstIndex(greaterThan: oldWindowEnd)
        var rescanned: [Int] = []
        var index = windowStart
        while index < newWindowEnd {
            let unit = text.character(at: index)
            if unit == CodeText.newline || unit == 0x2029 {
                rescanned.append(index + 1)
            } else if unit == CodeText.carriageReturn {
                let followedByLF = index + 1 < length && text.character(at: index + 1) == CodeText.newline
                if !followedByLF { rescanned.append(index + 1) }
            }
            index += 1
        }
        // Starts past the old window shift past the new one; the unchanged
        // characters at both window edges keep a CR+LF pair split across the
        // edge counted once.
        starts = Array(starts[..<first]) + rescanned + starts[afterRemoved...].map { $0 + delta }
    }

    private func firstIndex(greaterThan offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Zero-based line containing `offset`.
    func line(containing offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
}

/// Pure editing commands for the code editor. Every command reads the buffer
/// and returns one `CodeTextEdit`; nil means the command does nothing here.
enum CodeTextEditing {

    // MARK: - Lines

    /// Whole lines touched by `selection`, including the last line's break.
    /// A non-empty selection that ends at a line start leaves that line out.
    static func lineBlock(_ text: NSString, selection: NSRange) -> NSRange {
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, end <= text.length,
           end > 0, CodeText.isLineBreak(text.character(at: end - 1)) {
            end -= 1
        }
        let first = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let last = text.lineRange(for: NSRange(location: min(end, text.length), length: 0))
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    /// Ranges of each line's contents (no break) inside `block`.
    static func lineContents(_ text: NSString, in block: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = block.location
        let end = NSMaxRange(block)
        repeat {
            var next = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &next, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            ranges.append(NSRange(location: location, length: contentsEnd - location))
            if next <= location { break }
            location = next
        } while location < end
        return ranges
    }

    static func leadingWhitespace(_ text: NSString, line: NSRange) -> NSRange {
        var index = line.location
        while index < NSMaxRange(line), CodeText.isBlank(text.character(at: index)) { index += 1 }
        return NSRange(location: line.location, length: index - line.location)
    }

    /// Line break used when a command adds a line: CRLF when the caret's line
    /// or the one before it uses CRLF, else LF.
    static func lineBreak(_ text: NSString, near offset: Int) -> String {
        let line = text.lineRange(for: NSRange(location: min(offset, text.length), length: 0))
        let end = NSMaxRange(line)
        if end >= 2, text.character(at: end - 2) == CodeText.carriageReturn, text.character(at: end - 1) == CodeText.newline {
            return "\r\n"
        }
        if line.location >= 2, text.character(at: line.location - 2) == CodeText.carriageReturn {
            return "\r\n"
        }
        return "\n"
    }

    // MARK: - Indent

    /// Prefix `levels` levels on every non-empty line of the selection's block.
    static func indent(_ text: NSString, selection: NSRange, indentation: CodeIndentation, levels: Int = 1) -> CodeTextEdit {
        let block = lineBlock(text, selection: selection)
        let unit = String(repeating: indentation.unit, count: max(1, levels))
        return transformLines(text, block: block, selection: selection) { _, contents in
            contents.isEmpty ? (contents, 0) : (unit + contents, 0)
        }
    }

    /// Remove up to `levels` levels from every line of the selection's block.
    static func outdent(_ text: NSString, selection: NSRange, indentation: CodeIndentation, levels: Int = 1) -> CodeTextEdit? {
        let block = lineBlock(text, selection: selection)
        let edit = transformLines(text, block: block, selection: selection) { _, contents in
            let units = Array(contents.utf16)
            var removed = 0
            // One level is a tab or up to `width` spaces; stop once a line has none left.
            for _ in 0..<max(1, levels) {
                if removed < units.count, units[removed] == CodeText.tab {
                    removed += 1
                    continue
                }
                var spaces = 0
                while spaces < indentation.width, removed + spaces < units.count, units[removed + spaces] == CodeText.space { spaces += 1 }
                if spaces == 0 { break }
                removed += spaces
            }
            return (String(utf16CodeUnits: Array(units.dropFirst(removed)), count: units.count - removed), 0)
        }
        return edit.replacement == text.substring(with: edit.range) ? nil : edit
    }

    /// Tab key: indent a multi-line selection, else replace the selection with
    /// one tab or spaces to the next tab stop.
    static func insertTab(_ text: NSString, selection: NSRange, indentation: CodeIndentation) -> CodeTextEdit {
        if selection.length > 0, text.substring(with: selection).contains(where: \.isNewline) {
            return indent(text, selection: selection, indentation: indentation)
        }
        let replacement: String
        if indentation.usesTabs {
            replacement = "\t"
        } else {
            let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let column = selection.location - line.location
            let count = indentation.width - column % max(1, indentation.width)
            replacement = String(repeating: " ", count: count)
        }
        let caret = selection.location + (replacement as NSString).length
        return CodeTextEdit(range: selection, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// Backspace in leading spaces deletes back to the previous tab stop.
    static func softTabDeletion(_ text: NSString, caret: Int, indentation: CodeIndentation) -> CodeTextEdit? {
        guard !indentation.usesTabs, indentation.width > 1, caret > 0 else { return nil }
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let column = caret - line.location
        guard column > 0 else { return nil }
        for index in line.location..<caret where text.character(at: index) != CodeText.space { return nil }
        let remove = column % indentation.width == 0 ? indentation.width : column % indentation.width
        guard remove > 1 else { return nil }
        let range = NSRange(location: caret - remove, length: remove)
        return CodeTextEdit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0))
    }

    // MARK: - Return

    /// Return keeps the line's indentation. After an opening bracket (or a
    /// colon in Python/YAML) it adds a level; between a bracket pair it also
    /// moves the closer to its own line.
    static func newline(
        _ text: NSString,
        selection: NSRange,
        indentation: CodeIndentation,
        colonOpensBlock: Bool
    ) -> CodeTextEdit {
        let caret = selection.location
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let leading = leadingWhitespace(text, line: NSRange(location: line.location, length: max(0, caret - line.location)))
        let indent = text.substring(with: leading)
        let breakText = lineBreak(text, near: caret)

        var before: unichar?
        var index = caret - 1
        while index >= line.location {
            let unit = text.character(at: index)
            if !CodeText.isBlank(unit) {
                before = unit
                break
            }
            index -= 1
        }
        let afterIndex = NSMaxRange(selection)
        let after: unichar? = afterIndex < text.length ? text.character(at: afterIndex) : nil

        let opens = before.map { pairs[$0] != nil && !isQuote($0) } ?? false
            || (colonOpensBlock && before == UInt16(UInt8(ascii: ":")))
        if opens, let before, let after, let closer = pairs[before], closer == after {
            let first = breakText + indent + indentation.unit
            let replacement = first + breakText + indent
            let caretAfter = caret + (first as NSString).length
            return CodeTextEdit(range: selection, replacement: replacement, selection: NSRange(location: caretAfter, length: 0))
        }
        let replacement = breakText + indent + (opens ? indentation.unit : "")
        return CodeTextEdit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: caret + (replacement as NSString).length, length: 0)
        )
    }

    // MARK: - Pairs

    static let pairs: [unichar: unichar] = [
        0x28: 0x29, // ( )
        0x5B: 0x5D, // [ ]
        0x7B: 0x7D, // { }
        0x22: 0x22, // " "
        0x27: 0x27, // ' '
        0x60: 0x60, // ` `
    ]

    private static let closers: Set<unichar> = [0x29, 0x5D, 0x7D]

    static func isQuote(_ unit: unichar) -> Bool {
        unit == 0x22 || unit == 0x27 || unit == 0x60
    }

    /// Typing an opener closes it, wraps a selection, or steps over the
    /// closer already under the caret. Quotes pair only when `pairsQuotes`
    /// and never right after a word character (so `don't` stays one quote).
    static func pairedInsertion(
        _ text: NSString,
        selection: NSRange,
        typed: String,
        pairsQuotes: Bool
    ) -> CodeTextEdit? {
        let units = Array(typed.utf16)
        guard units.count == 1 else { return nil }
        let unit = units[0]
        let quote = isQuote(unit)
        if quote, !pairsQuotes { return nil }
        let after: unichar? = NSMaxRange(selection) < text.length ? text.character(at: NSMaxRange(selection)) : nil

        // Step over the closer we would otherwise type twice.
        if selection.length == 0, after == unit, closers.contains(unit) || quote {
            return CodeTextEdit(
                range: selection,
                replacement: "",
                selection: NSRange(location: selection.location + 1, length: 0)
            )
        }
        guard let closer = pairs[unit] else { return nil }
        let open = typed
        let close = String(utf16CodeUnits: [closer], count: 1)
        if selection.length > 0 {
            let inner = text.substring(with: selection)
            return CodeTextEdit(
                range: selection,
                replacement: open + inner + close,
                selection: NSRange(location: selection.location + 1, length: selection.length)
            )
        }
        if quote, selection.location > 0 {
            let before = text.character(at: selection.location - 1)
            if isWordUnit(before) || before == unit { return nil }
        }
        if let after, !(CodeText.isBlank(after) || CodeText.isLineBreak(after) || closers.contains(after)
            || after == 0x2C || after == 0x3B || after == 0x3A) {
            return nil
        }
        return CodeTextEdit(
            range: selection,
            replacement: open + close,
            selection: NSRange(location: selection.location + 1, length: 0)
        )
    }

    /// Backspace between an empty pair deletes both halves.
    static func pairDeletion(_ text: NSString, caret: Int) -> CodeTextEdit? {
        guard caret > 0, caret < text.length else { return nil }
        let before = text.character(at: caret - 1)
        guard let closer = pairs[before], text.character(at: caret) == closer else { return nil }
        return CodeTextEdit(
            range: NSRange(location: caret - 1, length: 2),
            replacement: "",
            selection: NSRange(location: caret - 1, length: 0)
        )
    }

    static func isWordUnit(_ unit: unichar) -> Bool {
        if unit == 0x5F { return true }
        if unit < 0x80 {
            return (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
        }
        if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: - Comments

    /// Toggle a line comment on the selection's block. Every non-blank line
    /// already commented means remove; otherwise add `prefix ` at the block's
    /// shallowest indentation.
    static func toggleLineComment(_ text: NSString, selection: NSRange, prefix: String) -> CodeTextEdit? {
        let block = lineBlock(text, selection: selection)
        let lines = lineContents(text, in: block)
        let nonBlank = lines.filter { leadingWhitespace(text, line: $0).length < $0.length }
        guard !nonBlank.isEmpty else { return nil }
        let allCommented = nonBlank.allSatisfy { line in
            let lead = leadingWhitespace(text, line: line)
            return text.substring(with: NSRange(location: NSMaxRange(lead), length: NSMaxRange(line) - NSMaxRange(lead)))
                .hasPrefix(prefix)
        }
        let column = nonBlank.map { leadingWhitespace(text, line: $0).length }.min() ?? 0
        let prefixLength = (prefix as NSString).length
        return transformLines(text, block: block, selection: selection) { _, contents in
            let ns = contents as NSString
            let lead = leadingWhitespace(ns, line: NSRange(location: 0, length: ns.length))
            if lead.length == ns.length { return (contents, 0) }
            if allCommented {
                var cut = prefixLength
                if NSMaxRange(lead) + cut < ns.length, ns.character(at: NSMaxRange(lead) + cut) == CodeText.space { cut += 1 }
                return (ns.replacingCharacters(in: NSRange(location: NSMaxRange(lead), length: cut), with: ""), lead.length)
            }
            return (ns.replacingCharacters(in: NSRange(location: column, length: 0), with: prefix + " "), column)
        }
    }

    /// Toggle `<!-- -->` around the selection's block (Markdown, HTML, XML).
    static func toggleBlockComment(_ text: NSString, selection: NSRange, open: String, close: String) -> CodeTextEdit? {
        let block = lineBlock(text, selection: selection)
        var contentsEnd = NSMaxRange(block)
        while contentsEnd > block.location, CodeText.isLineBreak(text.character(at: contentsEnd - 1)) { contentsEnd -= 1 }
        let body = NSRange(location: block.location, length: contentsEnd - block.location)
        let source = text.substring(with: body)
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        let replacement: String
        if trimmed.hasPrefix(open), trimmed.hasSuffix(close), trimmed.count >= open.count + close.count {
            var inner = String(trimmed.dropFirst(open.count).dropLast(close.count))
            if inner.hasPrefix(" ") { inner.removeFirst() }
            if inner.hasSuffix(" ") { inner.removeLast() }
            let lead = text.substring(with: leadingWhitespace(text, line: body))
            replacement = lead + inner
        } else {
            let lead = leadingWhitespace(text, line: body)
            replacement = text.substring(with: lead) + open + " "
                + text.substring(with: NSRange(location: NSMaxRange(lead), length: NSMaxRange(body) - NSMaxRange(lead)))
                + " " + close
        }
        let length = (replacement as NSString).length
        return CodeTextEdit(range: body, replacement: replacement, selection: NSRange(location: body.location, length: length))
    }

    // MARK: - Line moves

    /// Swap the selection's block with the line above or below it.
    static func moveLines(_ text: NSString, selection: NSRange, up: Bool) -> CodeTextEdit? {
        let block = lineBlock(text, selection: selection)
        if up {
            guard block.location > 0 else { return nil }
            let previous = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
            var blockText = text.substring(with: block)
            var previousText = text.substring(with: previous)
            if NSMaxRange(block) == text.length, !(blockText.last?.isNewline ?? false) {
                // The block is the unterminated last line: it borrows the break.
                let breakText = trailingBreak(previousText)
                previousText.removeLast(breakText.count)
                blockText += breakText
            }
            // The block's own offsets are unchanged; it now starts where the
            // previous line did.
            return CodeTextEdit(
                range: NSRange(location: previous.location, length: NSMaxRange(block) - previous.location),
                replacement: blockText + previousText,
                selection: NSRange(location: selection.location - previous.length, length: selection.length)
            )
        } else {
            guard NSMaxRange(block) < text.length else { return nil }
            let next = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            var blockText = text.substring(with: block)
            var nextText = text.substring(with: next)
            if NSMaxRange(next) == text.length, !(nextText.last?.isNewline ?? false) {
                let breakText = trailingBreak(blockText)
                blockText.removeLast(breakText.count)
                nextText += breakText
            }
            let replacement = nextText + blockText
            let newBlockStart = block.location + (nextText as NSString).length
            return CodeTextEdit(
                range: NSRange(location: block.location, length: NSMaxRange(next) - block.location),
                replacement: replacement,
                selection: NSRange(location: selection.location - block.location + newBlockStart, length: selection.length)
            )
        }
    }

    private static func trailingBreak(_ line: String) -> String {
        if line.hasSuffix("\r\n") { return "\r\n" }
        if let last = line.last, last.isNewline { return String(last) }
        return ""
    }

    private static func trailingBreakLength(_ line: String) -> Int {
        (trailingBreak(line) as NSString).length
    }

    /// Copy the selection's block below itself and select the copy.
    static func duplicateLines(_ text: NSString, selection: NSRange) -> CodeTextEdit {
        let block = lineBlock(text, selection: selection)
        let blockText = text.substring(with: block)
        if trailingBreak(blockText).isEmpty {
            let breakText = lineBreak(text, near: block.location)
            let insertion = breakText + blockText
            let offset = (breakText as NSString).length + block.length
            return CodeTextEdit(
                range: NSRange(location: NSMaxRange(block), length: 0),
                replacement: insertion,
                selection: NSRange(location: selection.location + offset, length: selection.length)
            )
        }
        return CodeTextEdit(
            range: NSRange(location: NSMaxRange(block), length: 0),
            replacement: blockText,
            selection: NSRange(location: selection.location + block.length, length: selection.length)
        )
    }

    /// Delete the selection's block; the caret lands where the next line starts.
    static func deleteLines(_ text: NSString, selection: NSRange) -> CodeTextEdit {
        var block = lineBlock(text, selection: selection)
        if NSMaxRange(block) == text.length, block.location > 0,
           trailingBreak(text.substring(with: block)).isEmpty {
            // Last line without a break: take the break before it instead.
            let previousBreak = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let breakLength = trailingBreakLength(text.substring(with: previousBreak))
            block = NSRange(location: block.location - breakLength, length: block.length + breakLength)
            // The caret goes to the start of what becomes the last line.
            let remaining = text.substring(to: block.location) as NSString
            let caret = remaining.lineRange(for: NSRange(location: remaining.length, length: 0)).location
            return CodeTextEdit(range: block, replacement: "", selection: NSRange(location: caret, length: 0))
        }
        return CodeTextEdit(range: block, replacement: "", selection: NSRange(location: block.location, length: 0))
    }

    /// Open a new line below (or above) the caret's line at its indentation.
    static func insertLine(_ text: NSString, selection: NSRange, below: Bool) -> CodeTextEdit {
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        let indent = text.substring(with: leadingWhitespace(text, line: NSRange(location: line.location, length: contentsEnd - line.location)))
        let breakText = lineBreak(text, near: selection.location)
        if below {
            let replacement = breakText + indent
            return CodeTextEdit(
                range: NSRange(location: contentsEnd, length: 0),
                replacement: replacement,
                selection: NSRange(location: contentsEnd + (replacement as NSString).length, length: 0)
            )
        }
        return CodeTextEdit(
            range: NSRange(location: line.location, length: 0),
            replacement: indent + breakText,
            selection: NSRange(location: line.location + (indent as NSString).length, length: 0)
        )
    }

    // MARK: - Markdown

    /// Wrap the selection in `marker` (Bold `**`, Italic `_`), or unwrap it
    /// when the marker already surrounds it. An empty selection inserts the
    /// pair with the caret inside.
    static func toggleWrap(_ text: NSString, selection: NSRange, marker: String) -> CodeTextEdit {
        let length = (marker as NSString).length
        let before = selection.location - length
        let after = NSMaxRange(selection)
        if before >= 0, after + length <= text.length,
           text.substring(with: NSRange(location: before, length: length)) == marker,
           text.substring(with: NSRange(location: after, length: length)) == marker {
            let inner = text.substring(with: selection)
            return CodeTextEdit(
                range: NSRange(location: before, length: selection.length + 2 * length),
                replacement: inner,
                selection: NSRange(location: before, length: selection.length)
            )
        }
        let inner = text.substring(with: selection)
        return CodeTextEdit(
            range: selection,
            replacement: marker + inner + marker,
            selection: NSRange(location: selection.location + length, length: selection.length)
        )
    }

    // MARK: - Helpers

    /// Rewrite each line of `block` and map the selection through it.
    /// `transform` returns the new contents and the column at or after which
    /// an offset in that line shifts (offsets before it stay put).
    private static func transformLines(
        _ text: NSString,
        block: NSRange,
        selection: NSRange,
        transform: (NSRange, String) -> (String, Int)
    ) -> CodeTextEdit {
        var output = ""
        var cursor = block.location
        var deltas: [(start: Int, pivot: Int, oldLength: Int, newLength: Int)] = []
        for line in lineContents(text, in: block) {
            if line.location > cursor {
                output += text.substring(with: NSRange(location: cursor, length: line.location - cursor))
            }
            let contents = text.substring(with: line)
            let (replaced, pivot) = transform(line, contents)
            output += replaced
            deltas.append((line.location, pivot, line.length, (replaced as NSString).length))
            cursor = NSMaxRange(line)
        }
        if NSMaxRange(block) > cursor {
            output += text.substring(with: NSRange(location: cursor, length: NSMaxRange(block) - cursor))
        }

        /// A selection that starts at a line start keeps starting there, so
        /// whole selected lines stay whole.
        func map(_ offset: Int, keepsLineStart: Bool = false) -> Int {
            var shift = 0
            for delta in deltas {
                let lineEnd = delta.start + delta.oldLength
                if offset > lineEnd {
                    shift += delta.newLength - delta.oldLength
                } else if offset >= delta.start {
                    let column = offset - delta.start
                    if keepsLineStart, column == 0 { return delta.start + shift }
                    let change = delta.newLength - delta.oldLength
                    if change >= 0 {
                        return offset + shift + (column >= delta.pivot ? change : 0)
                    }
                    // Removed text sits right after `pivot`; offsets inside it collapse there.
                    let mapped = column <= delta.pivot ? column : max(delta.pivot, column + change)
                    return delta.start + shift + mapped
                }
            }
            return offset + shift
        }

        let start = map(selection.location, keepsLineStart: selection.length > 0)
        let end = map(NSMaxRange(selection))
        return CodeTextEdit(
            range: block,
            replacement: output,
            selection: NSRange(location: start, length: max(0, end - start))
        )
    }
}
