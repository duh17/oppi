import CoreGraphics
import CoreText
import Foundation

/// Renders `[MathNode]` into a Core Graphics context via a two-phase pipeline.
///
/// Phase 1 — `layout()`: converts the AST into a `LayoutBox` tree with
/// computed positions and sizes using `MathLayoutEngine`. Inline formulas set
/// in TeX's text style, document formulas in display style.
///
/// Phase 2 — `draw()`: walks the `LayoutBox` tree and draws glyphs and
/// rules into a `CGContext` using Core Text and Core Graphics.
///
/// Conforms to `GraphicalDocumentRenderer` so it plugs into the shared
/// renderer protocol. The draw closure captures the layout result and
/// is marked `@Sendable` per protocol requirements. `CGContext` is not
/// `Sendable` but is only used inside the closure at draw time — this is
/// safe because the closure is called synchronously from the view's draw
/// method on the thread that owns the context.
struct MathCoreGraphicsRenderer: GraphicalDocumentRenderer, Sendable {
    typealias Document = [MathNode]
    typealias LayoutResult = MathRenderLayout

    private let engine = MathLayoutEngine()

    // MARK: - Layout Phase

    nonisolated func layout(
        _ document: [MathNode],
        configuration: RenderConfiguration
    ) -> MathRenderLayout {
        let rootBox = engine.layout(
            document,
            fontSize: configuration.fontSize,
            display: configuration.displayMode == .document
        )
        return MathRenderLayout(
            rootBox: rootBox,
            configuration: configuration
        )
    }

    // MARK: - Draw Phase

    nonisolated func draw(
        _ layout: MathRenderLayout,
        in context: CGContext,
        at origin: CGPoint
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        // Layout uses top-left coordinates, which match UIKit's context
        // (y down). Glyphs flip locally around their baseline.
        context.translateBy(x: origin.x, y: origin.y)

        drawBox(layout.rootBox, in: context, foreground: layout.configuration.theme.foreground)
    }

    // MARK: - Bounding Box

    nonisolated func boundingBox(_ layout: MathRenderLayout) -> CGSize {
        layout.rootBox.size
    }

    // MARK: - Recursive Drawing

    private func drawBox(
        _ box: LayoutBox,
        in context: CGContext,
        foreground: CGColor
    ) {
        context.saveGState()
        context.translateBy(x: box.origin.x, y: box.origin.y)

        switch box.content {
        case .glyph(let text, let fontSize):
            drawText(text, fontSize: fontSize, baseline: box.baseline, in: context, foreground: foreground)

        case .glyphID(let glyph, let fontSize):
            context.saveGState()
            context.translateBy(x: 0, y: box.baseline)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(foreground)
            // The text matrix is not graphics state: a CTLineDraw before
            // this one leaves its pen position in it.
            context.textMatrix = .identity
            context.textPosition = .zero
            var id = glyph
            var position = CGPoint.zero
            CTFontDrawGlyphs(MathFont.shared.font(size: fontSize), &id, &position, 1, context)
            context.restoreGState()

        case .line(let from, let to, let thickness):
            context.setStrokeColor(foreground)
            context.setLineWidth(thickness)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()

        case .container(let children):
            for child in children {
                drawBox(child, in: context, foreground: foreground)
            }
        }

        context.restoreGState()
    }

    // MARK: - Glyph Drawing

    /// Colored CTLines reused across fullscreen vector redraws of the same
    /// formula. Layout metrics live in `MathLayoutEngine`; this cache is draw.
    private final class GlyphLineStore: @unchecked Sendable {
        let cache: NSCache<NSString, CachedGlyphLine> = {
            let cache = NSCache<NSString, CachedGlyphLine>()
            cache.countLimit = 4_096
            cache.name = "org.oppi.MathCoreGraphicsRenderer.ctLine"
            return cache
        }()
    }

    private static let glyphLineStore = GlyphLineStore()

    private final class CachedGlyphLine: @unchecked Sendable {
        let line: CTLine
        init(_ line: CTLine) { self.line = line }
    }

    private static func colorKey(_ color: CGColor) -> String {
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

    private func drawText(
        _ text: String,
        fontSize: CGFloat,
        baseline: CGFloat,
        in context: CGContext,
        foreground: CGColor
    ) {
        let key = "\(fontSize)|\(Self.colorKey(foreground))|\(text)" as NSString
        let line: CTLine
        if let hit = Self.glyphLineStore.cache.object(forKey: key) {
            line = hit.line
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): MathFont.shared.font(size: fontSize),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
            ]
            let attrString = NSAttributedString(string: text, attributes: attributes)
            line = CTLineCreateWithAttributedString(attrString)
            Self.glyphLineStore.cache.setObject(
                CachedGlyphLine(line),
                forKey: key,
                cost: max(1, text.utf8.count)
            )
        }

        // CTLineDraw expects CG coordinates (Y-up), but UIKit context is Y-down.
        // Flip locally around the baseline.
        context.saveGState()
        context.translateBy(x: 0, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

// MARK: - Layout Result

/// Cached layout result for the renderer.
///
/// Holds the positioned box tree and the configuration used to produce it.
/// Passed from `layout()` to `draw()` — the separation allows layout
/// caching while keeping draw calls cheap.
struct MathRenderLayout: Sendable {
    let rootBox: LayoutBox
    let configuration: RenderConfiguration
}
