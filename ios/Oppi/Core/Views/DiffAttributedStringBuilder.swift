import UIKit

/// Attribute key for tagging diff line kind (added/removed/header) for full-width background rendering.
let diffLineKindAttributeKey = NSAttributedString.Key("unifiedDiffLineKind")

/// Attribute key embedding line metadata for tap-to-annotate.
/// Value is a `DiffLineTapInfo` struct.
let diffLineTapInfoKey = NSAttributedString.Key("diffLineTapInfo")

/// Metadata attached to each diff line's character range for tap detection.
struct DiffLineTapInfo: Sendable {
    let newLine: Int?
    let oldLine: Int?
    let side: AnnotationSide

    /// The primary line number for annotation anchoring.
    var anchorLine: Int? { newLine ?? oldLine }
}

/// Builds the attributed string for a unified diff from structured hunks.
///
/// Uses a fused two-phase approach:
/// 1. Build the entire text as NSMutableString, tracking per-line offsets
/// 2. Create NSMutableAttributedString once, apply all attributes by range
///
/// This avoids thousands of intermediate NSAttributedString allocations that
/// the previous per-line append approach created.
enum DiffAttributedStringBuilder {

    /// Per-line metadata tracked during text assembly (phase 1).
    private struct LineInfo {
        let rowStart: Int       // UTF-16 offset of the row start (gutter prefix)
        let gutterStart: Int    // UTF-16 offset of the gutter prefix
        let gutterLen: Int      // UTF-16 length of the gutter prefix
        let lineNumStart: Int   // UTF-16 offset of the line number section
        let lineNumLen: Int     // UTF-16 length of the line number section
        let codeStart: Int      // UTF-16 offset of the code text
        let codeCharOffset: Int // Character offset of code text in the original line.text
        let codeLen: Int        // UTF-16 length of the code text
        let rowEnd: Int         // UTF-16 offset past the trailing newline
        let kind: WorkspaceReviewDiffLine.Kind
        let hasSpans: Bool
        let spans: [WorkspaceReviewDiffSpan]?
        let oldLine: Int?
        let newLine: Int?
    }

    /// Per-hunk header metadata.
    private struct HeaderInfo {
        let start: Int
        let length: Int
    }

