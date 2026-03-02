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
    static let maxRenderedCommandCharacters = 6_000
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
                NSAttributedString(SyntaxHighlighter.highlight(text, language: language)),
                font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            ),
            plainText: nil
        )
    }

    @MainActor
    static func applyANSIOutputPresentation(
        _ presentation: ANSIOutputPresentation,
        to label: UILabel,
        plainTextColor: UIColor
    ) {
        if let attributed = presentation.attributedText {
            label.attributedText = attributed
            return
        }

        label.attributedText = nil
        label.text = presentation.plainText
        label.textColor = plainTextColor
    }

    // MARK: - Markdown

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
        rendered.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil {
                rendered.addAttribute(
                    .font,
                    value: UIFont.systemFont(ofSize: 12, weight: .regular),
                    range: range
                )
            }
        }

        return rendered
    }

    // MARK: - Code

    static func makeCodeAttributedText(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int
    ) -> NSAttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let safeStartLine = max(1, startLine)
        let lastLineNumber = safeStartLine + max(0, lines.count - 1)
        let numberDigits = max(2, String(lastLineNumber).count)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 1

        let lineNumberColor = UIColor(Color.themeComment.opacity(0.55))
        let separatorColor = UIColor(Color.themeComment.opacity(0.35))
        let foregroundColor = UIColor(Color.themeFg)
        let codeFont = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let lineNumberFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        let lineNumAttrs: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont,
            .foregroundColor: lineNumberColor,
            .paragraphStyle: paragraph,
        ]
        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: codeFont,
            .foregroundColor: separatorColor,
            .paragraphStyle: paragraph,
        ]
        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: codeFont,
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraph,
        ]

        let result = NSMutableAttributedString()
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = safeStartLine + index
            result.append(NSAttributedString(
                string: "\(paddedLineNumber(lineNumber, digits: numberDigits)) ",
                attributes: lineNumAttrs
            ))
            result.append(NSAttributedString(string: "│ ", attributes: separatorAttrs))

            let displayLine = rawLine.isEmpty ? " " : rawLine
            if let language,
               language != .unknown,
               displayLine.utf8.count <= maxDiffSyntaxHighlightBytes {
                let highlighted = NSMutableAttributedString(
                    attributedString: NSAttributedString(
                        SyntaxHighlighter.highlightLine(displayLine, language: language)
                    )
                )
                let fullRange = NSRange(location: 0, length: highlighted.length)
                highlighted.addAttributes(
                    [.font: codeFont, .paragraphStyle: paragraph],
                    range: fullRange
                )
                highlighted.enumerateAttribute(
                    .foregroundColor,
                    in: fullRange,
                    options: []
                ) { value, range, _ in
                    if value == nil {
                        highlighted.addAttribute(
                            .foregroundColor,
                            value: foregroundColor,
                            range: range
                        )
                    }
                }
                result.append(highlighted)
            } else {
                result.append(NSAttributedString(string: displayLine, attributes: codeAttrs))
            }

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }

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
                        .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: UIColor(Color.themeComment),
                        .paragraphStyle: paragraph,
                    ]
                )
            )
            return result
        }

        // Pre-compute reusable attributes (avoids per-line dictionary allocations).
        let codeFont = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let numFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let prefixFont = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)

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
            .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
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
                    attributedString: NSAttributedString(
                        SyntaxHighlighter.highlight(displayText, language: language)
                    )
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

        return String(format: "%\(digits)d", number)
    }

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
            NSAttributedString(SyntaxHighlighter.highlight(text, language: .shell)),
            font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        )
    }

    static func ansiHighlighted(
        _ text: String,
        baseForeground: Color = .themeFg
    ) -> NSAttributedString {
        let highlighted = ANSIParser.attributedString(from: text, baseForeground: baseForeground)
        return NSAttributedString(highlighted)
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
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
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

    static func truncatedDisplayText(_ text: String, maxCharacters: Int, note: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + note
    }

    static func displayCommandText(_ text: String) -> String {
        truncatedDisplayText(
            text,
            maxCharacters: maxRenderedCommandCharacters,
            note: "\n… command truncated for display"
        )
    }

    static func displayOutputText(_ text: String) -> String {
        truncatedDisplayText(
            text,
            maxCharacters: maxRenderedOutputCharacters,
            note: "\n… output truncated for display. Use Copy for full content."
        )
    }
}
