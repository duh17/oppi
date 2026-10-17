import UIKit

/// Attribute key for tagging diff line kind (added/removed/header) for full-width background rendering.
let diffLineKindAttributeKey = NSAttributedString.Key("unifiedDiffLineKind")
/// Attribute key for resolving selected diff text back to source line numbers.
let reviewLineNumberAttributeKey = NSAttributedString.Key("oppiReviewLineNumber")
/// Attribute key marking the code/text column inside a rendered diff row.
let diffCodeColumnAttributeKey = NSAttributedString.Key("oppiDiffCodeColumn")

/// Builds the attributed string for a unified diff from structured hunks.
///
/// Architecture: two main phases:
/// 1. Build the string by appending small pre-attributed segments. Each segment
///    (gutter, line numbers, code) gets its final font/foreground from the start.
///    This eliminates the expensive Phase 4 attribute overrides (1300+ addAttribute
///    calls on a large string). Append is O(1) amortized.
/// 2. Apply row-level backgrounds, syntax highlights, and word-span overrides
///    via addAttribute on the assembled string.
enum DiffAttributedStringBuilder {

    // MARK: - Cached Style Attrs

    private struct StyleAttrs {
        let codeFont: UIFont
        let paragraph: NSParagraphStyle

        // Segment attribute dictionaries (used during append phase)
        let headerAttrs: [NSAttributedString.Key: Any]
        let sectionHeaderBlockAttrs: [NSAttributedString.Key: Any]
        let gapSummaryAttrs: [NSAttributedString.Key: Any]
        let codeDefaultAttrs: [NSAttributedString.Key: Any]
        /// Row tints as `.backgroundColor` attributes, for plain TextKit consumers.
        let attributeRows: RowStyle
        /// Row tints left to `DiffReaderView`'s tint layers.
        let paintedRows: RowStyle
        let painterColors: PainterColors

        let fgColor: UIColor

        // Syntax token colors
        // Array indexed by TokenKind.rawValue for O(1) lookup (no dictionary hash)
        let syntaxColorArray: [UIColor?]  // 9 entries: variable=nil, comment..operator

        // Stats summary accents (exposed for inline styling)
        let addedAccentColor: UIColor
        let removedAccentColor: UIColor
        let commentDimColor: UIColor

        private final class CacheBox: @unchecked Sendable {
            private let lock = NSLock()
            private var cached: StyleAttrs?
            private var cachedThemeID: ThemeID?

            func current() -> StyleAttrs {
                let currentThemeID = ThemeRuntimeState.currentThemeID()

                lock.lock()
                if let cached, cachedThemeID == currentThemeID {
                    lock.unlock()
                    return cached
                }
                lock.unlock()

                let attrs = StyleAttrs.make(themeID: currentThemeID)

                lock.lock()
                cached = attrs
                cachedThemeID = currentThemeID
                lock.unlock()
                return attrs
            }
        }

        private static let cacheBox = CacheBox()

        static func current() -> Self {
            cacheBox.current()
        }