    static func build(hunks: [WorkspaceReviewDiffHunk], filePath: String) -> NSAttributedString {
        let ext = (filePath as NSString).pathExtension
        let language = ext.isEmpty ? SyntaxLanguage.unknown : SyntaxLanguage.detect(ext)

        // --- Resolve colors once ---
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
        let lineNumSectionLen = numDigits + 1 + numDigits + 1 // "oldNum newNum "

        // --- Phase 1: Build full text as NSMutableString, track offsets ---

        // Estimate capacity: ~80 chars per line
        let text = NSMutableString(capacity: totalLines * 80)
        var lineInfos: [LineInfo] = []
        lineInfos.reserveCapacity(totalLines)
        var headerInfos: [HeaderInfo] = []

        // Build batched code text for single-pass syntax scan (Phase 5)
        let batchCode: NSMutableString? = language != .unknown
            ? NSMutableString(capacity: totalLines * 60) : nil
        var batchCharOffsets: [Int] = []
        if language != .unknown { batchCharOffsets.reserveCapacity(totalLines) }
        var batchCharPos = 0

        for (hunkIndex, hunk) in hunks.enumerated() {
            if hunkIndex > 0 {
                text.append("\n")
            }

            let headerStart = text.length
            let headerStr = " \(hunk.headerText) \n"
            text.append(headerStr)
            headerInfos.append(HeaderInfo(start: headerStart, length: headerStr.utf16.count))

            for line in hunk.lines {
                let rowStart = text.length

                // Gutter prefix
                let gutterStart = text.length
                let gutterStr: String
                switch line.kind {
                case .added:   gutterStr = "▎+ "
                case .removed: gutterStr = "▎− "
                case .context: gutterStr = "   "
                }
                text.append(gutterStr)
                let gutterLen = text.length - gutterStart

                // Line numbers
                let lineNumStart = text.length
                let oldNum = line.oldLine.map { paddedNumber($0, digits: numDigits) }
                    ?? String(repeating: " ", count: numDigits)
                let newNum = line.newLine.map { paddedNumber($0, digits: numDigits) }
                    ?? String(repeating: " ", count: numDigits)
                text.append(oldNum)
                text.append(" ")
                text.append(newNum)
                text.append(" ")

                // Code text
                let codeStart = text.length
                let codeText = line.text.isEmpty ? " " : line.text
                text.append(codeText)
                let codeLen = text.length - codeStart

                // Accumulate code text for batched syntax scan
                if let bc = batchCode {
                    if batchCharPos > 0 {
                        bc.append("\n")
                        batchCharPos += 1
                    }
                    batchCharOffsets.append(batchCharPos)
                    bc.append(codeText)
                    batchCharPos += codeText.count
                }

                // Newline
                text.append("\n")
                let rowEnd = text.length

                lineInfos.append(LineInfo(
                    rowStart: rowStart,
                    gutterStart: gutterStart,
                    gutterLen: gutterLen,
                    lineNumStart: lineNumStart,
                    lineNumLen: lineNumSectionLen,
                    codeStart: codeStart,
                    codeCharOffset: 0, // unused in current approach
                    codeLen: codeLen,
                    rowEnd: rowEnd,
                    kind: line.kind,
                    hasSpans: line.spans != nil && !(line.spans?.isEmpty ?? true),
                    spans: line.spans,
                    oldLine: line.oldLine,
                    newLine: line.newLine
                ))
            }
        }

        // --- Phase 2: Create attributed string with default code attributes ---
        let result = NSMutableAttributedString(
            string: text as String,
            attributes: [
                .font: codeFont,
                .foregroundColor: fgColor,
                .paragraphStyle: paragraph,
            ]
        )

        result.beginEditing()

        // --- Phase 3: Apply header attributes ---
        for header in headerInfos {
            let range = NSRange(location: header.start, length: header.length)
            result.addAttributes([
                .font: headerFont,
                .foregroundColor: headerColor,
                diffLineKindAttributeKey: "header",
            ], range: range)
        }

        // --- Phase 4: Apply per-line gutter, line number, and row-level attributes ---
        for info in lineInfos {
            let rowRange = NSRange(location: info.rowStart, length: info.rowEnd - info.rowStart)

            // Gutter prefix
            let gutterColor: UIColor
            switch info.kind {
            case .added:   gutterColor = addedAccent
            case .removed: gutterColor = removedAccent
            case .context: gutterColor = contextDim
            }
            result.addAttributes([
                .font: gutterFont,
                .foregroundColor: gutterColor,
            ], range: NSRange(location: info.gutterStart, length: info.gutterLen))

            // Line numbers
            result.addAttributes([
                .font: lineNumFont,
                .foregroundColor: lineNumColor,
            ], range: NSRange(location: info.lineNumStart, length: info.lineNumLen))

            // Code default foreground (context lines are dimmed)
            if info.kind == .context {
                result.addAttribute(
                    .foregroundColor,
                    value: fgDimColor,
                    range: NSRange(location: info.codeStart, length: info.codeLen + 1) // +1 for newline
                )
            }

            // Row-level background + diffLineKind
            switch info.kind {
            case .added:
                result.addAttribute(diffLineKindAttributeKey, value: "added", range: rowRange)
                result.addAttribute(.backgroundColor, value: lineAddedBg, range: rowRange)
            case .removed:
                result.addAttribute(diffLineKindAttributeKey, value: "removed", range: rowRange)
                result.addAttribute(.backgroundColor, value: lineRemovedBg, range: rowRange)
            case .context:
                break
            }

            // Word-level span backgrounds (foreground override in Phase 6)
            if info.hasSpans, let spans = info.spans {
                let wordBg: UIColor = info.kind == .removed ? wordRemovedBg : wordAddedBg
                for span in spans {
                    let length = span.end - span.start
                    guard span.start >= 0, length > 0 else { continue }
                    let spanStart = info.codeStart + span.start
                    guard spanStart + length <= info.rowEnd else { continue }
                    result.addAttribute(
                        .backgroundColor,
                        value: wordBg,
                        range: NSRange(location: spanStart, length: length)
                    )
                }
            }

            // Tap metadata
            let tapSide: AnnotationSide = info.kind == .removed ? .old : .new
            let tapInfo = DiffLineTapInfo(
                newLine: info.newLine,
                oldLine: info.oldLine,
                side: tapSide
            )
            result.addAttribute(diffLineTapInfoKey, value: tapInfo, range: rowRange)
        }

        // --- Phase 5: Syntax highlighting via batched scan ---
        if language != .unknown, let bc = batchCode {
            let allTokens = SyntaxHighlighter.scanTokenRanges(bc as String, language: language)

            var lineIdx = 0
            let lineCount = lineInfos.count
            for token in allTokens {
                guard let color = SyntaxHighlighter.color(for: token.kind) else { continue }

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

        // --- Phase 6: Word-level foreground override ---
        // Must run after syntax highlighting (Phase 5) so we override
        // whatever foreground the highlighter assigned. Without this,
        // dark syntax colors (e.g. Nord comments at #4c566a) become
        // invisible on the green/red word-level highlight backgrounds.
        for info in lineInfos {
            guard info.hasSpans, let spans = info.spans else { continue }
            for span in spans {
                let length = span.end - span.start
                guard span.start >= 0, length > 0 else { continue }
                let spanStart = info.codeStart + span.start
                guard spanStart + length <= info.rowEnd else { continue }
                result.addAttribute(
                    .foregroundColor,
                    value: fgColor,
                    range: NSRange(location: spanStart, length: length)
                )
            }
        }

        result.endEditing()
        return result
    }

    /// Pad a number to the given digit width without String(format:).
    private static func paddedNumber(_ n: Int, digits: Int) -> String {
        let s = String(n)
        let padding = digits - s.count
        return padding > 0 ? String(repeating: " ", count: padding) + s : s
    }
}

import SwiftUI

extension String {
    func leftPadded(toWidth width: Int) -> String {
        let padding = width - count
        return padding > 0 ? String(repeating: " ", count: padding) + self : self
    }
}
