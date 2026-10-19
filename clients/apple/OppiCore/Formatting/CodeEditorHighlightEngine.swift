import Foundation
import SwiftTreeSitter
import TreeSitter

/// How one stretch of editor text is painted.
enum CodeEditorSpanStyle: Equatable, Sendable {
    case token(SyntaxTokenKind)
    // Markdown source
    case heading
    case strong
    case emphasis
    case strikethrough
    case inlineCode
    case link
    case url
    case quote
    /// Markdown syntax characters: `#`, `**`, list bullets, fences, brackets.
    case marker
}

/// A painted range. Offsets are UTF-16, matching `NSRange` and the text view.
struct CodeEditorSpan: Equatable, Sendable {
    let location: Int
    let length: Int
    let style: CodeEditorSpanStyle

    var range: NSRange { NSRange(location: location, length: length) }
}

/// Syntax spans for the code editor's live buffer.
///
/// Tree-sitter languages keep one parse tree per document. Each call diffs the
/// new text against the last parsed text (one common prefix/suffix edit), lets
/// tree-sitter reparse incrementally, then runs the highlights query only over
/// `window`, the rows around the viewport. Typing in a 1 MiB file reparses in
/// about a millisecond instead of rebuilding the whole tree. Languages without
/// a grammar use the line scanner on the window; Markdown uses
/// `MarkdownSourceHighlighter`.
///
/// The actor owns the parser and tree, so parsing stays off the main thread.
actor CodeEditorHighlightEngine {
    enum Grammar: Equatable, Sendable {
        case treeSitter(SyntaxLanguage)
        case scanner(SyntaxLanguage)
        case markdown
        case plain
    }

    nonisolated let grammar: Grammar

    private var parser: Parser?
    private var tree: MutableTree?
    private var query: Query?
    private var parsedText: NSString = ""
    private var parsedLines = CodeLineIndex("")

    init(grammar: Grammar) {
        self.grammar = grammar
    }

    /// Editor grammar for a file. Formats with no syntax (CSV, plain text)
    /// paint plain.
    static func grammar(forPath path: String) -> Grammar {
        let language: SyntaxLanguage
        switch FileType.detect(from: path) {
        case .markdown: return .markdown
        case .code(let detected): language = detected
        case .json, .geojson, .topojson: language = .json
        case .html: language = .html
        case .latex: language = .latex
        case .orgMode: language = .orgMode
        case .mermaid: language = .mermaid
        case .graphviz: language = .dot
        case .csv, .tsv, .plain, .image, .audio, .video, .pdf, .usdz, .binary: return .plain
        }
        if language == .unknown { return .plain }
        return TreeSitterHighlighter.supports(language) ? .treeSitter(language) : .scanner(language)
    }

    /// Bring the parse up to date with `text` and return the spans that
    /// overlap `window`, sorted by location. Later spans win when they overlap.
    func spans(text: String, window: NSRange) -> [CodeEditorSpan] {
        let source = text as NSString
        let window = NSIntersectionRange(window, NSRange(location: 0, length: source.length))
        switch grammar {
        case .plain:
            return []
        case .markdown:
            return MarkdownSourceHighlighter.spans(in: source, window: window)
        case .scanner(let language):
            return Self.scannerSpans(source, window: window, language: language)
        case .treeSitter(let language):
            guard let tree = reparse(source, language: language), let query else { return [] }
            return TreeSitterHighlighter.scanWithQuery(query: query, tree: tree, source: source, range: window)
                .map { CodeEditorSpan(location: $0.location, length: $0.length, style: .token($0.kind)) }
        }
    }

    // MARK: - Tree-sitter

    private func reparse(_ source: NSString, language: SyntaxLanguage) -> MutableTree? {
        if parser == nil {
            guard let tsLanguage = TreeSitterHighlighter.GrammarRegistry.shared.language(for: language),
                  let compiled = TreeSitterHighlighter.GrammarRegistry.shared.highlightsQuery(for: language) else {
                return nil
            }
            let parser = Parser()
            guard (try? parser.setLanguage(tsLanguage)) != nil else { return nil }
            self.parser = parser
            query = compiled
        }
        guard let parser else { return nil }

        if let tree {
            guard let edit = Self.edit(from: parsedText, to: source, oldLines: parsedLines) else { return tree }
            tree.edit(edit.input)
            let lines = edit.newLines
            guard let next = parser.parse(tree: tree, readBlock: Self.reader(source)) else { return nil }
            self.tree = next
            parsedLines = lines
        } else {
            tree = parser.parse(tree: nil as MutableTree?, readBlock: Self.reader(source))
            parsedLines = CodeLineIndex(source)
        }
        parsedText = source
        return tree
    }

    /// UTF-16LE chunks straight from the string, no whole-buffer copy.
    private static func reader(_ source: NSString) -> Parser.ReadBlock {
        let length = source.length
        return { byteOffset, _ in
            let start = byteOffset / 2
            guard start < length else { return nil }
            let count = min(4_096, length - start)
            var data = Data(count: count * 2)
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: unichar.self) else { return }
                source.getCharacters(base, range: NSRange(location: start, length: count))
            }
            return data
        }
    }

    struct Edit {
        let input: InputEdit
        let newLines: CodeLineIndex
        /// UTF-16 offsets for tests.
        let start: Int
        let oldEnd: Int
        let newEnd: Int
    }

    /// One edit that turns `old` into `new`: the span between their common
    /// prefix and common suffix. Nil when the texts are equal.
    static func edit(from old: NSString, to new: NSString, oldLines: CodeLineIndex) -> Edit? {
        let oldLength = old.length
        let newLength = new.length
        let limit = min(oldLength, newLength)
        let prefix = commonLength(old, new, limit: limit, forward: true)
        if prefix == oldLength, prefix == newLength { return nil }
        let suffix = commonLength(old, new, limit: limit - prefix, forward: false)
        let start = prefix
        let oldEnd = oldLength - suffix
        let newEnd = newLength - suffix
        var newLines = oldLines
        newLines.apply(editedRange: NSRange(location: start, length: newEnd - start), changeInLength: newEnd - oldEnd, in: new)

        func point(_ offset: Int, _ lines: CodeLineIndex) -> Point {
            let row = lines.line(containing: offset)
            return Point(row: row, column: (offset - lines.starts[row]) * 2)
        }
        let input = InputEdit(
            startByte: start * 2,
            oldEndByte: oldEnd * 2,
            newEndByte: newEnd * 2,
            startPoint: point(start, oldLines),
            oldEndPoint: point(oldEnd, oldLines),
            newEndPoint: point(newEnd, newLines)
        )
        return Edit(input: input, newLines: newLines, start: start, oldEnd: oldEnd, newEnd: newEnd)
    }

    /// Matching UTF-16 units from the front (or back), at most `limit`.
    private static func commonLength(_ a: NSString, _ b: NSString, limit: Int, forward: Bool) -> Int {
        guard limit > 0 else { return 0 }
        let chunk = 2_048
        let left = UnsafeMutablePointer<unichar>.allocate(capacity: chunk)
        let right = UnsafeMutablePointer<unichar>.allocate(capacity: chunk)
        defer {
            left.deallocate()
            right.deallocate()
        }
        var matched = 0
        while matched < limit {
            let count = min(chunk, limit - matched)
            let aStart = forward ? matched : a.length - matched - count
            let bStart = forward ? matched : b.length - matched - count
            a.getCharacters(left, range: NSRange(location: aStart, length: count))
            b.getCharacters(right, range: NSRange(location: bStart, length: count))
            if memcmp(left, right, count * 2) == 0 {
                matched += count
                continue
            }
            if forward {
                var index = 0
                while index < count, left[index] == right[index] { index += 1 }
                return matched + index
            }
            var index = 0
            while index < count, left[count - 1 - index] == right[count - 1 - index] { index += 1 }
            return matched + index
        }
        return matched
    }

    // MARK: - Scanner

    private static func scannerSpans(_ source: NSString, window: NSRange, language: SyntaxLanguage) -> [CodeEditorSpan] {
        guard window.length > 0 else { return [] }
        let lines = source.lineRange(for: window)
        let snippet = source.substring(with: lines)
        return SyntaxTokenScanner.scanTokenRanges(snippet, language: language).compactMap { token in
            guard token.kind != .variable else { return nil }
            return CodeEditorSpan(location: lines.location + token.location, length: token.length, style: .token(token.kind))
        }
    }
}