        private static func make(themeID: ThemeID) -> Self {
            let palette = themeID.palette
            let codeFont = AppFont.monoMedium
            let headerFont = AppFont.monoBold
            let gutterFont = AppFont.monoBold
            let lineNumFont = AppFont.monoSmall

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping

            let addedAccent = UIColor(palette.toolDiffAdded)
            let removedAccent = UIColor(palette.toolDiffRemoved)
            let contextDim = UIColor(palette.comment.opacity(0.4))
            let lineNumColor = UIColor(palette.comment.opacity(0.5))
            let fgColor = UIColor(palette.fg)
            let fgDimColor = UIColor(palette.fgDim)
            let headerColor = UIColor(palette.purple)
            let gapSummaryColor = UIColor(palette.fgDim)

            let lineAddedBg = UIColor(palette.toolDiffAdded.opacity(0.12))
            let lineRemovedBg = UIColor(palette.toolDiffRemoved.opacity(0.10))
            let wordAddedBg = UIColor(palette.toolDiffAdded.opacity(0.35))
            let wordRemovedBg = UIColor(palette.toolDiffRemoved.opacity(0.35))

            // Painter-backed readers draw the text-extent tint themselves (cheap
            // line-fragment rects instead of TextKit's per-run attribute rects),
            // then word backgrounds, then the full-width row tint. A word
            // background now lands on top of the text tint instead of replacing
            // it, so its alpha is reduced to give the same pixel:
            // 1 - (1 - text)(1 - word') = 0.35. Same hue, so this is exact.
            let paintedWordAddedBg = UIColor(palette.toolDiffAdded.opacity(1 - (1 - 0.35) / (1 - 0.12)))
            let paintedWordRemovedBg = UIColor(palette.toolDiffRemoved.opacity(1 - (1 - 0.35) / (1 - 0.10)))

            func rows(
                addedBackground: UIColor?,
                removedBackground: UIColor?,
                wordAdded: UIColor,
                wordRemoved: UIColor
            ) -> RowStyle {
                func tinted(
                    _ attrs: [NSAttributedString.Key: Any],
                    _ background: UIColor?
                ) -> [NSAttributedString.Key: Any] {
                    guard let background else { return attrs }
                    return attrs.merging([.backgroundColor: background]) { _, new in new }
                }
                return RowStyle(
                    gutterAdded: tinted([.font: gutterFont, .foregroundColor: addedAccent, .paragraphStyle: paragraph, diffLineKindAttributeKey: "added"], addedBackground),
                    gutterRemoved: tinted([.font: gutterFont, .foregroundColor: removedAccent, .paragraphStyle: paragraph, diffLineKindAttributeKey: "removed"], removedBackground),
                    gutterContext: [.font: gutterFont, .foregroundColor: contextDim, .paragraphStyle: paragraph],
                    numberAdded: tinted([.font: lineNumFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph, diffLineKindAttributeKey: "added"], addedBackground),
                    numberRemoved: tinted([.font: lineNumFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph, diffLineKindAttributeKey: "removed"], removedBackground),
                    numberContext: [.font: lineNumFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph],
                    codeAdded: tinted([.font: codeFont, .foregroundColor: fgColor, .paragraphStyle: paragraph, diffLineKindAttributeKey: "added", diffCodeColumnAttributeKey: true], addedBackground),
                    codeRemoved: tinted([.font: codeFont, .foregroundColor: fgColor, .paragraphStyle: paragraph, diffLineKindAttributeKey: "removed", diffCodeColumnAttributeKey: true], removedBackground),
                    codeContext: [.font: codeFont, .foregroundColor: fgDimColor, .paragraphStyle: paragraph, diffCodeColumnAttributeKey: true],
                    wordAdded: wordAdded,
                    wordRemoved: wordRemoved
                )
            }

            // Cache iOS painter colors once per theme. Keep the array for O(1)
            // lookup; do not convert palette colors per token.
            var syntaxColorArray: [UIColor?] = Array(repeating: nil, count: 9)
            let kinds: [SyntaxHighlighter.TokenKind] = [
                .variable, .comment, .keyword, .string, .number,
                .type, .punctuation, .function, .operator,
            ]
            for kind in kinds {
                syntaxColorArray[Int(kind.rawValue)] = SyntaxHighlighter.color(for: kind, themeID: themeID)
            }

            return Self(
                codeFont: codeFont,
                paragraph: paragraph,
                headerAttrs: [.font: headerFont, .foregroundColor: headerColor, .paragraphStyle: paragraph, diffLineKindAttributeKey: "header"],
                sectionHeaderBlockAttrs: [.paragraphStyle: paragraph, diffLineKindAttributeKey: "header"],
                gapSummaryAttrs: [.font: AppFont.systemSmall, .foregroundColor: gapSummaryColor, .paragraphStyle: paragraph],
                codeDefaultAttrs: [.font: codeFont, .foregroundColor: fgColor, .paragraphStyle: paragraph],
                attributeRows: rows(
                    addedBackground: lineAddedBg,
                    removedBackground: lineRemovedBg,
                    wordAdded: wordAddedBg,
                    wordRemoved: wordRemovedBg
                ),
                paintedRows: rows(
                    addedBackground: nil,
                    removedBackground: nil,
                    wordAdded: paintedWordAddedBg,
                    wordRemoved: paintedWordRemovedBg
                ),
                painterColors: PainterColors(
                    addedText: lineAddedBg,
                    removedText: lineRemovedBg,
                    addedRow: UIColor(palette.toolDiffAdded.opacity(0.10)),
                    removedRow: UIColor(palette.toolDiffRemoved.opacity(0.08)),
                    header: UIColor(palette.bgHighlight),
                    addedBar: addedAccent,
                    removedBar: removedAccent
                ),
                fgColor: fgColor,
                syntaxColorArray: syntaxColorArray,
                addedAccentColor: addedAccent,
                removedAccentColor: removedAccent,
                commentDimColor: lineNumColor
            )
        }

    }

    /// Segment attributes for one row kind under one background strategy.
    private struct RowStyle {
        let gutterAdded: [NSAttributedString.Key: Any]
        let gutterRemoved: [NSAttributedString.Key: Any]
        let gutterContext: [NSAttributedString.Key: Any]
        let numberAdded: [NSAttributedString.Key: Any]
        let numberRemoved: [NSAttributedString.Key: Any]
        let numberContext: [NSAttributedString.Key: Any]
        let codeAdded: [NSAttributedString.Key: Any]
        let codeRemoved: [NSAttributedString.Key: Any]
        let codeContext: [NSAttributedString.Key: Any]
        let wordAdded: UIColor
        let wordRemoved: UIColor

