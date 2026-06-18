import SwiftUI
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

        nonisolated(unsafe) private static var cached: Self?
        nonisolated(unsafe) private static var cachedThemeID: ThemeID?

        static func current() -> Self {
            let currentTheme = ThemeRuntimeState.currentThemeID()
            if let cached, cachedThemeID == currentTheme { return cached }
            let codeFont = AppFont.monoMedium
            let headerFont = AppFont.monoBold
            let gutterFont = AppFont.monoBold
            let lineNumFont = AppFont.monoSmall

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping

            let addedAccent = UIColor(Color.themeDiffAdded)
            let removedAccent = UIColor(Color.themeDiffRemoved)
            let contextDim = UIColor(Color.themeComment.opacity(0.4))
            let lineNumColor = UIColor(Color.themeComment.opacity(0.5))
            let fgColor = UIColor(Color.themeFg)
            let fgDimColor = UIColor(Color.themeFgDim)
            let headerColor = UIColor(Color.themePurple)
            let gapSummaryColor = UIColor(Color.themeFgDim)

            let lineAddedBg = UIColor(Color.themeDiffAdded.opacity(0.12))
            let lineRemovedBg = UIColor(Color.themeDiffRemoved.opacity(0.10))
            let wordAddedBg = UIColor(Color.themeDiffAdded.opacity(0.35))
            let wordRemovedBg = UIColor(Color.themeDiffRemoved.opacity(0.35))

            // Build direct-indexed color array (0=variable=nil, 1=comment, etc.)
            var syntaxColorArray: [UIColor?] = Array(repeating: nil, count: 9)
            for kind: SyntaxHighlighter.TokenKind in [.comment, .keyword, .string, .number, .type, .punctuation, .function, .operator] {
                syntaxColorArray[Int(kind.rawValue)] = SyntaxHighlighter.color(for: kind)
            }

            let attrs = Self(
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
            cached = attrs
            cachedThemeID = currentTheme
            return attrs
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
        let ext = (filePath as NSString).pathExtension
        let language = ext.isEmpty ? SyntaxLanguage.unknown : SyntaxLanguage.detect(ext)
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
        var batchCode = ""
        var allTokens: [SyntaxHighlighter.TokenRange] = []
        var batchUTF16Offsets: [Int] = []
        var lineInfos: [LineInfo] = []
        lineInfos.reserveCapacity(totalLines)
        var headers: [HeaderInfo] = []

        if language != .unknown {
            batchCode.reserveCapacity(totalLines * 60)
            batchUTF16Offsets.reserveCapacity(totalLines)
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

        var batchUTF16Offset = 0
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

                if language != .unknown {
                    if batchUTF16Offset > 0 {
                        batchCode.append("\n")
                        batchUTF16Offset += 1
                    }
                    batchUTF16Offsets.append(batchUTF16Offset)
                    batchCode.append(codeText)
                    batchUTF16Offset += codeText.utf16.count
                }

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
            }
        }

        if language != .unknown {
            allTokens = SyntaxHighlighter.scanTokenRangesUTF8(batchCode, language: language)
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

        if !allTokens.isEmpty {
            let colorArray = style.syntaxColorArray
            var lineIdx = 0
            let lineCount = lineInfos.count
            for token in allTokens {
                guard let color = colorArray[Int(token.kind.rawValue)] else { continue }
                let tokenEnd = token.location + token.length
                guard tokenEnd > token.location else { continue }

                while lineIdx + 1 < lineCount,
                      batchUTF16Offsets[lineIdx + 1] <= token.location {
                    lineIdx += 1
                }

                // Batch syntax tokens may span newlines (XML comments, heredocs).
                // Split them back across diff rows so syntax color never paints gutters.
                var segmentLineIdx = lineIdx
                var segmentStart = token.location
                while segmentLineIdx < lineCount, segmentStart < tokenEnd {
                    let lineStart = batchUTF16Offsets[segmentLineIdx]
                    let lineEnd = lineStart + lineInfos[segmentLineIdx].codeLen
                    if segmentStart < lineStart {
                        segmentStart = lineStart
                    }

                    if segmentStart < lineEnd {
                        let segmentEnd = min(tokenEnd, lineEnd)
                        result.addAttribute(
                            .foregroundColor,
                            value: color,
                            range: NSRange(
                                location: lineInfos[segmentLineIdx].codeStart + segmentStart - lineStart,
                                length: segmentEnd - segmentStart
                            )
                        )
                        segmentStart = segmentEnd
                    }

                    if segmentStart >= tokenEnd { break }
                    segmentLineIdx += 1
                    if segmentLineIdx < lineCount {
                        segmentStart = max(segmentStart, batchUTF16Offsets[segmentLineIdx])
                    }
                }
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
