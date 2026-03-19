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

        nonisolated(unsafe) private static var cached: Self?

        static func current() -> Self {
            if let cached { return cached }
            let codeFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let headerFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            let gutterFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            let lineNumFont = UIFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

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
                gutterAddedAttrs: [.font: gutterFont, .foregroundColor: addedAccent, .paragraphStyle: paragraph],
                gutterRemovedAttrs: [.font: gutterFont, .foregroundColor: removedAccent, .paragraphStyle: paragraph],
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
                syntaxColorArray: syntaxColorArray
            )
            cached = attrs
            return attrs
        }

        static func resetCache() { cached = nil }
    }

    /// Invalidate cached style colors. Call when the theme changes.
    static func resetCachedAttrs() {
        StyleAttrs.resetCache()
    }

    /// Per-line metadata tracked during assembly.
    private struct LineInfo {
        let rowStart: Int
        let rowEnd: Int
        let codeStart: Int
        let codeLen: Int
        let kind: WorkspaceReviewDiffLine.Kind
        let spans: [WorkspaceReviewDiffSpan]?
    }

    // MARK: - Build

    static func build(hunks: [WorkspaceReviewDiffHunk], filePath: String) -> NSAttributedString {
        let ext = (filePath as NSString).pathExtension
        let language = ext.isEmpty ? SyntaxLanguage.unknown : SyntaxLanguage.detect(ext)
        let style = StyleAttrs.current()

        // --- Compute max line number for gutter width ---
        var maxLineNum = 1
        var totalLines = 0
        for hunk in hunks {
            totalLines += hunk.lines.count
            for line in hunk.lines {
                if let n = line.oldLine { maxLineNum = max(maxLineNum, n) }
                if let n = line.newLine { maxLineNum = max(maxLineNum, n) }
            }
        }
        let numDigits = max(3, String(maxLineNum).count)
        let blankNum = String(repeating: " ", count: numDigits)

        // Pre-compute padded number strings (avoid per-line String allocation)
        var paddedNums = [String](repeating: "", count: maxLineNum + 1)
        for i in 1...maxLineNum {
            paddedNums[i] = paddedNumber(i, digits: numDigits)
        }

        // --- Batch syntax scan (build [Character] directly, skip String→Array conversion) ---
        var allTokens: [SyntaxHighlighter.TokenRange] = []
        var batchCharOffsets: [Int] = []

        if language != .unknown {
            var batchChars: [Character] = []
            batchChars.reserveCapacity(totalLines * 60)
            batchCharOffsets.reserveCapacity(totalLines)

            for hunk in hunks {
                for line in hunk.lines {
                    if !batchChars.isEmpty {
                        batchChars.append("\n")
                    }
                    batchCharOffsets.append(batchChars.count)
                    let codeText = line.text.isEmpty ? " " : line.text
                    batchChars.append(contentsOf: codeText)
                }
            }

            allTokens = SyntaxHighlighter.scanTokenRanges(characters: batchChars, language: language)
        }

        // --- Phase 1: Build string via appends with correct per-segment attributes ---
        // Each append gets its final font/foreground color, eliminating the need
        // for Phase 4's 1300+ addAttribute overrides.
        let result = NSMutableAttributedString()
        var lineInfos: [LineInfo] = []
        lineInfos.reserveCapacity(totalLines)

        // Pre-build shared immutable NSAttributedStrings for gutter/newline.
        // Three variants per element: context (plain), added (with bg), removed (with bg).
        let gutterContext = NSAttributedString(string: "   ", attributes: style.gutterContextAttrs)
        let gutterAdded = NSAttributedString(string: "▎+ ", attributes: style.gutterAddedAttrs)
        let gutterRemoved = NSAttributedString(string: "▎− ", attributes: style.gutterRemovedAttrs)
        let newlineContext = NSAttributedString(string: "\n", attributes: style.codeDimAttrs)
        let newlineDefault = NSAttributedString(string: "\n", attributes: style.codeDefaultAttrs)

        // Pre-compute line number NSAttributedStrings.
        // Three arrays: plain, added-bg, removed-bg. Index 0 = blank.
        func buildNumAttrs(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString] {
            var arr: [NSAttributedString] = []
            arr.reserveCapacity(maxLineNum + 1)
            arr.append(NSAttributedString(string: "\(blankNum) ", attributes: attrs))
            for i in 1...maxLineNum {
                arr.append(NSAttributedString(string: "\(paddedNums[i]) ", attributes: attrs))
            }
            return arr
        }
        let numPlain = buildNumAttrs(style.lineNumAttrs)
        let numAdded = buildNumAttrs(style.lineNumAddedAttrs)
        let numRemoved = buildNumAttrs(style.lineNumRemovedAttrs)

        result.beginEditing()

        for (hunkIndex, hunk) in hunks.enumerated() {
            if hunkIndex > 0 {
                result.append(newlineDefault)
            }
            result.append(NSAttributedString(string: " \(hunk.headerText) \n", attributes: style.headerAttrs))

            for line in hunk.lines {
                let rowStart = result.length

                // Gutter, line numbers, code, newline — all with bg baked in for added/removed.
                // This eliminates the Phase 2 row-level addAttributes calls.
                let nums: [NSAttributedString]
                let codeAttrs: [NSAttributedString.Key: Any]

                switch line.kind {
                case .added:
                    result.append(gutterAdded)
                    nums = numAdded
                    codeAttrs = style.codeAddedAttrs
                case .removed:
                    result.append(gutterRemoved)
                    nums = numRemoved
                    codeAttrs = style.codeRemovedAttrs
                case .context:
                    result.append(gutterContext)
                    nums = numPlain
                    codeAttrs = style.codeDimAttrs
                }

                result.append(nums[line.oldLine ?? 0])
                result.append(nums[line.newLine ?? 0])

                // Code text
                let codeStart = result.length
                let codeText = line.text.isEmpty ? " " : line.text
                result.mutableString.append(codeText)
                let codeLen = result.length - codeStart
                result.setAttributes(codeAttrs, range: NSRange(location: codeStart, length: codeLen))

                // Newline
                result.append(line.kind == .context ? newlineContext : newlineDefault)
                let rowEnd = result.length

                lineInfos.append(LineInfo(
                    rowStart: rowStart,
                    rowEnd: rowEnd,
                    codeStart: codeStart,
                    codeLen: codeLen,
                    kind: line.kind,
                    spans: line.spans
                ))
            }
        }

        // --- Phase 2: Word-level span backgrounds only ---
        // Row-level backgrounds are now baked into the append-phase attributes above.
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

        // --- Phase 3: Syntax highlighting ---
        if !allTokens.isEmpty {
            let colorArray = style.syntaxColorArray
            var lineIdx = 0
            let lineCount = lineInfos.count
            for token in allTokens {
                guard let color = colorArray[Int(token.kind.rawValue)] else { continue }

                while lineIdx + 1 < lineCount,
                      batchCharOffsets[lineIdx + 1] <= token.location {
                    lineIdx += 1
                }

                let offsetInLine = token.location - batchCharOffsets[lineIdx]
                result.addAttribute(
                    .foregroundColor, value: color,
                    range: NSRange(location: lineInfos[lineIdx].codeStart + offsetInLine, length: token.length)
                )
            }
        }

        // --- Phase 4: Word-level foreground override ---
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

import SwiftUI

extension String {
    func leftPadded(toWidth width: Int) -> String {
        let padding = width - count
        return padding > 0 ? String(repeating: " ", count: padding) + self : self
    }
}
