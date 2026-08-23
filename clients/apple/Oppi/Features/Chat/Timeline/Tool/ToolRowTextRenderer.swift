import SwiftUI
import UIKit

/// Pure-function text rendering for tool row content.
///
/// Extracted from `ToolTimelineRowContentView` — all methods are static/pure
/// with no UIKit view dependencies, making them independently testable.
enum ToolRowTextRenderer {
    // MARK: - Constants

    static let maxANSIHighlightBytes = 64 * 1024
    static let maxSyntaxHighlightBytes = 64 * 1024
    // periphery:ignore - used by ToolRowTextRendererTests via @testable import
    static let maxRenderedCommandCharacters = 6_000
    // periphery:ignore - used by ToolRowTextRendererTests via @testable import
    static let maxRenderedOutputCharacters = 2_000
    static let maxShellHighlightBytes = 64 * 1024

    // MARK: - Types

    struct ANSIOutputPresentation {
        let attributedText: NSAttributedString?
        let plainText: String?
    }

    // MARK: - ANSI / Syntax Output

    static func makeANSIOutputPresentation(
        _ text: String,
        isError: Bool,
        maxHighlightBytes: Int = maxANSIHighlightBytes
    ) -> ANSIOutputPresentation {
        if text.utf8.count <= maxHighlightBytes {
            return ANSIOutputPresentation(
                attributedText: ansiHighlighted(
                    text,
                    baseForeground: isError ? .themeRed : .themeFg
                ),
                plainText: nil
            )
        }

        return ANSIOutputPresentation(
            attributedText: nil,
            plainText: ANSIParser.strip(text)
        )
    }

    static func makeSyntaxOutputPresentation(
        _ text: String,
        language: SyntaxLanguage,
        maxHighlightBytes: Int = maxSyntaxHighlightBytes
    ) -> ANSIOutputPresentation {
        guard language != .unknown else {
            return ANSIOutputPresentation(attributedText: nil, plainText: text)
        }

        guard text.utf8.count <= maxHighlightBytes else {
            return ANSIOutputPresentation(attributedText: nil, plainText: text)
        }

        return ANSIOutputPresentation(
            attributedText: withMonospaceFont(
                SyntaxHighlighter.highlight(text, language: language),
                font: ToolFont.regular
            ),
            plainText: nil
        )
    }

    @MainActor
    static func applyANSIOutputPresentation(
        _ presentation: ANSIOutputPresentation,
        to textView: UITextView,
        plainTextColor: UIColor
    ) {
        if let attributed = presentation.attributedText {
            textView.attributedText = attributed
            return
        }

        textView.attributedText = nil
        textView.text = presentation.plainText
        textView.textColor = plainTextColor
    }

    // MARK: - Markdown

    // periphery:ignore - used by ToolRowTextRendererTests via @testable import
    static func makeMarkdownAttributedText(_ text: String) -> NSAttributedString {
        let markdownOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        let rendered: NSMutableAttributedString
        if let markdown = try? AttributedString(markdown: text, options: markdownOptions) {
            rendered = NSMutableAttributedString(attributedString: NSAttributedString(markdown))
        } else {
            rendered = NSMutableAttributedString(string: text)
        }

        let fullRange = NSRange(location: 0, length: rendered.length)
        guard fullRange.length > 0 else { return rendered }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.lineBreakMode = .byWordWrapping

        rendered.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        rendered.addAttribute(.foregroundColor, value: UIColor(Color.themeFg), range: fullRange)
        AttributedStringNormalizer.ensureFont(
            in: rendered,
            fallback: AppFont.monoMedium
        )

        return rendered
    }

    // MARK: - Code

    static func makeCodeAttributedText(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int
    ) -> NSAttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let safeStartLine = max(1, startLine)
        let lastLineNumber = safeStartLine + max(0, lines.count - 1)
        let numberDigits = max(2, String(lastLineNumber).count)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 1

        let lineNumberColor = UIColor(Color.themeComment.opacity(0.55))
        let separatorColor = UIColor(Color.themeComment.opacity(0.35))
        let foregroundColor = UIColor(Color.themeFg)
        let codeFont = ToolFont.regular
        let lineNumberFont = ToolFont.small