// MARK: - Markdown

/// Source-mode Markdown styling: headings, emphasis, code, links, quotes,
/// lists, and fenced code painted with the fence language's highlighter.
/// Syntax characters stay visible and are dimmed as `.marker`.
enum MarkdownSourceHighlighter {
    private static let heading = try? NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+|$)"#)
    private static let listMarker = try? NSRegularExpression(
        pattern: #"^[ \t]*(?:[-*+]|[0-9]{1,9}[.)])[ \t]+(\[[ xX]\](?:[ \t]+|$))?"#
    )
    private static let quote = try? NSRegularExpression(pattern: #"^ {0,3}(?:>[ \t]?)+"#)
    private static let rule = try? NSRegularExpression(pattern: #"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let fence = try? NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})[ \t]*([^`\s]*)"#)
    private static let codeSpan = try? NSRegularExpression(pattern: #"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let strong = try? NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let emphasis = try? NSRegularExpression(
        pattern: #"(?<![\*\w])(\*|_)(?=[^\s\*_])(.+?)(?<=[^\s\*_])\1(?![\*\w])"#
    )
    private static let strike = try? NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)~~"#)
    private static let link = try? NSRegularExpression(pattern: #"(!?\[)([^\]\n]*)(\]\()([^)\s]*)(?:\s+"[^"]*")?(\))"#)
    private static let wikiLink = try? NSRegularExpression(pattern: #"(!?\[\[)([^\]\n]+)(\]\])"#)
    private static let autolink = try? NSRegularExpression(pattern: #"<(?:https?|mailto):[^>\s]+>|https?://[^\s<>()]+"#)
    private static let htmlComment = try? NSRegularExpression(pattern: #"<!--.*?-->"#)

    static func spans(in text: NSString, window: NSRange) -> [CodeEditorSpan] {
        var spans: [CodeEditorSpan] = []
        let windowEnd = NSMaxRange(window)
        var location = 0
        var fenceMarker: String?
        var fenceLanguage: SyntaxLanguage = .unknown
        var fenceBodyStart = 0
        var frontMatter = false
        var lineNumber = 0

        func flushFence(until end: Int) {
            guard fenceLanguage != .unknown else { return }
            let start = max(fenceBodyStart, text.lineRange(for: NSRange(location: window.location, length: 0)).location)
            guard end > start else { return }
            let body = text.substring(with: NSRange(location: start, length: end - start))
            for token in TreeSitterHighlighter.resolvedTokenRanges(body, language: fenceLanguage) where token.kind != .variable {
                spans.append(CodeEditorSpan(location: start + token.location, length: token.length, style: .token(token.kind)))
            }
        }

        while location < text.length || (location == 0 && text.length == 0) {
            var next = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &next, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let line = NSRange(location: location, length: contentsEnd - location)
            let visible = NSMaxRange(line) >= window.location && line.location <= windowEnd
            let lineText = text.substring(with: line)
            let lineNS = lineText as NSString
            let whole = NSRange(location: 0, length: lineNS.length)

            if lineNumber == 0, lineText == "---" {
                frontMatter = true
                if visible { spans.append(CodeEditorSpan(location: line.location, length: line.length, style: .marker)) }
            } else if frontMatter {
                if lineText == "---" || lineText == "..." { frontMatter = false }
                if visible {
                    spans.append(CodeEditorSpan(
                        location: line.location,
                        length: line.length,
                        style: frontMatter ? .token(.comment) : .marker
                    ))
                }
            } else if let open = fenceMarker {
                let trimmed = lineText.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) {
                    if NSMaxRange(line) >= window.location, fenceBodyStart <= windowEnd { flushFence(until: line.location) }
                    fenceMarker = nil
                    if visible { spans.append(CodeEditorSpan(location: line.location, length: line.length, style: .marker)) }
                } else if fenceLanguage == .unknown, visible {
                    spans.append(CodeEditorSpan(location: line.location, length: line.length, style: .inlineCode))
                }
            } else if let match = fence?.firstMatch(in: lineText, range: whole) {
                fenceMarker = lineNS.substring(with: match.range(at: 1))
                let info = lineNS.substring(with: match.range(at: 2))
                fenceLanguage = info.isEmpty ? .unknown : SyntaxLanguage.detect(info)
                fenceBodyStart = next
                if visible { spans.append(CodeEditorSpan(location: line.location, length: line.length, style: .marker)) }
            } else if visible {
                styleLine(lineNS, at: line.location, into: &spans)
            }

            if line.location > windowEnd { break }
            lineNumber += 1
            if next <= location { break }
            location = next
        }
        if fenceMarker != nil, fenceBodyStart <= windowEnd {
            flushFence(until: min(text.length, text.lineRange(for: NSRange(location: min(windowEnd, text.length), length: 0)).upperBound))
        }
        return spans
    }

    private static func styleLine(_ line: NSString, at base: Int, into spans: inout [CodeEditorSpan]) {
        let whole = NSRange(location: 0, length: line.length)
        guard whole.length > 0 else { return }
        func add(_ range: NSRange, _ style: CodeEditorSpanStyle) {
            guard range.location != NSNotFound, range.length > 0 else { return }
            spans.append(CodeEditorSpan(location: base + range.location, length: range.length, style: style))
        }

        if rule?.firstMatch(in: line as String, range: whole) != nil {
            add(whole, .marker)
            return
        }
        var inlineStart = 0
        if let match = heading?.firstMatch(in: line as String, range: whole) {
            add(whole, .heading)
            add(match.range(at: 1), .marker)
            inlineStart = NSMaxRange(match.range)
        } else if let match = quote?.firstMatch(in: line as String, range: whole) {
            add(whole, .quote)
            add(match.range, .marker)
            inlineStart = NSMaxRange(match.range)
        }
        if let match = listMarker?.firstMatch(in: line as String, range: NSRange(location: inlineStart, length: line.length - inlineStart)) {
            add(match.range, .marker)
            inlineStart = NSMaxRange(match.range)
        }
        let inline = NSRange(location: inlineStart, length: line.length - inlineStart)
        guard inline.length > 0 else { return }

        // Code spans first; nothing else paints inside them. Links claim their
        // URL so the bare-URL rule does not paint it again.
        var code: [NSRange] = []
        var linked: [NSRange] = []
        codeSpan?.enumerateMatches(in: line as String, range: inline) { match, _, _ in
            guard let match else { return }
            code.append(match.range)
            add(match.range, .inlineCode)
            add(match.range(at: 1), .marker)
            add(NSRange(location: NSMaxRange(match.range) - match.range(at: 1).length, length: match.range(at: 1).length), .marker)
        }
        func outsideCode(_ range: NSRange) -> Bool {
            !code.contains { NSIntersectionRange($0, range).length > 0 }
        }
        func paired(_ regex: NSRegularExpression?, _ style: CodeEditorSpanStyle) {
            regex?.enumerateMatches(in: line as String, range: inline) { match, _, _ in
                guard let match, outsideCode(match.range) else { return }
                let marker = match.range(at: 1).length
                add(match.range, style)
                add(NSRange(location: match.range.location, length: marker), .marker)
                add(NSRange(location: NSMaxRange(match.range) - marker, length: marker), .marker)
            }
        }
        paired(strong, .strong)
        paired(emphasis, .emphasis)
        paired(strike, .strikethrough)
        link?.enumerateMatches(in: line as String, range: inline) { match, _, _ in
            guard let match, outsideCode(match.range) else { return }
            add(match.range(at: 1), .marker)
            add(match.range(at: 2), .link)
            add(match.range(at: 3), .marker)
            add(match.range(at: 4), .url)
            add(match.range(at: 5), .marker)
            linked.append(match.range)
        }
        wikiLink?.enumerateMatches(in: line as String, range: inline) { match, _, _ in
            guard let match, outsideCode(match.range) else { return }
            add(match.range(at: 1), .marker)
            add(match.range(at: 2), .link)
            add(match.range(at: 3), .marker)
        }
        autolink?.enumerateMatches(in: line as String, range: inline) { match, _, _ in
            guard let match, outsideCode(match.range),
                  !linked.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }
            add(match.range, .url)
        }
        htmlComment?.enumerateMatches(in: line as String, range: inline) { match, _, _ in
            guard let match, outsideCode(match.range) else { return }
            add(match.range, .token(.comment))
        }
    }
}