        func segments(
            for kind: WorkspaceReviewDiffLine.Kind
        ) -> (gutter: [NSAttributedString.Key: Any], number: [NSAttributedString.Key: Any], code: [NSAttributedString.Key: Any]) {
            switch kind {
            case .added: (gutterAdded, numberAdded, codeAdded)
            case .removed: (gutterRemoved, numberRemoved, codeRemoved)
            case .context: (gutterContext, numberContext, codeContext)
            }
        }

        func wordBackground(for kind: WorkspaceReviewDiffLine.Kind) -> UIColor {
            kind == .removed ? wordRemoved : wordAdded
        }
    }

    /// Row tint colors for `DiffReaderView`'s tint layers, cached per theme.
    struct PainterColors {
        /// Behind the row's text (what the row `.backgroundColor` attribute covers).
        let addedText: UIColor
        let removedText: UIColor
        /// Across the full content width, over everything else.
        let addedRow: UIColor
        let removedRow: UIColor
        let header: UIColor
        let addedBar: UIColor
        let removedBar: UIColor
    }

    static func painterColors() -> PainterColors {
        StyleAttrs.current().painterColors
    }

    /// Per-line metadata tracked during assembly.
    private struct LineInfo {
        let gutterStart: Int
        let numStart: Int   // start of the single displayed line number block
        let markerStart: Int
        let codeStart: Int
        let codeLen: Int
        let rowEnd: Int
        let lineNumber: Int?
        let kind: WorkspaceReviewDiffLine.Kind
        let spans: [WorkspaceReviewDiffSpan]?
    }

    /// Old and new source projections for one contiguous hunk.
    /// Context is included in both so later removed/added lines see real lexer state,
    /// but displayed context is painted only from the new projection.
    private struct HunkSyntaxProjection {
        var oldCode = ""
        var newCode = ""
        var oldUTF16 = 0
        var newUTF16 = 0
        var oldLines: [(lineIndex: Int, start: Int)] = []
        var newLines: [(lineIndex: Int, start: Int)] = []

        mutating func append(lineIndex: Int, kind: WorkspaceReviewDiffLine.Kind, codeText: String) {
            switch kind {
            case .removed:
                appendOld(lineIndex: lineIndex, codeText: codeText)
            case .added:
                appendNew(lineIndex: lineIndex, codeText: codeText)
            case .context:
                appendOld(lineIndex: lineIndex, codeText: codeText)
                appendNew(lineIndex: lineIndex, codeText: codeText)
            }
        }

        private mutating func appendOld(lineIndex: Int, codeText: String) {
            if oldUTF16 > 0 {
                oldCode.append("\n")
                oldUTF16 += 1
            }
            oldLines.append((lineIndex, oldUTF16))
            oldCode.append(codeText)
            oldUTF16 += codeText.utf16.count
        }

        private mutating func appendNew(lineIndex: Int, codeText: String) {
            if newUTF16 > 0 {
                newCode.append("\n")
                newUTF16 += 1
            }
            newLines.append((lineIndex, newUTF16))
            newCode.append(codeText)
            newUTF16 += codeText.utf16.count
        }
    }

    /// Collapsed unchanged-lines separator position.
    private struct HeaderInfo {
        let fullRange: NSRange
    }

    /// Stats summary line segment positions.
    private struct StatsSegments {
        let fullRange: NSRange
        let addedRange: NSRange?
        let removedRange: NSRange?
        let totalRange: NSRange
    }

    struct Options: Sendable {
        var includeStats = false
        var includeGapSummary = true
        /// The text will be shown by `DiffReaderView`, which tints rows with
        /// layers. Leaving row `.backgroundColor` attributes out matters for long
        /// lines: TextKit sizes attribute backgrounds across the whole line, which
        /// cost ~22 ms per tile on a 2,000-character diff.
        var paintsRowBackgrounds = false
    }

    struct BuildResult {
        let attributedText: NSAttributedString
    }

    // MARK: - Build

    static func build(hunks: [WorkspaceReviewDiffHunk], filePath: String, includeStats: Bool = false) -> NSAttributedString {
        buildResult(
            hunks: hunks,
            filePath: filePath,
            options: Options(includeStats: includeStats)
        ).attributedText
    }