        // Phase 1: Build the full guttered text using NSMutableString (avoids
        // Swift String += copy-on-write overhead). Track per-line offsets manually
        // instead of calling .utf16.count (which is O(n) per call on Swift String).
        let separatorStr: NSString = "│ "
        let sepLen = separatorStr.length // UTF-16 length
        let lineNumLen = numberDigits + 1 // digits + trailing space

        let nsText = NSMutableString(capacity: text.utf16.count + lines.count * (lineNumLen + sepLen + 1))

        let lineCount = lines.count
        var codeStartOffsets = [Int](repeating: 0, count: lineCount)
        var codeCharOffsets = [Int](repeating: 0, count: lineCount)
        var lineNumStarts = [Int](repeating: 0, count: lineCount)
        var sepStarts = [Int](repeating: 0, count: lineCount)

        var utf16Pos = 0
        var origCharOffset = 0

        for index in 0..<lineCount {
            let rawLine = lines[index]
            let lineNumber = safeStartLine + index
            let lineNumStr = paddedLineNumber(lineNumber, digits: numberDigits) + " "

            lineNumStarts[index] = utf16Pos
            nsText.append(lineNumStr)
            utf16Pos += lineNumLen

            sepStarts[index] = utf16Pos
            nsText.append(separatorStr as String)
            utf16Pos += sepLen

            codeStartOffsets[index] = utf16Pos
            codeCharOffsets[index] = origCharOffset

            if rawLine.isEmpty {
                nsText.append(" ")
                utf16Pos += 1
            } else {
                nsText.append(String(rawLine))
                utf16Pos += rawLine.utf16.count
            }

            origCharOffset += rawLine.count + 1

            if index < lineCount - 1 {
                nsText.append("\n")
                utf16Pos += 1
            }
        }

        // Phase 2: Create attributed string with default code attributes.
        let result = NSMutableAttributedString(
            string: nsText as String,
            attributes: [
                .font: codeFont,
                .foregroundColor: foregroundColor,
                .paragraphStyle: paragraph,
            ]
        )

        // Phase 3+4: Apply all attribute overrides in a single editing batch.
        // beginEditing/endEditing defers internal attribute-run fixup.
        result.beginEditing()

        for i in 0..<lineCount {
            result.addAttributes(
                [.font: lineNumberFont, .foregroundColor: lineNumberColor],
                range: NSRange(location: lineNumStarts[i], length: lineNumLen)
            )
            result.addAttribute(
                .foregroundColor,
                value: separatorColor,
                range: NSRange(location: sepStarts[i], length: sepLen)
            )
        }

