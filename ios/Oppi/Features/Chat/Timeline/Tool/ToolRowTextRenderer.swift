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
    static let maxDiffSyntaxHighlightBytes = 48 * 1024
    static let maxRenderedDiffLines = 400
    static let maxRenderedDiffLineCharacters = 800
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
            fallback: .systemFont(ofSize: 12, weight: .regular)
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
                let gutterPos = codeStartOffsets[lineIdx] + offsetInLine

                result.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: NSRange(location: gutterPos, length: token.length)
                )
            }
        }

        result.endEditing()
        return result
    }

    // MARK: - Diff

    static func makeDiffAttributedText(
        lines: [DiffLine],
        filePath: String?
    ) -> NSAttributedString {
        let window = diffRenderWindow(for: lines)
        let renderedLines = Array(window.lines)

        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 1

        let language = diffLanguage(for: filePath)
        let numberDigits = max(2, lineNumberDigits(
            for: renderedLines,
            startOldLine: window.startingOldLine,
            startNewLine: window.startingNewLine
        ))

        if renderedLines.isEmpty {
            result.append(
                NSAttributedString(
                    string: "No textual changes",
                    attributes: [
                        .font: ToolFont.regular,
                        .foregroundColor: UIColor(Color.themeComment),
                        .paragraphStyle: paragraph,
                    ]
                )
            )
            return result
        }

        // Pre-compute reusable attributes (avoids per-line dictionary allocations).
        let codeFont = ToolFont.regular
        let numFont = ToolFont.small
        let prefixFont = ToolFont.regularBold

        let addedBg = UIColor(Color.themeDiffAdded.opacity(0.20))
        let removedBg = UIColor(Color.themeDiffRemoved.opacity(0.18))
        let addedAccent = UIColor(Color.themeDiffAdded)
        let removedAccent = UIColor(Color.themeDiffRemoved)
        let contextDim = UIColor(Color.themeDiffContext.opacity(0.45))
        let lineNumColor = UIColor(Color.themeComment.opacity(0.5))
        let fgColor = UIColor(Color.themeFg)
        let fgDimColor = UIColor(Color.themeFgDim)

        let gutterAddedAttrs: [NSAttributedString.Key: Any] = [
            .font: prefixFont, .foregroundColor: addedAccent, .paragraphStyle: paragraph,
        ]
        let gutterRemovedAttrs: [NSAttributedString.Key: Any] = [
            .font: prefixFont, .foregroundColor: removedAccent, .paragraphStyle: paragraph,
        ]
        let gutterContextAttrs: [NSAttributedString.Key: Any] = [
            .font: prefixFont, .foregroundColor: contextDim, .paragraphStyle: paragraph,
        ]
        let lineNumAttrs: [NSAttributedString.Key: Any] = [
            .font: numFont, .foregroundColor: lineNumColor, .paragraphStyle: paragraph,
        ]
        let codeFgAttrs: [NSAttributedString.Key: Any] = [
            .font: codeFont, .foregroundColor: fgColor, .paragraphStyle: paragraph,
        ]
        let codeDimAttrs: [NSAttributedString.Key: Any] = [
            .font: codeFont, .foregroundColor: fgDimColor, .paragraphStyle: paragraph,
        ]
        let omissionAttrs: [NSAttributedString.Key: Any] = [
            .font: ToolFont.small,
            .foregroundColor: UIColor(Color.themeComment),
            .paragraphStyle: paragraph,
        ]

        if window.omittedAbove > 0 {
            result.append(NSAttributedString(
                string: "… \(window.omittedAbove) lines omitted above\n",
                attributes: omissionAttrs
            ))
        }

        var oldLineNumber = window.startingOldLine
        var newLineNumber = window.startingNewLine

        for (index, line) in renderedLines.enumerated() {
            let lineNumber: Int?
            switch line.kind {
            case .context:
                lineNumber = newLineNumber
                oldLineNumber += 1
                newLineNumber += 1
            case .removed:
                lineNumber = oldLineNumber
                oldLineNumber += 1
            case .added:
                lineNumber = newLineNumber
                newLineNumber += 1
            }

            let clippedText = clippedDiffLineText(line.text)

            let rowStart = result.length

            // Gutter: ▎+  ▎-  or    (space for context).
            switch line.kind {
            case .added:
                result.append(NSAttributedString(string: "▎+ ", attributes: gutterAddedAttrs))
            case .removed:
                result.append(NSAttributedString(string: "▎− ", attributes: gutterRemovedAttrs))
            case .context:
                result.append(NSAttributedString(string: "   ", attributes: gutterContextAttrs))
            }

            // Line number.
            result.append(NSAttributedString(
                string: "\(paddedLineNumber(lineNumber, digits: numberDigits)) ",
                attributes: lineNumAttrs
            ))

            // Code text.
            let displayText = clippedText.isEmpty ? " " : clippedText

            if let language, language != .unknown,
               displayText.utf8.count <= maxDiffSyntaxHighlightBytes {
                // Syntax highlight all lines — the subtle tinted backgrounds
                // (≈20% opacity) provide enough add/remove context while
                // token colors keep the code readable.
                let highlighted = NSMutableAttributedString(
                    attributedString: SyntaxHighlighter.highlight(displayText, language: language)
                )
                let fullRange = NSRange(location: 0, length: highlighted.length)
                highlighted.addAttributes(
                    [.font: codeFont, .paragraphStyle: paragraph],
                    range: fullRange
                )
                // Fill in missing foreground colors.
                let defaultFg = line.kind == .context ? fgDimColor : fgColor
                highlighted.enumerateAttribute(
                    .foregroundColor, in: fullRange, options: []
                ) { value, range, _ in
                    if value == nil {
                        highlighted.addAttribute(.foregroundColor, value: defaultFg, range: range)
                    }
                }
                result.append(highlighted)
            } else {
                let attrs = line.kind == .context ? codeDimAttrs : codeFgAttrs
                result.append(NSAttributedString(string: displayText, attributes: attrs))
            }

            // Row background for changed lines.
            let rowEnd = result.length
            switch line.kind {
            case .added:
                result.addAttribute(
                    .backgroundColor, value: addedBg,
                    range: NSRange(location: rowStart, length: rowEnd - rowStart)
                )
            case .removed:
                result.addAttribute(
                    .backgroundColor, value: removedBg,
                    range: NSRange(location: rowStart, length: rowEnd - rowStart)
                )
            case .context:
                break
            }

            if index < renderedLines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }

        if window.omittedBelow > 0 {
            result.append(NSAttributedString(
                string: "\n… \(window.omittedBelow) lines omitted below",
                attributes: omissionAttrs
            ))
        }

        return result
    }

    // MARK: - Helpers

    private struct DiffRenderWindow {
        let lines: ArraySlice<DiffLine>
        let omittedAbove: Int
        let omittedBelow: Int
        let startingOldLine: Int
        let startingNewLine: Int
    }

    private static func clippedDiffLineText(_ text: String) -> String {
        guard text.count > maxRenderedDiffLineCharacters else {
            return text
        }

        guard maxRenderedDiffLineCharacters > 1 else {
            return "…"
        }

        return String(text.prefix(maxRenderedDiffLineCharacters - 1)) + "…"
    }

    private static func diffRenderWindow(for lines: [DiffLine]) -> DiffRenderWindow {
        guard !lines.isEmpty else {
            return DiffRenderWindow(
                lines: lines[0..<0],
                omittedAbove: 0,
                omittedBelow: 0,
                startingOldLine: 1,
                startingNewLine: 1
            )
        }

        let maxLines = maxRenderedDiffLines
        guard lines.count > maxLines else {
            return makeDiffRenderWindow(for: lines, start: 0, end: lines.count)
        }

        guard let changedRange = changedLineRange(in: lines) else {
            return makeDiffRenderWindow(for: lines, start: 0, end: maxLines)
        }

        let bounds = diffWindowBounds(
            around: changedRange,
            totalLineCount: lines.count,
            maxWindowSize: maxLines
        )

        return makeDiffRenderWindow(for: lines, start: bounds.start, end: bounds.end)
    }

    private static func makeDiffRenderWindow(
        for lines: [DiffLine],
        start: Int,
        end: Int
    ) -> DiffRenderWindow {
        let startingLines = startingLineNumbers(for: lines, at: start)

        return DiffRenderWindow(
            lines: lines[start..<end],
            omittedAbove: start,
            omittedBelow: lines.count - end,
            startingOldLine: startingLines.old,
            startingNewLine: startingLines.new
        )
    }

    private static func changedLineRange(in lines: [DiffLine]) -> ClosedRange<Int>? {
        guard let firstChanged = lines.firstIndex(where: { $0.kind != .context }),
              let lastChanged = lines.lastIndex(where: { $0.kind != .context }) else {
            return nil
        }

        return firstChanged...lastChanged
    }

    private static func diffWindowBounds(
        around changedRange: ClosedRange<Int>,
        totalLineCount: Int,
        maxWindowSize: Int
    ) -> (start: Int, end: Int) {
        let changedLineCount = changedRange.upperBound - changedRange.lowerBound + 1
        if changedLineCount >= maxWindowSize {
            let start = changedRange.lowerBound
            return (start, min(totalLineCount, start + maxWindowSize))
        }

        let remainingContext = maxWindowSize - changedLineCount
        let availableBefore = changedRange.lowerBound
        let availableAfter = totalLineCount - changedRange.upperBound - 1

        var contextBefore = min(availableBefore, remainingContext / 2)
        var contextAfter = min(availableAfter, remainingContext - contextBefore)

        let unallocatedContext = remainingContext - contextBefore - contextAfter
        if unallocatedContext > 0 {
            let extraBefore = min(availableBefore - contextBefore, unallocatedContext)
            contextBefore += extraBefore
            contextAfter += min(availableAfter - contextAfter, unallocatedContext - extraBefore)
        }

        var start = changedRange.lowerBound - contextBefore
        var end = changedRange.upperBound + 1 + contextAfter

        let missingLines = maxWindowSize - (end - start)
        if missingLines > 0 {
            let shiftUp = min(start, missingLines)
            start -= shiftUp
            end = min(totalLineCount, end + (missingLines - shiftUp))
        }

        return (start, end)
    }

    private static func startingLineNumbers(for lines: [DiffLine], at index: Int) -> (old: Int, new: Int) {
        var oldLine = 1
        var newLine = 1

        guard index > 0 else {
            return (oldLine, newLine)
        }

        for line in lines[..<index] {
            switch line.kind {
            case .context:
                oldLine += 1
                newLine += 1
            case .removed:
                oldLine += 1
            case .added:
                newLine += 1
            }
        }

        return (oldLine, newLine)
    }

    // periphery:ignore - used by ToolRowTextRendererTests via @testable import
    static func lineNumberDigits(for lines: [DiffLine]) -> Int {
        lineNumberDigits(for: lines, startOldLine: 1, startNewLine: 1)
    }

    private static func lineNumberDigits(
        for lines: [DiffLine],
        startOldLine: Int,
        startNewLine: Int
    ) -> Int {
        var oldNumber = startOldLine
        var newNumber = startNewLine
        var maxSeen = max(1, oldNumber, newNumber)

        for line in lines {
            switch line.kind {
            case .context:
                maxSeen = max(maxSeen, oldNumber, newNumber)
                oldNumber += 1
                newNumber += 1
            case .removed:
                maxSeen = max(maxSeen, oldNumber)
                oldNumber += 1
            case .added:
                maxSeen = max(maxSeen, newNumber)
                newNumber += 1
            }
        }

        return String(maxSeen).count
    }

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

    // periphery:ignore - used by ToolRowTextRendererTests via @testable import
    static func paddedHeader(_ value: String, digits: Int) -> String {
        if value.count >= digits {
            return String(value.suffix(digits))
        }

        return String(repeating: " ", count: digits - value.count) + value
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
        case .plain, .markdown, .image, .audio:
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
