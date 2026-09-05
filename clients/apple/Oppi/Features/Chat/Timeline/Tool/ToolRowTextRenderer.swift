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

    // MARK: - Code

    static func makeCodeAttributedText(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID()
    ) -> NSAttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let safeStartLine = max(1, startLine)
        let lastLineNumber = safeStartLine + max(0, lines.count - 1)
        let numberDigits = max(2, String(lastLineNumber).count)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 1

        let palette = themeID.palette
        let lineNumberColor = UIColor(palette.comment).withAlphaComponent(0.55)
        let separatorColor = UIColor(palette.comment).withAlphaComponent(0.35)
        let foregroundColor = UIColor(palette.fg)
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
        var sourceUTF16Starts = [Int](repeating: 0, count: lineCount)
        var sourceUTF16Lengths = [Int](repeating: 0, count: lineCount)
        var lineNumStarts = [Int](repeating: 0, count: lineCount)
        var sepStarts = [Int](repeating: 0, count: lineCount)

        var utf16Pos = 0
        var sourceUTF16Offset = 0

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
            sourceUTF16Starts[index] = sourceUTF16Offset
            sourceUTF16Lengths[index] = rawLine.utf16.count

            if rawLine.isEmpty {
                nsText.append(" ")
                utf16Pos += 1
            } else {
                nsText.append(String(rawLine))
                utf16Pos += rawLine.utf16.count
            }

            sourceUTF16Offset += rawLine.utf16.count + 1

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

        // Map tokens from source UTF-16 space onto guttered code columns.
        // Intersect with every overlapping source line so multiline tokens
        // color continuations, and do not assume tokens are ordered by start.
        if let language, language != .unknown {
            let tokenRanges = SyntaxHighlighter.scanTokenRanges(text, language: language)
            let nsLength = result.length

            for token in tokenRanges {
                guard let color = SyntaxHighlighter.color(for: token.kind, themeID: themeID) else { continue }
                guard token.length > 0 else { continue }
                let tokenStart = token.location
                let tokenEnd = token.location + token.length

                SyntaxHighlighter.forEachOverlappingSourceLine(
                    lineStarts: sourceUTF16Starts,
                    tokenStart: tokenStart,
                    tokenEnd: tokenEnd,
                    lineLengthAt: { sourceUTF16Lengths[$0] }
                ) { lineIdx, overlapStart, overlapEnd in
                    let range = NSRange(
                        location: codeStartOffsets[lineIdx] + (overlapStart - sourceUTF16Starts[lineIdx]),
                        length: overlapEnd - overlapStart
                    )
                    guard range.location >= 0, NSMaxRange(range) <= nsLength else { return }
                    result.addAttribute(.foregroundColor, value: color, range: range)
                }
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
        return FileType.detect(from: filePath).syntaxLanguage
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

    static func shellHighlighted(
        _ text: String,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID()
    ) -> NSAttributedString {
        withMonospaceFont(
            SyntaxHighlighter.highlight(text, language: .shell, themeID: themeID),
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
    static func bashCommandHighlighted(
        _ text: String,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID()
    ) -> NSAttributedString {
        let segments = BashEmbeddedLanguageDetector.detect(text)

        // Fast path: no embedded language detected
        guard segments.count > 1 else {
            return shellHighlighted(text, themeID: themeID)
        }

        let font = ToolFont.regular
        let result = NSMutableAttributedString()

        for segment in segments {
            switch segment.kind {
            case .shell:
                result.append(withMonospaceFont(
                    SyntaxHighlighter.highlight(segment.text, language: .shell, themeID: themeID),
                    font: font
                ))
            case .embeddedCode(let language):
                result.append(withMonospaceFont(
                    SyntaxHighlighter.highlight(segment.text, language: language, themeID: themeID),
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