        // Apply syntax highlight colors using precomputed offset table.
        if let language, language != .unknown {
            let tokenRanges = SyntaxHighlighter.scanTokenRanges(text, language: language)

            // Map each token from original-text space to guttered-text space.
            // Both tokenRanges and codeCharOffsets are sorted by offset, so we
            // advance lineIdx forward in O(tokens + lines) total.
            var lineIdx = 0
            let lineCount = codeCharOffsets.count

            for token in tokenRanges {
                guard let color = SyntaxHighlighter.color(for: token.kind) else { continue }

                // Advance lineIdx until we find the line containing this token.
                while lineIdx + 1 < lineCount,
                      codeCharOffsets[lineIdx + 1] <= token.location {
                    lineIdx += 1
                }

                let offsetInLine = token.location - codeCharOffsets[lineIdx]
                guard offsetInLine >= 0 else { continue }

                let gutterPos = codeStartOffsets[lineIdx] + offsetInLine

                // Clamp token length to stay within this line's code area.
                // Prevents cross-line scanner bugs from coloring the next
                // line's gutter (line number + separator).
                let lineCodeLen = lines[lineIdx].count
                let clampedLen = min(token.length, lineCodeLen - offsetInLine)
                guard clampedLen > 0 else { continue }

                result.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: NSRange(location: gutterPos, length: clampedLen)
                )
            }
        }

        result.endEditing()
        return result
    }

    // MARK: - Helpers

    static func paddedLineNumber(_ number: Int?, digits: Int) -> String {
        guard let number else {
            return String(repeating: " ", count: digits)
        }

        // Manual padding: avoids String(format:) C sprintf overhead per call.
        let numStr = String(number)
        let padding = digits - numStr.count
        if padding <= 0 { return numStr }
        return String(repeating: " ", count: padding) + numStr
    }

    static func diffLanguage(for filePath: String?) -> SyntaxLanguage? {
        guard let filePath, !filePath.isEmpty else { return nil }

        switch FileType.detect(from: filePath) {
        case .code(let language):
            return language
        case .json:
            return .json
        case .html:
            return .html
        case .latex: return .latex
        case .orgMode: return .orgMode
        case .mermaid: return .mermaid
        case .graphviz: return .dot
        case .plain, .markdown, .image, .audio, .video, .pdf, .binary:
            return nil
        }
    }

    private static func withMonospaceFont(
        _ attributed: NSAttributedString,
        font: UIFont
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return mutable }
        mutable.addAttribute(.font, value: font, range: fullRange)
        return mutable
    }

    // MARK: - Shell / ANSI

    static func shellHighlighted(_ text: String) -> NSAttributedString {
        withMonospaceFont(
            SyntaxHighlighter.highlight(text, language: .shell),
            font: ToolFont.regular
        )
    }

    /// Highlight a bash command with language-aware embedded code detection.
    ///
    /// When the command contains a heredoc (`node - <<'NODE' ...`) or inline
    /// script flag (`python3 -c '...'`), the embedded code body receives
    /// language-specific syntax highlighting while the shell portions keep
    /// bash highlighting. Falls back to plain shell highlighting when no
    /// embedded language is detected.
    static func bashCommandHighlighted(_ text: String) -> NSAttributedString {
        let segments = BashEmbeddedLanguageDetector.detect(text)

        // Fast path: no embedded language detected
        guard segments.count > 1 else {
            return shellHighlighted(text)
        }

        let font = ToolFont.regular
        let result = NSMutableAttributedString()

        for segment in segments {
            switch segment.kind {
            case .shell:
                result.append(withMonospaceFont(
                    SyntaxHighlighter.highlight(segment.text, language: .shell),
                    font: font
                ))
            case .embeddedCode(let language):
                result.append(withMonospaceFont(
                    SyntaxHighlighter.highlight(segment.text, language: language),
                    font: font
                ))
            }
        }

        return result
    }

    static func ansiHighlighted(
        _ text: String,
        baseForeground: Color = .themeFg
    ) -> NSAttributedString {
        ANSIParser.attributedString(from: text, baseForeground: baseForeground)
    }

    // MARK: - Title

    static func styledTitle(
        title: String,
        toolNamePrefix: String?,
        toolNameColor: UIColor
    ) -> NSAttributedString {
        let base = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: ToolFont.title,
                .foregroundColor: UIColor(Color.themeFg),
            ]
        )

        guard let toolNamePrefix,
              !toolNamePrefix.isEmpty else {
            return base
        }

        let prefixLength = (toolNamePrefix as NSString).length
        guard prefixLength > 0 else { return base }

        let highlightRange: NSRange?
        if title.hasPrefix(toolNamePrefix) {
            highlightRange = NSRange(location: 0, length: prefixLength)
        } else {
            let nsTitle = title as NSString
            let spacedPrefix = "\(toolNamePrefix) "
            let range = nsTitle.range(of: spacedPrefix)
            highlightRange = range.location == NSNotFound
                ? nil
                : NSRange(location: range.location, length: prefixLength)
        }

        if let highlightRange {
            base.addAttribute(.foregroundColor, value: toolNameColor, range: highlightRange)
        }

        return base
    }

    // MARK: - Display Text Truncation

    // periphery:ignore - used by ToolRowTextRendererTests via @testable import
    static func truncatedDisplayText(_ text: String, maxCharacters: Int, note: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + note
    }

    static func displayCommandText(_ text: String) -> String {
        text
    }

    static func displayOutputText(_ text: String) -> String {
        text
    }
}