    static func buildResult(
        hunks: [WorkspaceReviewDiffHunk],
        filePath: String,
        options: Options = Options()
    ) -> BuildResult {
        let language = FileType.detect(from: filePath).syntaxLanguage ?? .unknown
        let style = StyleAttrs.current()

        var maxLineNum = 1
        var totalLines = 0
        var totalAdded = 0
        var totalRemoved = 0
        for hunk in hunks {
            totalLines += hunk.lines.count
            for line in hunk.lines {
                if let n = displayedLineNumber(for: line) { maxLineNum = max(maxLineNum, n) }
                switch line.kind {
                case .added: totalAdded += 1
                case .removed: totalRemoved += 1
                case .context: break
                }
            }
        }
        let numDigits = max(3, String(maxLineNum).count)

        var paddedNums = [String](repeating: "", count: maxLineNum + 1)
        paddedNums[0] = String(repeating: " ", count: numDigits)
        for i in 1...maxLineNum {
            paddedNums[i] = paddedNumber(i, digits: numDigits)
        }

        let text = NSMutableString()
        var lineInfos: [LineInfo] = []
        lineInfos.reserveCapacity(totalLines)
        var headers: [HeaderInfo] = []
        var hunkProjections: [HunkSyntaxProjection] = []
        if language != .unknown {
            hunkProjections.reserveCapacity(hunks.count)
        }

        var statsSegs: StatsSegments?
        if options.includeStats, totalAdded > 0 || totalRemoved > 0 {
            let statsStart = text.length
            text.append(" ")
            var addedRange: NSRange?
            if totalAdded > 0 {
                let s = text.length
                text.append("+\(totalAdded)")
                addedRange = NSRange(location: s, length: text.length - s)
                text.append(" ")
            }
            var removedRange: NSRange?
            if totalRemoved > 0 {
                let s = text.length
                text.append("-\(totalRemoved)")
                removedRange = NSRange(location: s, length: text.length - s)
                text.append(" ")
            }
            text.append(" ")
            let totalStart = text.length
            text.append("\(totalLines) lines")
            let totalRange = NSRange(location: totalStart, length: text.length - totalStart)
            text.append("\n")
            statsSegs = StatsSegments(
                fullRange: NSRange(location: statsStart, length: text.length - statsStart),
                addedRange: addedRange,
                removedRange: removedRange,
                totalRange: totalRange
            )
        }

        for (hunkIndex, hunk) in hunks.enumerated() {
            if hunkIndex > 0 {
                text.append("\n")
                if options.includeGapSummary,
                   let gap = unchangedLineGap(from: hunks[hunkIndex - 1], to: hunk),
                   gap > 0 {
                    let gapStart = text.length
                    text.append(" … ")
                    text.append("\(gap) unchanged line")
                    if gap != 1 {
                        text.append("s")
                    }
                    text.append("\n")
                    let gapRange = NSRange(location: gapStart, length: text.length - gapStart)
                    headers.append(HeaderInfo(fullRange: gapRange))
                }
            }

            var projection = HunkSyntaxProjection()
            for line in hunk.lines {
                let displayLineNumber = displayedLineNumber(for: line)

                let gutterStart = text.length
                text.append(" ")

                let numStart = text.length
                text.append(paddedNums[displayLineNumber ?? 0])

                let markerStart = text.length
                switch line.kind {
                case .added: text.append(" + ")
                case .removed: text.append(" - ")
                case .context: text.append("   ")
                }

                let codeStart = text.length
                let codeText = line.text.isEmpty ? " " : line.text
                text.append(codeText)
                let codeLen = text.length - codeStart

                text.append("\n")
                let rowEnd = text.length

                lineInfos.append(LineInfo(
                    gutterStart: gutterStart,
                    numStart: numStart,
                    markerStart: markerStart,
                    codeStart: codeStart,
                    codeLen: codeLen,
                    rowEnd: rowEnd,
                    lineNumber: displayLineNumber,
                    kind: line.kind,
                    spans: line.spans
                ))

                if language != .unknown {
                    projection.append(
                        lineIndex: lineInfos.count - 1,
                        kind: line.kind,
                        codeText: codeText
                    )
                }
            }
            if language != .unknown {
                hunkProjections.append(projection)
            }
        }

        let result = NSMutableAttributedString(string: text as String, attributes: style.codeDefaultAttrs)
        result.beginEditing()

        for header in headers {
            result.setAttributes(style.sectionHeaderBlockAttrs, range: header.fullRange)
            result.addAttributes(style.gapSummaryAttrs, range: header.fullRange)
        }

        if let stats = statsSegs {
            result.setAttributes(style.headerAttrs, range: stats.fullRange)
            if let r = stats.addedRange {
                result.addAttribute(.foregroundColor, value: style.addedAccentColor, range: r)
                result.addAttribute(.font, value: AppFont.monoMediumBold, range: r)
            }
            if let r = stats.removedRange {
                result.addAttribute(.foregroundColor, value: style.removedAccentColor, range: r)
                result.addAttribute(.font, value: AppFont.monoMediumBold, range: r)
            }
            result.addAttribute(.foregroundColor, value: style.commentDimColor, range: stats.totalRange)
            result.addAttribute(.font, value: AppFont.systemSmall, range: stats.totalRange)
        }

        let rows = options.paintsRowBackgrounds ? style.paintedRows : style.attributeRows
        for info in lineInfos {
            let (gutterAttrs, numAttrs, codeAttrs) = rows.segments(for: info.kind)

            let rowRange = NSRange(location: info.gutterStart, length: info.rowEnd - info.gutterStart)

            result.setAttributes(gutterAttrs, range: NSRange(location: info.gutterStart, length: info.numStart - info.gutterStart))
            result.setAttributes(numAttrs, range: NSRange(location: info.numStart, length: info.markerStart - info.numStart))
            result.setAttributes(gutterAttrs, range: NSRange(location: info.markerStart, length: info.codeStart - info.markerStart))

            if info.kind == .context {
                result.setAttributes(codeAttrs, range: NSRange(location: info.codeStart, length: info.codeLen + 1))
            } else {
                result.setAttributes(codeAttrs, range: NSRange(location: info.codeStart, length: info.codeLen))
            }

            if let lineNumber = info.lineNumber {
                result.addAttribute(reviewLineNumberAttributeKey, value: lineNumber, range: rowRange)
            }
        }

        for info in lineInfos {
            guard let spans = info.spans, !spans.isEmpty else { continue }
            let wordBg = rows.wordBackground(for: info.kind)
            for span in spans {
                let length = span.end - span.start
                guard span.start >= 0, length > 0 else { continue }
                let spanStart = info.codeStart + span.start
                guard spanStart + length <= info.codeStart + info.codeLen else { continue }
                result.addAttribute(.backgroundColor, value: wordBg, range: NSRange(location: spanStart, length: length))
            }
        }

        if language != .unknown {
            let colorArray = style.syntaxColorArray
            for projection in hunkProjections {
                let oldTokens = TreeSitterHighlighter.resolvedTokenRangesUTF8(projection.oldCode, language: language)
                let newTokens = TreeSitterHighlighter.resolvedTokenRangesUTF8(projection.newCode, language: language)
                // Removed rows use the old projection. Added and context rows use the new one.
                applySyntaxTokens(
                    oldTokens,
                    onto: projection.oldLines.filter { lineInfos[$0.lineIndex].kind == .removed },
                    lineInfos: lineInfos,
                    in: result,
                    colorArray: colorArray
                )
                applySyntaxTokens(
                    newTokens,
                    onto: projection.newLines.filter { lineInfos[$0.lineIndex].kind != .removed },
                    lineInfos: lineInfos,
                    in: result,
                    colorArray: colorArray
                )
            }
        }

        let fgColor = style.fgColor
        for info in lineInfos {
            guard let spans = info.spans, !spans.isEmpty else { continue }
            for span in spans {
                let length = span.end - span.start
                guard span.start >= 0, length > 0 else { continue }
                let spanStart = info.codeStart + span.start
                guard spanStart + length <= info.codeStart + info.codeLen else { continue }
                result.addAttribute(.foregroundColor, value: fgColor, range: NSRange(location: spanStart, length: length))
            }
        }

        result.endEditing()
        return BuildResult(attributedText: result)
    }

