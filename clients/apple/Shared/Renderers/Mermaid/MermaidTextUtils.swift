import CoreGraphics
import CoreText
import Foundation

/// Shared text utilities for Mermaid diagram renderers.
///
/// Handles HTML `<br>` tag normalization and multi-line CoreText
/// measurement/drawing. All methods are `nonisolated static`.
enum MermaidTextUtils {

    static func hexagonPath(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let inset = rect.width * 0.15
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    // MARK: - Text normalization

    /// Replace `<br>`, `<br/>`, `<br />` with `\n`.
    ///
    /// Mermaid uses HTML break tags for line breaks in node labels and
    /// message text. This normalizes them to newlines so renderers can
    /// handle multi-line text uniformly.
    static func normalizeBrTags(_ text: String) -> String {
        // Match <br>, <br/>, <br />, case-insensitive
        text.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// Result of inspecting a Mermaid label before drawing.
    struct LabelInspection: Equatable, Sendable {
        let text: String
        let isMarkdown: Bool
    }

    /// Normalize Mermaid label text from parsed delimiters.
    ///
    /// Official flowchart and mindmap syntax uses quoted strings for labels
    /// containing syntax characters, backtick-wrapped markdown strings, and
    /// entity codes such as `#quot;` and `#9829;`.
    static func normalizeLabel(_ text: String) -> String {
        inspectLabel(text).text
    }

    /// Detect official quoted+backtick markdown strings before stripping delimiters.
    ///
    /// `A["`**bold**`"]` is markdown. `A["text with *stars*"]` is not.
    static func inspectLabel(_ text: String) -> LabelInspection {
        var result = normalizeBrTags(text)
        result = stripWrappingDelimiter(result, delimiter: "\"")
        // Official markdown strings are the backtick-wrapped form, with or
        // without quotes: A["`**bold**`"] and A("`**bold**`").
        // Plain quoted text such as A["*stars*"] stays literal.
        let hadBackticks = result.count >= 2 && result.first == "`" && result.last == "`"
        result = stripWrappingDelimiter(result, delimiter: "`")
        return LabelInspection(
            text: decodeMermaidEntities(result),
            isMarkdown: hadBackticks
        )
    }

    /// One visible run after official-subset markdown parsing.
    struct LabelRun: Equatable, Sendable {
        let text: String
        let isBold: Bool
        let isItalic: Bool
    }

    /// Official flowchart markdown subset: `**bold**`, `*italic*`, `_italic_`.
    /// Unmatched markers stay literal. Nested spans are not parsed.
    static func markdownLabelRuns(_ text: String) -> [LabelRun] {
        var runs: [LabelRun] = []
        var literal = ""
        var index = text.startIndex

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            runs.append(LabelRun(text: literal, isBold: false, isItalic: false))
            literal = ""
        }

        while index < text.endIndex {
            if text[index...].hasPrefix("**") {
                if let span = takeSpan(text, from: index, delimiter: "**") {
                    flushLiteral()
                    runs.append(LabelRun(text: span.text, isBold: true, isItalic: false))
                    index = span.end
                } else {
                    literal.append(contentsOf: "**")
                    index = text.index(index, offsetBy: 2)
                }
                continue
            }
            if text[index...].hasPrefix("*") {
                if let span = takeSpan(text, from: index, delimiter: "*") {
                    flushLiteral()
                    runs.append(LabelRun(text: span.text, isBold: false, isItalic: true))
                    index = span.end
                } else {
                    literal.append("*")
                    index = text.index(after: index)
                }
                continue
            }
            if text[index...].hasPrefix("_") {
                if let span = takeSpan(text, from: index, delimiter: "_") {
                    flushLiteral()
                    runs.append(LabelRun(text: span.text, isBold: false, isItalic: true))
                    index = span.end
                } else {
                    literal.append("_")
                    index = text.index(after: index)
                }
                continue
            }
            literal.append(text[index])
            index = text.index(after: index)
        }
        flushLiteral()
        return runs
    }

    /// Build an attributed label. Markdown formatting is applied only when `isMarkdown`.
    static func attributedLabel(
        _ text: String,
        font: CTFont,
        fontSize: CGFloat,
        foregroundColor: CGColor? = nil,
        isMarkdown: Bool
    ) -> NSAttributedString {
        if !isMarkdown {
            return attributedRun(text, font: font, foregroundColor: foregroundColor)
        }
        let result = NSMutableAttributedString()
        for run in markdownLabelRuns(text) {
            let runFont = styledFont(from: font, size: fontSize, bold: run.isBold, italic: run.isItalic)
            result.append(attributedRun(run.text, font: runFont, foregroundColor: foregroundColor))
        }
        return result
    }

    private static func takeSpan(
        _ text: String,
        from start: String.Index,
        delimiter: String
    ) -> (text: String, end: String.Index)? {
        guard text[start...].hasPrefix(delimiter) else { return nil }
        let innerStart = text.index(start, offsetBy: delimiter.count)
        guard innerStart < text.endIndex,
              let close = text[innerStart...].range(of: delimiter),
              close.lowerBound > innerStart
        else { return nil }
        return (String(text[innerStart..<close.lowerBound]), close.upperBound)
    }

    private static func attributedRun(
        _ text: String,
        font: CTFont,
        foregroundColor: CGColor?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: font, range: range)
        if let foregroundColor {
            result.addAttribute(.foregroundColor, value: foregroundColor, range: range)
        }
        return result
    }

