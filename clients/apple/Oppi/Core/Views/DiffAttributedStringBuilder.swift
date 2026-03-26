import SwiftUI
import UIKit

/// Attribute key for tagging diff line kind (added/removed/header) for full-width background rendering.
let diffLineKindAttributeKey = NSAttributedString.Key("unifiedDiffLineKind")

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
                gutterAddedAttrs: [.font: gutterFont, .foregroundColor: addedAccent, .paragraphStyle: paragraph, .backgroundColor: lineAddedBg, diffLineKindAttributeKey: "added"],
                gutterRemovedAttrs: [.font: gutterFont, .foregroundColor: removedAccent, .paragraphStyle: paragraph, .backgroundColor: lineRemovedBg, diffLineKindAttributeKey: "removed"],
                gutterContextAttrs: [.font: gutterFont, .foregroundColor: contextDim, .paragraphStyle: paragraph],
                lineNumAttrs: [.font: lineNumFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph],
                lineNumAddedAttrs: [.font: lineNumFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph, .backgroundColor: lineAddedBg, diffLineKindAttributeKey: "added"],
                lineNumRemovedAttrs: [.font: lineNumFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph, .backgroundColor: lineRemovedBg, diffLineKindAttributeKey: "removed"],
                codeDefaultAttrs: [.font: codeFont, .foregroundColor: fgColor, .paragraphStyle: paragraph],
                codeDimAttrs: [.font: codeFont, .foregroundColor: fgDimColor, .paragraphStyle: paragraph],
                codeAddedAttrs: [.font: codeFont, .foregroundColor: fgColor, .paragraphStyle: paragraph, .backgroundColor: lineAddedBg, diffLineKindAttributeKey: "added"],
                codeRemovedAttrs: [.font: codeFont, .foregroundColor: fgColor, .paragraphStyle: paragraph, .backgroundColor: lineRemovedBg, diffLineKindAttributeKey: "removed"],
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
        let numStart: Int   // start of old+new line number block
        let codeStart: Int
        let codeLen: Int
        let rowEnd: Int
        let kind: WorkspaceReviewDiffLine.Kind
        let spans: [WorkspaceReviewDiffSpan]?
    }

    /// Header (hunk separator) position.
    private struct HeaderInfo {
        let start: Int
        let length: Int
    }

    /// Stats summary line segment positions.
    private struct StatsSegments {
        let fullRange: NSRange
        let addedRange: NSRange?
        let removedRange: NSRange?
        let totalRange: NSRange
    }

    // MARK: - Build

    static func build(hunks: [WorkspaceReviewDiffHunk], filePath: String, includeStats: Bool = false) -> NSAttributedString {
        let ext = (filePath as NSString).pathExtension
        let language = ext.isEmpty ? SyntaxLanguage.unknown : SyntaxLanguage.detect(ext)
        let style = StyleAttrs.current()

        // --- Compute max line number for gutter width ---
        var maxLineNum = 1
        var totalLines = 0
        var totalAdded = 0
        var totalRemoved = 0
        for hunk in hunks {
            totalLines += hunk.lines.count
            for line in hunk.lines {
                if let n = line.oldLine { maxLineNum = max(maxLineNum, n) }
                if let n = line.newLine { maxLineNum = max(maxLineNum, n) }
                switch line.kind {
                case .added: totalAdded += 1
                case .removed: totalRemoved += 1
                case .context: break
                }
            }
        }
        let numDigits = max(3, String(maxLineNum).count)

        // Pre-compute padded number strings with trailing space.
        // Index 0 = blank (for nil line numbers).
        var paddedNums = [String](repeating: "", count: maxLineNum + 1)
        paddedNums[0] = String(repeating: " ", count: numDigits) + " "
        for i in 1...maxLineNum {
            paddedNums[i] = paddedNumber(i, digits: numDigits) + " "
        }

        // --- Phase 1: Build entire text + batch syntax scan in one pass ---
        // Build all text via mutableString, simultaneously building the
        // batch code Swift String for syntax scanning. Using a Swift String
        // avoids the NSMutableString→String bridge copy at scan time.
        let text = NSMutableString()
        var batchCode = ""
        var allTokens: [SyntaxHighlighter.TokenRange] = []
        var batchOffsets: [Int] = []
        var lineInfos: [LineInfo] = []
        lineInfos.reserveCapacity(totalLines)
        var headers: [HeaderInfo] = []

        if language != .unknown {
            batchCode.reserveCapacity(totalLines * 60)
            batchOffsets.reserveCapacity(totalLines)
        }

        // --- Optional stats summary line ---
        var statsSegs: StatsSegments?
        if includeStats, totalAdded > 0 || totalRemoved > 0 {
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

        var batchByteOffset = 0
        for (hunkIndex, hunk) in hunks.enumerated() {
            if hunkIndex > 0 {
                text.append("\n")
            }
            let headerStart = text.length
            text.append(" ")
            text.append(hunk.headerText)
            text.append(" \n")
            headers.append(HeaderInfo(start: headerStart, length: text.length - headerStart))

            for line in hunk.lines {
                let gutterStart = text.length
                switch line.kind {
                case .added: text.append(" + ")
                case .removed: text.append(" - ")
                case .context: text.append("   ")
                }

                let numStart = text.length
                text.append(paddedNums[line.oldLine ?? 0])
                text.append(paddedNums[line.newLine ?? 0])

                let codeStart = text.length
                let codeText = line.text.isEmpty ? " " : line.text
                text.append(codeText)
                let codeLen = text.length - codeStart

                if language != .unknown {
                    if batchByteOffset > 0 {
                        batchCode.append("\n")
                        batchByteOffset += 1
                    }
                    batchOffsets.append(batchByteOffset)
                    batchCode.append(codeText)
                    batchByteOffset += codeText.utf8.count
                }

                text.append("\n")
                let rowEnd = text.length

                lineInfos.append(LineInfo(
                    gutterStart: gutterStart,
                    numStart: numStart,
                    codeStart: codeStart,
                    codeLen: codeLen,
                    rowEnd: rowEnd,
                    kind: line.kind,
                    spans: line.spans
                ))
            }
        }

        if language != .unknown {
            allTokens = SyntaxHighlighter.scanTokenRangesUTF8(batchCode, language: language)
        }

        // --- Phase 2: Create attributed string and apply segment attributes ---
        let result = NSMutableAttributedString(string: text as String, attributes: style.codeDefaultAttrs)
        result.beginEditing()

        // Headers
        for header in headers {
            result.setAttributes(style.headerAttrs, range: NSRange(location: header.start, length: header.length))
        }

        // Stats summary line
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

        // Per-line segments: gutter, line numbers, code
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

            result.setAttributes(gutterAttrs, range: NSRange(location: info.gutterStart, length: info.numStart - info.gutterStart))
            result.setAttributes(numAttrs, range: NSRange(location: info.numStart, length: info.codeStart - info.numStart))

            // Context: code + newline share the same dim attrs → one call.
            // Non-context: newline keeps default attrs (no bg leak).
            if info.kind == .context {
                result.setAttributes(codeAttrs, range: NSRange(location: info.codeStart, length: info.codeLen + 1))
            } else {
                result.setAttributes(codeAttrs, range: NSRange(location: info.codeStart, length: info.codeLen))
            }
        }

        // --- Phase 3: Word-level span backgrounds ---
        for info in lineInfos {
            guard let spans = info.spans, !spans.isEmpty else { continue }
            let wordBg = info.kind == .removed ? style.wordRemovedBg : style.wordAddedBg
            for span in spans {
                let length = span.end - span.start
                guard span.start >= 0, length > 0 else { continue }
                let spanStart = info.codeStart + span.start
                guard spanStart + length <= info.rowEnd else { continue }
                result.addAttribute(.backgroundColor, value: wordBg, range: NSRange(location: spanStart, length: length))
            }
        }

        // --- Phase 4: Syntax highlighting ---
        if !allTokens.isEmpty {
            let colorArray = style.syntaxColorArray
            var lineIdx = 0
            let lineCount = lineInfos.count
            for token in allTokens {
                guard let color = colorArray[Int(token.kind.rawValue)] else { continue }

                while lineIdx + 1 < lineCount,
                      batchOffsets[lineIdx + 1] <= token.location {
                    lineIdx += 1
                }

                let offsetInLine = token.location - batchOffsets[lineIdx]
                result.addAttribute(
                    .foregroundColor, value: color,
                    range: NSRange(location: lineInfos[lineIdx].codeStart + offsetInLine, length: token.length)
                )
            }
        }

        // --- Phase 5: Word-level foreground override ---
        let fgColor = style.fgColor
        for info in lineInfos {
            guard let spans = info.spans, !spans.isEmpty else { continue }
            for span in spans {
                let length = span.end - span.start
                guard span.start >= 0, length > 0 else { continue }
                let spanStart = info.codeStart + span.start
                guard spanStart + length <= info.rowEnd else { continue }
                result.addAttribute(.foregroundColor, value: fgColor, range: NSRange(location: spanStart, length: length))
            }
        }

        result.endEditing()
        return result
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


