import CoreGraphics
import UIKit

// MARK: - DocumentRenderPipeline

/// Shared render pipeline for document types (Mermaid, LaTeX, Org Mode).
///
/// Eliminates duplicated parse → layout → draw logic across display views,
/// full-screen bodies, and the share export service. Each caller specifies
/// a `RenderConfiguration`; the pipeline handles the rest.
///
/// Three helpers:
/// - ``layoutGraphical(parser:renderer:text:config:)`` — single graphical document
/// - ``layoutLatexExpressions(text:config:)`` — multi-expression LaTeX math
/// - ``orgToMarkdown(_:)`` — Org Mode → Markdown text conversion
///
/// Two export helpers (for ``FileShareService``):
/// - ``renderGraphicalToImage(size:draw:backgroundColor:padding:)``
/// - ``renderGraphicalToPDF(size:draw:backgroundColor:padding:)``
enum DocumentRenderPipeline {

    // MARK: - Graphical Layout

    /// Result of a graphical parse → layout pass. Contains everything
    /// needed to draw or embed the content.
    struct GraphicalLayout {
        let size: CGSize
        let draw: (CGContext, CGPoint) -> Void
    }

    /// Parse and layout a single graphical document.
    ///
    /// Works for any parser/renderer pair conforming to the protocol
    /// (Mermaid, future Graphviz, etc.).
    static func layoutGraphical<P: DocumentParser, R: GraphicalDocumentRenderer>(
        parser: P,
        renderer: R,
        text: String,
        config: RenderConfiguration
    ) -> GraphicalLayout where P.Document == R.Document {
        let document = parser.parse(text)
        let layoutResult = renderer.layout(document, configuration: config)
        let size = renderer.boundingBox(layoutResult)
        return GraphicalLayout(size: size) { ctx, origin in
            renderer.draw(layoutResult, in: ctx, at: origin)
        }
    }

    // MARK: - LaTeX Multi-Expression Layout

    /// Result of laying out multiple LaTeX expressions separated by blank lines.
    struct LatexMultiLayout {
        let expressions: [GraphicalLayout]
        let totalSize: CGSize
        let spacing: CGFloat
    }

    /// Parse and layout LaTeX text as multiple expressions split by blank lines.
    ///
    /// Shared between display views (which render each expression in a stack)
    /// and the share service (which draws all into a single image/PDF).
    static func layoutLatexExpressions(
        text: String,
        config: RenderConfiguration,
        spacing: CGFloat = 16
    ) -> LatexMultiLayout {
        let sources = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let parser = TeXMathParser()
        let renderer = MathCoreGraphicsRenderer()

        var expressions: [GraphicalLayout] = []
        var totalHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for source in sources {
            let nodes = parser.parse(source)
            let layoutResult = renderer.layout(nodes, configuration: config)
            let size = renderer.boundingBox(layoutResult)
            let layout = GraphicalLayout(size: size) { ctx, origin in
                renderer.draw(layoutResult, in: ctx, at: origin)
            }
            expressions.append(layout)
            totalHeight += size.height
            maxWidth = max(maxWidth, size.width)
        }

        totalHeight += spacing * CGFloat(max(0, expressions.count - 1))

        return LatexMultiLayout(
            expressions: expressions,
            totalSize: CGSize(width: maxWidth, height: totalHeight),
            spacing: spacing
        )
    }

    // MARK: - Org → Markdown

    /// Convert Org Mode source to Markdown text.
    ///
    /// Uses the standard OrgParser → OrgToMarkdownConverter → MarkdownBlockSerializer
    /// pipeline shared across all surfaces.
    static func orgToMarkdown(_ source: String) -> String {
        let parser = OrgParser()
        let orgBlocks = parser.parse(source)
        let mdBlocks = OrgToMarkdownConverter.convert(orgBlocks)
        return MarkdownBlockSerializer.serialize(mdBlocks)
    }

    // MARK: - Export Helpers

    /// Render a graphical layout to a UIImage with padding and background color.
    @MainActor
    static func renderGraphicalToImage(
        size: CGSize,
        draw: @escaping (CGContext, CGPoint) -> Void,
        backgroundColor: UIColor,
        padding: CGFloat = 40,
        minWidth: CGFloat = 100,
        format: UIGraphicsImageRendererFormat? = nil
    ) -> UIImage {
        let imageSize = CGSize(
            width: max(size.width + padding * 2, minWidth),
            height: max(size.height + padding * 2, 100)
        )
        // Center content horizontally when image is wider than content
        let xOffset = (imageSize.width - size.width) / 2
        let imageRenderer: UIGraphicsImageRenderer
        if let format {
            imageRenderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        } else {
            imageRenderer = UIGraphicsImageRenderer(size: imageSize)
        }
        return imageRenderer.image { ctx in
            backgroundColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: imageSize))
            draw(ctx.cgContext, CGPoint(x: xOffset, y: padding))
        }
    }

    /// Render a graphical layout to PDF data with padding and background color.
    @MainActor
    static func renderGraphicalToPDF(
        size: CGSize,
        draw: @escaping (CGContext, CGPoint) -> Void,
        backgroundColor: UIColor,
        padding: CGFloat = 40
    ) -> Data {
        let pageSize = CGSize(
            width: max(size.width + padding * 2, 100),
            height: max(size.height + padding * 2, 100)
        )
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            backgroundColor.setFill()
            UIRectFill(CGRect(origin: .zero, size: pageSize))
            draw(ctx.cgContext, CGPoint(x: padding, y: padding))
        }
    }

    /// Render multiple LaTeX expressions to a single image.
    @MainActor
    static func renderLatexExpressionsToImage(
        layout: LatexMultiLayout,
        backgroundColor: UIColor,
        padding: CGFloat = 40,
        minWidth: CGFloat = 100,
        format: UIGraphicsImageRendererFormat? = nil
    ) -> UIImage {
        guard !layout.expressions.isEmpty else {
            return placeholderImage()
        }
        return renderGraphicalToImage(
            size: layout.totalSize,
            draw: { ctx, origin in
                var yOffset = origin.y
                for expr in layout.expressions {
                    expr.draw(ctx, CGPoint(x: origin.x, y: yOffset))
                    yOffset += expr.size.height + layout.spacing
                }
            },
            backgroundColor: backgroundColor,
            padding: padding,
            minWidth: minWidth,
            format: format
        )
    }

    /// Render multiple LaTeX expressions to a single PDF page.
    @MainActor
    static func renderLatexExpressionsToPDF(
        layout: LatexMultiLayout,
        backgroundColor: UIColor,
        padding: CGFloat = 40
    ) -> Data {
        guard !layout.expressions.isEmpty else {
            return Data()
        }
        return renderGraphicalToPDF(
            size: layout.totalSize,
            draw: { ctx, origin in
                var yOffset = origin.y
                for expr in layout.expressions {
                    expr.draw(ctx, CGPoint(x: origin.x, y: yOffset))
                    yOffset += expr.size.height + layout.spacing
                }
            },
            backgroundColor: backgroundColor,
            padding: padding
        )
    }

    /// Placeholder image for empty/failed content.
    @MainActor
    static func placeholderImage() -> UIImage {
        let size = CGSize(width: 200, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.96, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
