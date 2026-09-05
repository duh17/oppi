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
        let gutterAddedAttrs: [NSAttributedString.Key: Any]
        let gutterRemovedAttrs: [NSAttributedString.Key: Any]
        let gutterContextAttrs: [NSAttributedString.Key: Any]
        let lineNumAttrs: [NSAttributedString.Key: Any]
        let lineNumAddedAttrs: [NSAttributedString.Key: Any]
        let lineNumRemovedAttrs: [NSAttributedString.Key: Any]
        let codeDefaultAttrs: [NSAttributedString.Key: Any]
        let codeDimAttrs: [NSAttributedString.Key: Any]
        let codeAddedAttrs: [NSAttributedString.Key: Any]
        let codeRemovedAttrs: [NSAttributedString.Key: Any]

        let fgColor: UIColor
        let wordAddedBg: UIColor
        let wordRemovedBg: UIColor

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

            // Build direct-indexed color array (0=variable=nil, 1=comment, etc.)
            var syntaxColorArray: [UIColor?] = Array(repeating: nil, count: 9)
            syntaxColorArray[Int(SyntaxHighlighter.TokenKind.comment.rawValue)] = UIColor(palette.syntaxComment)
            syntaxColorArray[Int(SyntaxHighlighter.TokenKind.keyword.rawValue)] = UIColor(palette.syntaxKeyword)
            syntaxColorArray[Int(SyntaxHighlighter.TokenKind.string.rawValue)] = UIColor(palette.syntaxString)
            syntaxColorArray[Int(SyntaxHighlighter.TokenKind.number.rawValue)] = UIColor(palette.syntaxNumber)
            syntaxColorArray[Int(SyntaxHighlighter.TokenKind.type.rawValue)] = UIColor(palette.syntaxType)
            syntaxColorArray[Int(SyntaxHighlighter.TokenKind.punctuation.rawValue)] = UIColor(palette.syntaxPunctuation)
            syntaxColorArray[Int(SyntaxHighlighter.TokenKind.function.rawValue)] = UIColor(palette.syntaxFunction)
            syntaxColorArray[Int(SyntaxHighlighter.TokenKind.operator.rawValue)] = UIColor(palette.syntaxOperator)

            return Self(
                codeFont: codeFont,
                paragraph: paragraph,
                headerAttrs: [.font: headerFont, .foregroundColor: headerColor, .paragraphStyle: paragraph, diffLineKindAttributeKey: "header"],
                sectionHeaderBlockAttrs: [.paragraphStyle: paragraph, diffLineKindAttributeKey: "header"],
                gapSummaryAttrs: [.font: AppFont.systemSmall, .foregroundColor: gapSummaryColor, .paragraphStyle: paragraph],
                gutterAddedAttrs: [.font: gutterFont, .foregroundColor: addedAccent, .paragraphStyle: paragraph, .backgroundColor: lineAddedBg, diffLineKindAttributeKey: "added"],
                gutterRemovedAttrs: [.font: gutterFont, .foregroundColor: removedAccent, .paragraphStyle: paragraph, .backgroundColor: lineRemovedBg, diffLineKindAttributeKey: "removed"],
                gutterContextAttrs: [.font: gutterFont, .foregroundColor: contextDim, .paragraphStyle: paragraph],
                lineNumAttrs: [.font: lineNumFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph],
                lineNumAddedAttrs: [.font: lineNumFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph, .backgroundColor: lineAddedBg, diffLineKindAttributeKey: "added"],
                lineNumRemovedAttrs: [.font: lineNumFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph, .backgroundColor: lineRemovedBg, diffLineKindAttributeKey: "removed"],
                codeDefaultAttrs: [.font: codeFont, .foregroundColor: fgColor, .paragraphStyle: paragraph],
                codeDimAttrs: [.font: codeFont, .foregroundColor: fgDimColor, .paragraphStyle: paragraph, diffCodeColumnAttributeKey: true],
                codeAddedAttrs: [.font: codeFont, .foregroundColor: fgColor, .paragraphStyle: paragraph, .backgroundColor: lineAddedBg, diffLineKindAttributeKey: "added", diffCodeColumnAttributeKey: true],
                codeRemovedAttrs: [.font: codeFont, .foregroundColor: fgColor, .paragraphStyle: paragraph, .backgroundColor: lineRemovedBg, diffLineKindAttributeKey: "removed", diffCodeColumnAttributeKey: true],
                fgColor: fgColor,
                wordAddedBg: wordAddedBg,
                wordRemovedBg: wordRemovedBg,
                syntaxColorArray: syntaxColorArray,
                addedAccentColor: addedAccent,
                removedAccentColor: removedAccent,
                commentDimColor: lineNumColor
            )
        }

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

    struct Options {
        var includeStats = false
        var includeGapSummary = true
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

        for info in lineInfos {
            let gutterAttrs: [NSAttributedString.Key: Any]
            let numAttrs: [NSAttributedString.Key: Any]
            let codeAttrs: [NSAttributedString.Key: Any]

            switch info.kind {
            case .added:
                gutterAttrs = style.gutterAddedAttrs
                numAttrs = style.lineNumAddedAttrs
                codeAttrs = style.codeAddedAttrs
            case .removed:
                gutterAttrs = style.gutterRemovedAttrs
                numAttrs = style.lineNumRemovedAttrs
                codeAttrs = style.codeRemovedAttrs
            case .context:
                gutterAttrs = style.gutterContextAttrs
                numAttrs = style.lineNumAttrs
                codeAttrs = style.codeDimAttrs
            }

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
            let wordBg = info.kind == .removed ? style.wordRemovedBg : style.wordAddedBg
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
                let oldTokens = SyntaxHighlighter.scanTokenRangesUTF8(projection.oldCode, language: language)
                let newTokens = SyntaxHighlighter.scanTokenRangesUTF8(projection.newCode, language: language)
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
                lineLengthAt: { lineInfos[lines[$0].lineIndex].codeLen }
            ) { lineIdx, overlapStart, overlapEnd in
                let mapped = lines[lineIdx]
                let info = lineInfos[mapped.lineIndex]
                let range = NSRange(
                    location: info.codeStart + overlapStart - mapped.start,
                    length: overlapEnd - overlapStart
                )
                guard range.location >= 0, NSMaxRange(range) <= nsLength else { return }
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
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
