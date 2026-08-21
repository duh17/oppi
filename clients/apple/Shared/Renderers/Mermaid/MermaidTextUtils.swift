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

    /// Normalize Mermaid label text from parsed delimiters.
    ///
    /// Official flowchart and mindmap syntax uses quoted strings for labels
    /// containing syntax characters, backtick-wrapped markdown strings, and
    /// entity codes such as `#quot;` and `#9829;`.
    static func normalizeLabel(_ text: String) -> String {
        var result = normalizeBrTags(text)
        result = stripWrappingDelimiter(result, delimiter: "\"")
        result = stripWrappingDelimiter(result, delimiter: "`")
        return decodeMermaidEntities(result)
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
        lineSpacing: CGFloat? = nil
    ) -> CGSize {
        let spacing = lineSpacing ?? fontSize * 0.3
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if lines.count <= 1 {
            return measureSingleLine(text, font: font, fontSize: fontSize)
        }

        var maxWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for (i, line) in lines.enumerated() {
            let size = measureSingleLine(line, font: font, fontSize: fontSize)
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
        fontSize: CGFloat
    ) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
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
        in ctx: CGContext
    ) {
        let spacing = lineSpacing ?? fontSize * 0.3
        let textSize = measureText(text, font: font, fontSize: fontSize, lineSpacing: spacing)
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
        in ctx: CGContext
    ) {
        let spacing = lineSpacing ?? fontSize * 0.3
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
        ]

        var currentY = origin.y

        for line in lines {
            let attrStr = NSAttributedString(string: line, attributes: attrs)
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