    // MARK: - Virtualized chunk index

    /// Compact, attributed-text-free index used by large diff readers. Syntax is
    /// resolved once across each complete hunk so lazily painted chunks keep the
    /// same lexer context as the whole-document renderer.
    struct ChunkIndex: Sendable {
        struct Chunk: Sendable {
            fileprivate let entries: [ChunkEntry]
            let renderedUTF16Count: Int
            let renderedLineCount: Int
            let widestUTF16ColumnCount: Int
            fileprivate let numberDigits: Int
        }

        let id: UUID
        let chunks: [Chunk]
        let totalUTF16Count: Int
        let renderedLineCount: Int
        let widestUTF16ColumnCount: Int
        let indexRanOnMainThread: Bool
    }

    fileprivate struct IndexedSyntaxSpan: Sendable {
        let location: Int
        let length: Int
        let kind: SyntaxHighlighter.TokenKind
    }

    fileprivate struct IndexedRow: Sendable {
        let line: WorkspaceReviewDiffLine
        let displayedLineNumber: Int?
        let syntaxSpans: [IndexedSyntaxSpan]
    }

    fileprivate enum ChunkEntry: Sendable {
        case stats(added: Int, removed: Int, total: Int)
        case blank
        case gap(Int)
        case row(IndexedRow)

        var renderedLineCount: Int { 1 }

        var renderedString: String {
            switch self {
            case .stats(let added, let removed, let total):
                var value = " "
                if added > 0 { value += "+\(added) " }
                if removed > 0 { value += "-\(removed) " }
                return value + " \(total) lines\n"
            case .blank:
                return "\n"
            case .gap(let count):
                return " … \(count) unchanged line\(count == 1 ? "" : "s")\n"
            case .row(let row):
                let marker: String
                switch row.line.kind {
                case .added: marker = " + "
                case .removed: marker = " - "
                case .context: marker = "   "
                }
                return " \(row.displayedLineNumber.map(String.init) ?? "")\(marker)\(row.line.text.isEmpty ? " " : row.line.text)\n"
            }
        }
    }