    private static func styledFont(
        from base: CTFont,
        size: CGFloat,
        bold: Bool,
        italic: Bool
    ) -> CTFont {
        if !bold && !italic { return base }
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let styled = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) {
            return styled
        }
        let name: String
        switch (bold, italic) {
        case (true, true): name = "Helvetica-BoldOblique"
        case (true, false): name = "Helvetica-Bold"
        case (false, true): name = "Helvetica-Oblique"
        default: return base
        }
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    private static func stripWrappingDelimiter(_ text: String, delimiter: Character) -> String {
        guard text.count >= 2,
              text.first == delimiter,
              text.last == delimiter
        else { return text }
        return String(text.dropFirst().dropLast())
    }

    private static func decodeMermaidEntities(_ text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]
            if char == "#" || char == "&" {
                let bodyStart = text.index(after: index)
                if bodyStart < text.endIndex,
                   let semicolon = text[bodyStart...].firstIndex(of: ";") {
                    let body = String(text[bodyStart..<semicolon])
                    if let decoded = decodedEntityBody(body) {
                        output.append(decoded)
                        index = text.index(after: semicolon)
                        continue
                    }
                }
            }

            output.append(char)
            index = text.index(after: index)
        }

        return output
    }

    private static func decodedEntityBody(_ body: String) -> String? {
        if body.hasPrefix("#") {
            return decodedEntityBody(String(body.dropFirst()))
        }

        let lower = body.lowercased()
        if lower.hasPrefix("x") {
            let hex = String(lower.dropFirst())
            if let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
                return String(scalar)
            }
            return nil
        }

        if let value = UInt32(body, radix: 10), let scalar = UnicodeScalar(value) {
            return String(scalar)
        }

        return namedEntities[lower]
    }

    private static let namedEntities: [String: String] = [
        "amp": "&",
        "apos": "'",
        "gt": ">",
        "infin": "∞",
        "lt": "<",
        "nbsp": "\u{00A0}",
        "quot": "\"",
    ]

    // MARK: - Text wrapping

    /// Word-wrap `text` so each line fits `maxWidth`. Existing newlines are kept.
    static func wrapText(
        _ text: String,
        maxWidth: CGFloat,
        font: CTFont,
        fontSize: CGFloat
    ) -> String {
        let width = max(maxWidth, fontSize * 2)
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var wrapped: [String] = []
        for paragraph in paragraphs {
            wrapped.append(contentsOf: wrapParagraph(paragraph, maxWidth: width, font: font, fontSize: fontSize))
        }
        return wrapped.joined(separator: "\n")
    }

    private static func wrapParagraph(
        _ paragraph: String,
        maxWidth: CGFloat,
        font: CTFont,
        fontSize: CGFloat
    ) -> [String] {
        if paragraph.isEmpty { return [""] }
        if measureSingleLine(paragraph, font: font, fontSize: fontSize).width <= maxWidth {
            return [paragraph]
        }

        let words = paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [paragraph] }

        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if measureSingleLine(candidate, font: font, fontSize: fontSize).width <= maxWidth {
                current = candidate
                continue
            }
            if !current.isEmpty {
                lines.append(current)
            }
            if measureSingleLine(word, font: font, fontSize: fontSize).width <= maxWidth {
                current = word
            } else {
                lines.append(contentsOf: wrapLongToken(word, maxWidth: maxWidth, font: font, fontSize: fontSize))
                current = ""
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines.isEmpty ? [paragraph] : lines
    }

    private static func wrapLongToken(
        _ token: String,
        maxWidth: CGFloat,
        font: CTFont,
        fontSize: CGFloat
    ) -> [String] {
        var lines: [String] = []
        var current = ""
        for character in token {
            let candidate = current + String(character)
            if !current.isEmpty,
               measureSingleLine(candidate, font: font, fontSize: fontSize).width > maxWidth {
                lines.append(current)
                current = String(character)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines.isEmpty ? [token] : lines
    }

    // MARK: - Text measurement

    /// Measure text size, supporting multi-line text (split on `\n`).
    ///
    /// Returns the bounding size of the full text block.
    /// Width = widest line; height = sum of line heights + inter-line spacing.
    static func measureText(
        _ text: String,
        font: CTFont,
        fontSize: CGFloat,
        lineSpacing: CGFloat? = nil,
        isMarkdown: Bool = false
    ) -> CGSize {
        let spacing = lineSpacing ?? fontSize * 0.3
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if lines.count <= 1 {
            return measureSingleLine(text, font: font, fontSize: fontSize, isMarkdown: isMarkdown)
        }

        var maxWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for (i, line) in lines.enumerated() {
            let size = measureSingleLine(line, font: font, fontSize: fontSize, isMarkdown: isMarkdown)
            maxWidth = max(maxWidth, size.width)
            totalHeight += size.height
            if i < lines.count - 1 {
                totalHeight += spacing
            }
        }

        return CGSize(
            width: max(maxWidth, fontSize * 2),
            height: max(totalHeight, fontSize * 1.4)
        )
    }

    /// Measure a single line of text.
    private static func measureSingleLine(
        _ text: String,
        font: CTFont,
        fontSize: CGFloat,
        isMarkdown: Bool = false
    ) -> CGSize {
        let attrStr = attributedLabel(text, font: font, fontSize: fontSize, isMarkdown: isMarkdown)
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        return CGSize(
            width: max(bounds.width, fontSize * 2),
            height: max(bounds.height, fontSize * 1.4)
        )
    }

    // MARK: - Text drawing

    /// Horizontal alignment for multi-line text drawing.
    enum TextAlignment {
        case left
        case center
    }

    /// Draw text centered in a rect, supporting multi-line text.
    static func drawText(
        _ text: String,
        centeredIn rect: CGRect,
        font: CTFont,
        fontSize: CGFloat,
        foregroundColor: CGColor,
        lineSpacing: CGFloat? = nil,
        isMarkdown: Bool = false,
        in ctx: CGContext
    ) {
        let spacing = lineSpacing ?? fontSize * 0.3
        let textSize = measureText(
            text,
            font: font,
            fontSize: fontSize,
            lineSpacing: spacing,
            isMarkdown: isMarkdown
        )
        let x = rect.midX - textSize.width / 2
        let y = rect.midY - textSize.height / 2

        drawText(
            text,
            at: CGPoint(x: x, y: y),
            width: textSize.width,
            font: font,
            fontSize: fontSize,
            foregroundColor: foregroundColor,
            alignment: .center,
            lineSpacing: spacing,
            isMarkdown: isMarkdown,
            in: ctx
        )
    }

    /// Draw text at a position, supporting multi-line text.
    ///
    /// `at` is the top-left of the text block (in UIKit Y-down coordinates).
    /// If `width` is provided, alignment is applied relative to that width.
    static func drawText(
        _ text: String,
        at origin: CGPoint,
        width: CGFloat? = nil,
        font: CTFont,
        fontSize: CGFloat,
        foregroundColor: CGColor,
        alignment: TextAlignment = .left,
        lineSpacing: CGFloat? = nil,
        isMarkdown: Bool = false,
        in ctx: CGContext
    ) {
        let spacing = lineSpacing ?? fontSize * 0.3
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var currentY = origin.y

        for line in lines {
            let attrStr = attributedLabel(
                line,
                font: font,
                fontSize: fontSize,
                foregroundColor: foregroundColor,
                isMarkdown: isMarkdown
            )
            let ctLine = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(ctLine, [])
            let lineHeight = max(bounds.height, fontSize * 1.4)

            let x: CGFloat
            switch alignment {
            case .left:
                x = origin.x
            case .center:
                let blockWidth = width ?? bounds.width
                x = origin.x + (blockWidth - bounds.width) / 2
            }

            drawCTLine(ctLine, at: CGPoint(x: x, y: currentY), fontSize: fontSize, in: ctx)
            currentY += lineHeight + spacing
        }
    }

    // MARK: - Single CTLine drawing

    /// Draw a CTLine at (x, y) in UIKit top-left (Y-down) coordinates.
    ///
    /// CTLineDraw uses CG coords (Y-up). This flips locally so text
    /// renders right-side-up in the UIKit coordinate space.
    static func drawCTLine(
        _ line: CTLine,
        at point: CGPoint,
        fontSize: CGFloat,
        in ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y + fontSize)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
