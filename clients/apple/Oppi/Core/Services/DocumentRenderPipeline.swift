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

    /// Explicit cap for natural-size timeline/inline rasters. Core Graphics
    /// layout may be arbitrarily wide, but bitmap allocation must stay bounded.
    struct NaturalRasterBudget: Equatable, Sendable {
        let maxPointDimension: CGFloat
        let maxPixelDimension: Int
        let maxPixelCount: Int
        let maxBytes: Int

        func permits(pointSize: CGSize, scale: CGFloat) -> Bool {
            guard pointSize.width.isFinite, pointSize.height.isFinite,
                  pointSize.width > 0, pointSize.height > 0,
                  scale.isFinite, scale > 0 else {
                return false
            }
            guard pointSize.width <= maxPointDimension,
                  pointSize.height <= maxPointDimension else {
                return false
            }
            let pixelWidth = ceil(pointSize.width * scale)
            let pixelHeight = ceil(pointSize.height * scale)
            guard pixelWidth <= CGFloat(maxPixelDimension),
                  pixelHeight <= CGFloat(maxPixelDimension) else {
                return false
            }
            let pixels = pixelWidth * pixelHeight
            guard pixels <= CGFloat(maxPixelCount) else { return false }
            return pixels * 4 <= CGFloat(maxBytes)
        }
    }

    static let naturalRasterBudget = NaturalRasterBudget(
        maxPointDimension: 2_048,
        maxPixelDimension: 4_096,
        maxPixelCount: 12_582_912,
        maxBytes: 48 * 1_024 * 1_024
    )

    /// File/share exports may be larger than timeline rasters, but every bitmap
    /// allocation still has an explicit point, pixel, and byte ceiling.
    static let exportRasterBudget = NaturalRasterBudget(
        maxPointDimension: 4_096,
        maxPixelDimension: 8_192,
        maxPixelCount: 16_777_216,
        maxBytes: 64 * 1_024 * 1_024
    )

    // MARK: - Render Cache

    /// Cross-surface raster cache for graphically rendered blocks (LaTeX
    /// formulas, Mermaid diagrams).
    ///
    /// The full-screen markdown reader renders these blocks synchronously so
    /// cell self-sizing sees final heights on the first pass. Without a cache,
    /// every cell reuse re-pays parse + layout + rasterize on the main thread.
    /// Parse failures are deterministic per input, so negative results are
    /// cached too. NSCache is thread-safe and evicts under memory pressure.
    /// `NSCache` is documented thread-safe but not `Sendable`; this holder
    /// lets the static satisfy strict-concurrency checking while concurrent
    /// render calls from detached tasks share one cache.
    private final class GraphicalRenderCacheStore: @unchecked Sendable {
        let cache: NSCache<NSString, CachedGraphicalRender> = {
            let cache = NSCache<NSString, CachedGraphicalRender>()
            cache.totalCostLimit = 64 * 1_024 * 1_024
            cache.name = "org.oppi.DocumentRenderPipeline"
            return cache
        }()
    }

    private static let renderCache = GraphicalRenderCacheStore()

    #if DEBUG
    static func debugRemoveAllCachedRendersForTesting() {
        renderCache.cache.removeAllObjects()
    }
    #endif

    private final class CachedGraphicalRender: @unchecked Sendable {
        /// `nil` means the source is deterministically unrenderable — callers
        /// show their source fallback without re-parsing.
        let image: UIImage?
        let size: CGSize
        let baseline: CGFloat?

        init(image: UIImage?, size: CGSize, baseline: CGFloat? = nil) {
            self.image = image
            self.size = size
            self.baseline = baseline
        }
    }

    /// Cache key includes the full source text (formulas are small) so hash
    /// collisions can never surface the wrong raster.
    private static func renderCacheKey(
        kind: String,
        text: String,
        config: RenderConfiguration,
        scale: CGFloat
    ) -> NSString {
        "\(kind)|\(config.fontSize)|\(Int(config.maxWidth.rounded()))|\(config.displayMode)|\(scale)|\(renderThemeSignature(config.theme))|\(text)" as NSString
    }

    private static func renderThemeSignature(_ theme: RenderTheme) -> String {
        func componentString(_ color: CGColor) -> String {
            guard
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
                let components = converted.components, components.count >= 3
            else {
                return "?"
            }
            let alpha = components.count > 3 ? components[3] : 1
            return String(
                format: "%.3f,%.3f,%.3f,%.3f",
                components[0], components[1], components[2], alpha
            )
        }
        return [
            componentString(theme.foreground), componentString(theme.foregroundDim),
            componentString(theme.background), componentString(theme.backgroundDark),
            componentString(theme.comment), componentString(theme.keyword),
            componentString(theme.string), componentString(theme.number),
            componentString(theme.function), componentString(theme.type),
            componentString(theme.link), componentString(theme.heading),
            componentString(theme.accentBlue), componentString(theme.accentCyan),
            componentString(theme.accentGreen), componentString(theme.accentOrange),
            componentString(theme.accentPurple), componentString(theme.accentRed),
            componentString(theme.accentYellow)
        ].joined(separator: ";")
    }

    private static func cachedRenderCost(_ image: UIImage?) -> Int {
        guard let image, let cgImage = image.cgImage else { return 16 }
        return cgImage.bytesPerRow * cgImage.height
    }

    private static func renderCached(
        kind: String,
        text: String,
        config: RenderConfiguration,
        scale: CGFloat,
        render: () -> CachedGraphicalRender
    ) -> CachedGraphicalRender {
        let key = renderCacheKey(kind: kind, text: text, config: config, scale: scale)
        if let hit = renderCache.cache.object(forKey: key) {
            return hit
        }
        let entry = render()
        renderCache.cache.setObject(entry, forKey: key, cost: cachedRenderCost(entry.image))
        return entry
    }

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

    static func renderInlineGraphicalImage<P: DocumentParser, R: GraphicalDocumentRenderer>(
        parser: P,
        renderer: R,
        text: String,
        config: RenderConfiguration,
        scale: CGFloat = 2.0
    ) -> (image: UIImage, size: CGSize)? where P.Document == R.Document {
        let kind = "graphical:\(String(reflecting: P.self))/\(String(reflecting: R.self))"
        let entry = renderCached(kind: kind, text: text, config: config, scale: scale) {
            let layout = layoutGraphical(
                parser: parser,
                renderer: renderer,
                text: text,
                config: config
            )
            guard naturalRasterBudget.permits(pointSize: layout.size, scale: scale) else {
                return CachedGraphicalRender(image: nil, size: layout.size)
            }

            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let imageRenderer = UIGraphicsImageRenderer(size: layout.size, format: format)
            let image = imageRenderer.image { ctx in
                layout.draw(ctx.cgContext, .zero)
            }
            return CachedGraphicalRender(image: image, size: layout.size)
        }
        guard let image = entry.image else { return nil }
        return (image: image, size: entry.size)
    }

    /// Validate and rasterize one natural-size display formula. Unsupported or
    /// recovered TeX and formulas beyond the bitmap budget return nil so callers
    /// can show exact source deterministically.
    static func renderLatexGraphicalImage(
        text: String,
        config: RenderConfiguration,
        scale: CGFloat = 2.0
    ) -> (image: UIImage, size: CGSize)? {
        let entry = renderCached(kind: "latex-display", text: text, config: config, scale: scale) {
            let parser = TeXMathParser()
            let parsed = parser.parseValidated(text)
            guard parsed.isRenderable else {
                return CachedGraphicalRender(image: nil, size: .zero)
            }

            let renderer = MathCoreGraphicsRenderer()
            let layoutResult = renderer.layout(parsed.nodes, configuration: config)
            let size = renderer.boundingBox(layoutResult)
            guard naturalRasterBudget.permits(pointSize: size, scale: scale) else {
                return CachedGraphicalRender(image: nil, size: size)
            }

            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let imageRenderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = imageRenderer.image { context in
                renderer.draw(layoutResult, in: context.cgContext, at: .zero)
            }
            return CachedGraphicalRender(image: image, size: size)
        }
        guard let image = entry.image else { return nil }
        return (image: image, size: entry.size)
    }

    /// Rasterize one inline formula and preserve its TeX baseline so a text
    /// attachment can align with surrounding prose instead of sitting on the
    /// bottom of the line fragment.
    static func renderInlineLatexImage(
        text: String,
        config: RenderConfiguration,
        scale: CGFloat = 2.0
    ) -> (image: UIImage, size: CGSize, baseline: CGFloat)? {
        let entry = renderCached(kind: "latex-inline", text: text, config: config, scale: scale) {
            let parser = TeXMathParser()
            let parsed = parser.parseValidated(text)
            guard parsed.isRenderable else {
                return CachedGraphicalRender(image: nil, size: .zero)
            }
            let renderer = MathCoreGraphicsRenderer()
            let layout = renderer.layout(parsed.nodes, configuration: config)
            let size = renderer.boundingBox(layout)
            guard naturalRasterBudget.permits(pointSize: size, scale: scale) else {
                return CachedGraphicalRender(image: nil, size: size)
            }

            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let imageRenderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = imageRenderer.image { context in
                renderer.draw(layout, in: context.cgContext, at: .zero)
            }
            return CachedGraphicalRender(image: image, size: size, baseline: layout.rootBox.baseline)
        }
        guard let image = entry.image, let baseline = entry.baseline else { return nil }
        return (image: image, size: entry.size, baseline: baseline)
    }

    // MARK: - LaTeX Multi-Expression Layout

    /// Result of laying out multiple LaTeX expressions separated by blank lines.
    struct LatexMultiLayout {
        let expressions: [GraphicalLayout]
        let sources: [String]
        let totalSize: CGSize
        let spacing: CGFloat
        /// Exact original source when any expression fails the same validated
        /// renderer contract used by timeline formulas.
        let exactSourceFallback: String?

        var isRenderable: Bool { exactSourceFallback == nil }
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
        guard text.utf8.count <= TeXMathLimits.maxSourceUTF8Bytes else {
            return LatexMultiLayout(
                expressions: [],
                sources: [],
                totalSize: .zero,
                spacing: spacing,
                exactSourceFallback: text
            )
        }

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
            let parsed = parser.parseValidated(source)
            guard parsed.isRenderable else {
                return LatexMultiLayout(
                    expressions: [],
                    sources: [],
                    totalSize: .zero,
                    spacing: spacing,
                    exactSourceFallback: text
                )
            }
            let layoutResult = renderer.layout(parsed.nodes, configuration: config)
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
            sources: sources,
            totalSize: CGSize(width: maxWidth, height: totalHeight),
            spacing: spacing,
            exactSourceFallback: nil
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
        let scale = format?.scale ?? UIGraphicsImageRendererFormat.default().scale
        guard exportRasterBudget.permits(pointSize: imageSize, scale: scale) else {
            return placeholderImage()
        }

        // Center content horizontally when image is wider than content.
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

    /// Build an exact-source fallback for invalid or unsupported LaTeX.
    @MainActor
    static func makeLatexSourceFallbackView(
        source: String,
        palette: ThemePalette
    ) -> UIView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.font = FontPreferences.scaledCodeFont(baseSize: 14, textStyle: .body)
        textView.textColor = UIColor(palette.fg)
        textView.text = source
        textView.accessibilityLabel = source
        return textView
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
        if let source = layout.exactSourceFallback {
            return renderLatexFallbackSourceToImage(
                source,
                backgroundColor: backgroundColor,
                padding: padding,
                minWidth: minWidth,
                format: format
            )
        }
        guard !layout.expressions.isEmpty else {
            return placeholderImage()
        }

        let exportSize = CGSize(
            width: max(layout.totalSize.width + padding * 2, minWidth),
            height: max(layout.totalSize.height + padding * 2, 100)
        )
        let exportScale = format?.scale ?? UIGraphicsImageRendererFormat.default().scale
        guard exportRasterBudget.permits(pointSize: exportSize, scale: exportScale) else {
            // A valid formula can still be too wide/tall for a safe bitmap.
            // Export a bounded source preview rather than attempting the graph
            // allocation or silently returning an empty document.
            return renderLatexFallbackSourceToImage(
                layout.sources.joined(separator: "\n\n"),
                backgroundColor: backgroundColor,
                padding: padding,
                minWidth: minWidth,
                format: format
            )
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
        if let source = layout.exactSourceFallback {
            return renderLatexFallbackSourceToPDF(
                source,
                backgroundColor: backgroundColor,
                padding: padding
            )
        }
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

    @MainActor
    private static func renderLatexFallbackSourceToImage(
        _ source: String,
        backgroundColor: UIColor,
        padding: CGFloat,
        minWidth: CGFloat,
        format: UIGraphicsImageRendererFormat?
    ) -> UIImage {
        let attributed = latexFallbackAttributedSource(boundedLatexSourcePreview(source))
        let drawWidth: CGFloat = 720
        let bounds = attributed.boundingRect(
            with: CGSize(width: drawWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return renderGraphicalToImage(
            size: CGSize(width: ceil(bounds.width), height: ceil(bounds.height)),
            draw: { _, origin in
                attributed.draw(
                    with: CGRect(origin: origin, size: bounds.size),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            },
            backgroundColor: backgroundColor,
            padding: padding,
            minWidth: minWidth,
            format: format
        )
    }

    @MainActor
    private static func renderLatexFallbackSourceToPDF(
        _ source: String,
        backgroundColor: UIColor,
        padding: CGFloat
    ) -> Data {
        let attributed = latexFallbackAttributedSource(source)
        let drawWidth: CGFloat = 720
        let bounds = attributed.boundingRect(
            with: CGSize(width: drawWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return renderGraphicalToPDF(
            size: CGSize(width: ceil(bounds.width), height: ceil(bounds.height)),
            draw: { _, origin in
                attributed.draw(
                    with: CGRect(origin: origin, size: bounds.size),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            },
            backgroundColor: backgroundColor,
            padding: padding
        )
    }

    private static func boundedLatexSourcePreview(_ source: String) -> String {
        // A single bitmap cannot paginate. Keep a deterministic first page and
        // make truncation explicit; PDF export remains the exact-source path.
        let maxCharacters = 3_072
        guard source.count > maxCharacters else { return source }
        return String(source.prefix(maxCharacters)) + "\n… (source truncated for image export)"
    }

    @MainActor
    private static func latexFallbackAttributedSource(_ source: String) -> NSAttributedString {
        NSAttributedString(
            string: source,
            attributes: [
                .font: FontPreferences.scaledCodeFont(baseSize: 14, textStyle: .body),
                .foregroundColor: UIColor.label,
            ]
        )
    }

    /// Placeholder image for empty/failed content.
    @MainActor
    static func placeholderImage() -> UIImage {
        let size = CGSize(width: 200, height: 100)
        let scale = UIGraphicsImageRendererFormat.default().scale
        guard exportRasterBudget.permits(pointSize: size, scale: scale) else {
            return UIImage()
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.96, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