    /// Builds only source/token metadata. No `NSAttributedString` or TextKit
    /// document is created here, and callers run this operation off the main actor.
    static func buildChunkIndex(
        hunks: [WorkspaceReviewDiffHunk],
        filePath: String,
        options: Options = Options(),
        maxLines: Int = 160,
        maxUTF8Bytes: Int = 32 * 1024
    ) -> ChunkIndex {
        let safeLineLimit = max(1, maxLines)
        let safeByteLimit = max(1, maxUTF8Bytes)
        let language = FileType.detect(from: filePath).syntaxLanguage ?? .unknown

        var maxLineNumber = 1
        var totalLines = 0
        var totalAdded = 0
        var totalRemoved = 0
        for hunk in hunks {
            totalLines += hunk.lines.count
            for line in hunk.lines {
                if let number = displayedLineNumber(for: line) {
                    maxLineNumber = max(maxLineNumber, number)
                }
                switch line.kind {
                case .added: totalAdded += 1
                case .removed: totalRemoved += 1
                case .context: break
                }
            }
        }
        let numberDigits = max(3, String(maxLineNumber).count)

        var entries: [ChunkEntry] = []
        entries.reserveCapacity(totalLines + hunks.count * 2 + 1)
        if options.includeStats, totalAdded > 0 || totalRemoved > 0 {
            entries.append(.stats(added: totalAdded, removed: totalRemoved, total: totalLines))
        }

        for (hunkIndex, hunk) in hunks.enumerated() {
            if hunkIndex > 0 {
                entries.append(.blank)
                if options.includeGapSummary,
                   let gap = unchangedLineGap(from: hunks[hunkIndex - 1], to: hunk),
                   gap > 0 {
                    entries.append(.gap(gap))
                }
            }

            let syntaxByLine = indexedSyntaxSpans(in: hunk, language: language)
            for (lineIndex, line) in hunk.lines.enumerated() {
                entries.append(.row(IndexedRow(
                    line: line,
                    displayedLineNumber: displayedLineNumber(for: line),
                    syntaxSpans: syntaxByLine[lineIndex]
                )))
            }
        }

        var chunks: [ChunkIndex.Chunk] = []
        var currentEntries: [ChunkEntry] = []
        var currentLines = 0
        var currentBytes = 0
        var currentUTF16 = 0
        var currentWidest = 0

        func flush() {
            guard !currentEntries.isEmpty else { return }
            chunks.append(ChunkIndex.Chunk(
                entries: currentEntries,
                renderedUTF16Count: currentUTF16,
                renderedLineCount: currentLines,
                widestUTF16ColumnCount: currentWidest,
                numberDigits: numberDigits
            ))
            currentEntries.removeAll(keepingCapacity: true)
            currentLines = 0
            currentBytes = 0
            currentUTF16 = 0
            currentWidest = 0
        }

        for entry in entries {
            let rendered = renderedString(for: entry, numberDigits: numberDigits)
            let entryBytes = rendered.utf8.count
            if !currentEntries.isEmpty,
               currentLines + entry.renderedLineCount > safeLineLimit
                || currentBytes + entryBytes > safeByteLimit {
                flush()
            }
            currentEntries.append(entry)
            currentLines += entry.renderedLineCount
            currentBytes += entryBytes
            currentUTF16 += rendered.utf16.count
            let lineWidth = rendered.last == "\n" ? rendered.dropLast().utf16.count : rendered.utf16.count
            currentWidest = max(currentWidest, lineWidth)
        }
        flush()

        return ChunkIndex(
            id: UUID(),
            chunks: chunks,
            totalUTF16Count: chunks.reduce(into: 0) { $0 += $1.renderedUTF16Count },
            renderedLineCount: chunks.reduce(into: 0) { $0 += $1.renderedLineCount },
            widestUTF16ColumnCount: chunks.map(\.widestUTF16ColumnCount).max() ?? 0,
            indexRanOnMainThread: Thread.isMainThread
        )
    }

