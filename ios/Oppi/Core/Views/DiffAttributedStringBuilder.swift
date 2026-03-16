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
/// Shared by `UnifiedDiffTextView` (full diff) and `UnifiedDiffTextSegment`
/// (annotation-split segments) to ensure consistent rendering.
enum DiffAttributedStringBuilder {

    static func build(hunks: [WorkspaceReviewDiffHunk], filePath: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let ext = (filePath as NSString).pathExtension
        let language = ext.isEmpty ? SyntaxLanguage.unknown : SyntaxLanguage.detect(ext)

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

        var maxLineNum = 1
        for hunk in hunks {
            for line in hunk.lines {
                if let n = line.oldLine { maxLineNum = max(maxLineNum, n) }
                if let n = line.newLine { maxLineNum = max(maxLineNum, n) }
            }
        }
        let numDigits = max(3, String(maxLineNum).count)

        for (hunkIndex, hunk) in hunks.enumerated() {
            if hunkIndex > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: codeFont, .paragraphStyle: paragraph,
                ]))
            }

            result.append(NSAttributedString(
                string: " \(hunk.headerText) \n",
                attributes: [
                    .font: headerFont,
                    .foregroundColor: headerColor,
                    .paragraphStyle: paragraph,
                    diffLineKindAttributeKey: "header",
                ]
            ))

            for line in hunk.lines {
                let rowStart = result.length

                switch line.kind {
                case .added:
                    result.append(NSAttributedString(string: "▎+ ", attributes: [
                        .font: gutterFont, .foregroundColor: addedAccent, .paragraphStyle: paragraph,
                    ]))
                case .removed:
                    result.append(NSAttributedString(string: "▎− ", attributes: [
                        .font: gutterFont, .foregroundColor: removedAccent, .paragraphStyle: paragraph,
                    ]))
                case .context:
                    result.append(NSAttributedString(string: "   ", attributes: [
                        .font: gutterFont, .foregroundColor: contextDim, .paragraphStyle: paragraph,
                    ]))
                }

                let oldNum = line.oldLine.map { String($0).leftPadded(toWidth: numDigits) }
                    ?? String(repeating: " ", count: numDigits)
                let newNum = line.newLine.map { String($0).leftPadded(toWidth: numDigits) }
                    ?? String(repeating: " ", count: numDigits)
                result.append(NSAttributedString(
                    string: "\(oldNum) \(newNum) ",
                    attributes: [
                        .font: lineNumFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph,
                    ]
                ))

                let codeText = line.text.isEmpty ? " " : line.text
                let codeStart = result.length

                if language != .unknown {
                    let highlighted = NSMutableAttributedString(
                        attributedString: SyntaxHighlighter.highlightLine(codeText, language: language)
                    )
                    let fullRange = NSRange(location: 0, length: highlighted.length)
                    highlighted.addAttributes(
                        [.font: codeFont, .paragraphStyle: paragraph],
                        range: fullRange
                    )
                    let defaultFg: UIColor = line.kind == .context ? fgDimColor : fgColor
                    highlighted.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
                        if value == nil {
                            highlighted.addAttribute(.foregroundColor, value: defaultFg, range: range)
                        }
                    }
                    result.append(highlighted)
                } else {
                    let fg: UIColor = line.kind == .context ? fgDimColor : fgColor
                    result.append(NSAttributedString(string: codeText, attributes: [
                        .font: codeFont, .foregroundColor: fg, .paragraphStyle: paragraph,
                    ]))
                }

                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: codeFont, .paragraphStyle: paragraph,
                ]))

                let rowEnd = result.length
                let rowRange = NSRange(location: rowStart, length: rowEnd - rowStart)
                switch line.kind {
                case .added:
                    result.addAttribute(diffLineKindAttributeKey, value: "added", range: rowRange)
                    result.addAttribute(.backgroundColor, value: lineAddedBg, range: rowRange)
                case .removed:
                    result.addAttribute(diffLineKindAttributeKey, value: "removed", range: rowRange)
                    result.addAttribute(.backgroundColor, value: lineRemovedBg, range: rowRange)
                case .context:
                    break
                }

                // Word-level spans override line bg for specific changed words
                if let spans = line.spans {
                    for span in spans {
                        let length = span.end - span.start
                        guard span.start >= 0, length > 0, span.end <= codeText.utf16.count else { continue }
                        let spanRange = NSRange(location: codeStart + span.start, length: length)
                        guard spanRange.location + spanRange.length <= result.length else { continue }
                        let bg: UIColor = line.kind == .removed ? wordRemovedBg : wordAddedBg
                        result.addAttribute(.backgroundColor, value: bg, range: spanRange)
                    }
                }

                // Embed tap metadata for annotation authoring
                let tapSide: AnnotationSide = line.kind == .removed ? .old : .new
                let tapInfo = DiffLineTapInfo(
                    newLine: line.newLine,
                    oldLine: line.oldLine,
                    side: tapSide
                )
                result.addAttribute(diffLineTapInfoKey, value: tapInfo, range: rowRange)
            }
        }

        return result
    }
}

import SwiftUI

extension String {
    func leftPadded(toWidth width: Int) -> String {
        let padding = width - count
        return padding > 0 ? String(repeating: " ", count: padding) + self : self
    }
}
