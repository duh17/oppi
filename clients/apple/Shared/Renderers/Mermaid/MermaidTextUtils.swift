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

    // MARK: - HTML tag normalization

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