    /// Paints one indexed chunk on demand. The index already contains syntax
    /// ranges, while theme colors and word-span backgrounds are applied here.
    static func buildChunk(_ chunk: ChunkIndex.Chunk) -> NSAttributedString {
        let style = StyleAttrs.current()
        let numberDigits = chunk.numberDigits
        let result = NSMutableAttributedString(string: "")

        for entry in chunk.entries {
            switch entry {
            case .stats(let added, let removed, let total):
                let start = result.length
                result.append(NSAttributedString(string: " ", attributes: style.headerAttrs))
                if added > 0 {
                    result.append(NSAttributedString(
                        string: "+\(added)",
                        attributes: style.headerAttrs.merging([
                            .foregroundColor: style.addedAccentColor,
                            .font: AppFont.monoMediumBold,
                        ]) { _, new in new }
                    ))
                    result.append(NSAttributedString(string: " ", attributes: style.headerAttrs))
                }
                if removed > 0 {
                    result.append(NSAttributedString(
                        string: "-\(removed)",
                        attributes: style.headerAttrs.merging([
                            .foregroundColor: style.removedAccentColor,
                            .font: AppFont.monoMediumBold,
                        ]) { _, new in new }
                    ))
                    result.append(NSAttributedString(string: " ", attributes: style.headerAttrs))
                }
                result.append(NSAttributedString(string: " ", attributes: style.headerAttrs))
                result.append(NSAttributedString(
                    string: "\(total) lines",
                    attributes: style.headerAttrs.merging([
                        .foregroundColor: style.commentDimColor,
                        .font: AppFont.systemSmall,
                    ]) { _, new in new }
                ))
                result.append(NSAttributedString(string: "\n", attributes: style.headerAttrs))
                assert(result.length > start)

            case .blank:
                result.append(NSAttributedString(string: "\n", attributes: style.codeDefaultAttrs))

            case .gap(let count):
                result.append(NSAttributedString(
                    string: " … \(count) unchanged line\(count == 1 ? "" : "s")\n",
                    attributes: style.sectionHeaderBlockAttrs.merging(style.gapSummaryAttrs) { _, new in new }
                ))

            case .row(let row):
                append(row: row, numberDigits: numberDigits, style: style, to: result)
            }
        }
        return result
    }

