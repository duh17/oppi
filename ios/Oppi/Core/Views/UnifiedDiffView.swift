import SwiftUI
import UIKit

/// Shared high-performance diff renderer used across review and history surfaces.
///
/// Renders server/local hunks with syntax highlighting, numbered lines, and
/// optional word-level spans inside a selectable `UITextView`.
struct UnifiedDiffView: View {
    let hunks: [WorkspaceReviewDiffHunk]
    let filePath: String
    var emptyTitle = "No Textual Changes"
    var emptySystemImage = "checkmark.circle"
    var emptyDescription = "This diff has no textual changes to show."

    var body: some View {
        if hunks.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: emptySystemImage,
                description: Text(emptyDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.themeBgDark)
        } else {
            UnifiedDiffTextView(hunks: hunks, filePath: filePath)
                .ignoresSafeArea(.keyboard)
        }
    }
}

/// Custom attribute key to tag diff line kind for full-width background drawing.
private let unifiedDiffLineKindKey = NSAttributedString.Key("unifiedDiffLineKind")

/// Layout manager that draws full-width backgrounds for added/removed lines.
/// `NSAttributedString.backgroundColor` only paints behind characters; this
/// extends the tint to cover the entire line fragment rect edge-to-edge.
private final class UnifiedDiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let textContainer = textContainers.first else { return }

        let addedBg = UIColor(Color.themeDiffAdded.opacity(0.18))
        let removedBg = UIColor(Color.themeDiffRemoved.opacity(0.15))
        let headerBg = UIColor(Color.themeBgHighlight)

        textStorage.enumerateAttribute(unifiedDiffLineKindKey, in: NSRange(location: 0, length: textStorage.length), options: []) { value, attrRange, _ in
            guard let kind = value as? String else { return }
            let bg: UIColor
            switch kind {
            case "added": bg = addedBg
            case "removed": bg = removedBg
            case "header": bg = headerBg
            default: return
            }

            let glyphRange = self.glyphRange(forCharacterRange: attrRange, actualCharacterRange: nil)
            self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                var fillRect = rect
                fillRect.origin.x = 0
                fillRect.size.width = textContainer.size.width
                fillRect.origin.x += origin.x
                fillRect.origin.y += origin.y
                bg.setFill()
                UIRectFillUsingBlendMode(fillRect, .normal)
            }
        }
    }
}

private struct UnifiedDiffTextView: UIViewRepresentable {
    let hunks: [WorkspaceReviewDiffHunk]
    let filePath: String

    func makeUIView(context: Context) -> UITextView {
        let textStorage = NSTextStorage()
        let layoutManager = UnifiedDiffLayoutManager()
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = UITextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.backgroundColor = UIColor(Color.themeBgDark)
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 20, right: 0)

        textStorage.setAttributedString(buildAttributedDiff())
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}

    private func buildAttributedDiff() -> NSAttributedString {
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
                    unifiedDiffLineKindKey: "header",
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

                let oldNum = line.oldLine.map { String($0).leftPadded(to: numDigits) }
                    ?? String(repeating: " ", count: numDigits)
                let newNum = line.newLine.map { String($0).leftPadded(to: numDigits) }
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

                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: codeFont, .paragraphStyle: paragraph,
                ]))

                let rowEnd = result.length
                let rowRange = NSRange(location: rowStart, length: rowEnd - rowStart)
                switch line.kind {
                case .added:
                    result.addAttribute(unifiedDiffLineKindKey, value: "added", range: rowRange)
                case .removed:
                    result.addAttribute(unifiedDiffLineKindKey, value: "removed", range: rowRange)
                case .context:
                    break
                }
            }
        }

        return result
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        let padding = width - count
        return padding > 0 ? String(repeating: " ", count: padding) + self : self
    }
}