    private static func append(
        row: IndexedRow,
        numberDigits: Int,
        style: StyleAttrs,
        to result: NSMutableAttributedString
    ) {
        // Chunks only render inside `DiffReaderView`, which tints rows with layers.
        let rows = style.paintedRows
        let (gutterAttrs, numberAttrs, codeAttrs) = rows.segments(for: row.line.kind)
        let marker: String
        switch row.line.kind {
        case .added: marker = " + "
        case .removed: marker = " - "
        case .context: marker = "   "
        }

        let rowStart = result.length
        result.append(NSAttributedString(string: " ", attributes: gutterAttrs))
        let number = row.displayedLineNumber.map { paddedNumber($0, digits: numberDigits) }
            ?? String(repeating: " ", count: numberDigits)
        result.append(NSAttributedString(string: number, attributes: numberAttrs))
        result.append(NSAttributedString(string: marker, attributes: gutterAttrs))
        let codeStart = result.length
        let code = row.line.text.isEmpty ? " " : row.line.text
        result.append(NSAttributedString(string: code, attributes: codeAttrs))
        if row.line.kind == .context {
            result.append(NSAttributedString(string: "\n", attributes: codeAttrs))
        } else {
            result.append(NSAttributedString(string: "\n", attributes: style.codeDefaultAttrs))
        }
        let rowRange = NSRange(location: rowStart, length: result.length - rowStart)
        if let lineNumber = row.displayedLineNumber {
            result.addAttribute(reviewLineNumberAttributeKey, value: lineNumber, range: rowRange)
        }

        for syntax in row.syntaxSpans {
            guard let color = style.syntaxColorArray[Int(syntax.kind.rawValue)] else { continue }
            result.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: codeStart + syntax.location, length: syntax.length)
            )
        }
        if let spans = row.line.spans, !spans.isEmpty {
            let background = rows.wordBackground(for: row.line.kind)
            for span in spans {
                let length = span.end - span.start
                guard span.start >= 0, length > 0, span.end <= code.utf16.count else { continue }
                let range = NSRange(location: codeStart + span.start, length: length)
                result.addAttribute(.backgroundColor, value: background, range: range)
                result.addAttribute(.foregroundColor, value: style.fgColor, range: range)
            }
        }
    }

    private static func renderedString(for entry: ChunkEntry, numberDigits: Int) -> String {
        guard case .row(let row) = entry else { return entry.renderedString }
        let number = row.displayedLineNumber.map { paddedNumber($0, digits: numberDigits) }
            ?? String(repeating: " ", count: numberDigits)
        let marker: String
        switch row.line.kind {
        case .added: marker = " + "
        case .removed: marker = " - "
        case .context: marker = "   "
        }
        return " \(number)\(marker)\(row.line.text.isEmpty ? " " : row.line.text)\n"
    }

    private static func indexedSyntaxSpans(
        in hunk: WorkspaceReviewDiffHunk,
        language: SyntaxLanguage
    ) -> [[IndexedSyntaxSpan]] {
        var result = [[IndexedSyntaxSpan]](repeating: [], count: hunk.lines.count)
        guard language != .unknown, !hunk.lines.isEmpty else { return result }

        var projection = HunkSyntaxProjection()
        for (lineIndex, line) in hunk.lines.enumerated() {
            projection.append(
                lineIndex: lineIndex,
                kind: line.kind,
                codeText: line.text.isEmpty ? " " : line.text
            )
        }

        func map(
            _ tokens: [SyntaxHighlighter.TokenRange],
            lines: [(lineIndex: Int, start: Int)]
        ) {
            guard !tokens.isEmpty, !lines.isEmpty else { return }
            let starts = lines.map(\.start)
            for token in tokens {
                let tokenEnd = token.location + token.length
                guard tokenEnd > token.location else { continue }
                SyntaxHighlighter.forEachOverlappingSourceLine(
                    lineStarts: starts,
                    tokenStart: token.location,
                    tokenEnd: tokenEnd,
                    lineLengthAt: { hunk.lines[lines[$0].lineIndex].text.isEmpty ? 1 : hunk.lines[lines[$0].lineIndex].text.utf16.count },
                    body: { mappedLine, overlapStart, overlapEnd in
                        let source = lines[mappedLine]
                        result[source.lineIndex].append(IndexedSyntaxSpan(
                            location: overlapStart - source.start,
                            length: overlapEnd - overlapStart,
                            kind: token.kind
                        ))
                    }
                )
            }
        }

        let oldLines = projection.oldLines.filter { hunk.lines[$0.lineIndex].kind == .removed }
        let newLines = projection.newLines.filter { hunk.lines[$0.lineIndex].kind != .removed }
        map(TreeSitterHighlighter.resolvedTokenRangesUTF8(projection.oldCode, language: language), lines: oldLines)
        map(TreeSitterHighlighter.resolvedTokenRangesUTF8(projection.newCode, language: language), lines: newLines)
        return result
    }

    private static func applySyntaxTokens(
        _ tokens: [SyntaxHighlighter.TokenRange],
        onto lines: [(lineIndex: Int, start: Int)],
        lineInfos: [LineInfo],
        in result: NSMutableAttributedString,
        colorArray: [UIColor?]
    ) {
        guard !tokens.isEmpty, !lines.isEmpty else { return }
        let nsLength = result.length
        let lineStarts = lines.map(\.start)
        for token in tokens {
            guard let color = colorArray[Int(token.kind.rawValue)] else { continue }
            let tokenEnd = token.location + token.length
            guard tokenEnd > token.location else { continue }

            SyntaxHighlighter.forEachOverlappingSourceLine(
                lineStarts: lineStarts,
                tokenStart: token.location,
                tokenEnd: tokenEnd,
                lineLengthAt: { lineInfos[lines[$0].lineIndex].codeLen },
                body: { lineIdx, overlapStart, overlapEnd in
                    let mapped = lines[lineIdx]
                    let info = lineInfos[mapped.lineIndex]
                    let range = NSRange(
                        location: info.codeStart + overlapStart - mapped.start,
                        length: overlapEnd - overlapStart
                    )
                    guard range.location >= 0, NSMaxRange(range) <= nsLength else { return }
                    result.addAttribute(.foregroundColor, value: color, range: range)
                }
            )
        }
    }

    private static func displayedLineNumber(for line: WorkspaceReviewDiffLine) -> Int? {
        switch line.kind {
        case .context:
            line.newLine ?? line.oldLine
        case .removed:
            line.oldLine
        case .added:
            line.newLine
        }
    }

    private static func unchangedLineGap(
        from previous: WorkspaceReviewDiffHunk,
        to next: WorkspaceReviewDiffHunk
    ) -> Int? {
        let previousStart = previous.newStart > 0 ? previous.newStart : previous.oldStart
        let previousCount = previous.newCount > 0 ? previous.newCount : previous.oldCount
        let nextStart = next.newStart > 0 ? next.newStart : next.oldStart
        guard previousStart > 0, previousCount > 0, nextStart > 0 else { return nil }
        let previousEnd = previousStart + previousCount - 1
        return max(0, nextStart - previousEnd - 1)
    }

    /// Pad a number to the given digit width. Uses a fixed padding table
    /// to avoid String(repeating:) allocation.
    private static let padStrings = (0...10).map { String(repeating: " ", count: $0) }

    private static func paddedNumber(_ n: Int, digits: Int) -> String {
        let s = String(n)
        let padding = digits - s.count
        guard padding > 0 else { return s }
        return (padding < padStrings.count ? padStrings[padding] : String(repeating: " ", count: padding)) + s
    }
}
