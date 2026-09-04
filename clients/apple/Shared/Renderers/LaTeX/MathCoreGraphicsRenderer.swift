import CoreGraphics
import CoreText
import Foundation

/// Renders `[MathNode]` into a Core Graphics context via a two-phase pipeline.
///
/// Phase 1 — `layout()`: converts the AST into a `LayoutBox` tree with
/// computed positions and sizes using `MathLayoutEngine`.
///
/// Phase 2 — `draw()`: walks the `LayoutBox` tree and draws glyphs and
/// lines into a `CGContext` using Core Text and Core Graphics.
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
        let rootBox = engine.layout(document, fontSize: configuration.fontSize)
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

        // Translate to origin. Layout uses top-left coordinates which match
        // UIKit's context (Y-down). Text is drawn with local Y-flips via drawGlyph.
        context.translateBy(x: origin.x, y: origin.y)

        drawBox(layout.rootBox, in: context, foreground: layout.configuration.theme.foreground)
    }

    // MARK: - Bounding Box

    nonisolated func boundingBox(_ layout: MathRenderLayout) -> CGSize {
        layout.rootBox.size
    }

    // MARK: - Recursive Drawing

    /// Recursively draw a layout box and its children.
    private func drawBox(
        _ box: LayoutBox,
        in context: CGContext,
        foreground: CGColor
    ) {
        context.saveGState()
        context.translateBy(x: box.origin.x, y: box.origin.y)

        switch box.content {
        case .glyph(let text, let fontSize):
            drawGlyph(text, fontSize: fontSize, in: context, foreground: foreground)

        case .line(let from, let to, let thickness):
            drawLine(from: from, to: to, thickness: thickness, in: context, foreground: foreground)

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

    private func drawGlyph(
        _ text: String,
        fontSize: CGFloat,
        in context: CGContext,
        foreground: CGColor
    ) {
        let key = "\(fontSize)|\(Self.colorKey(foreground))|\(text)" as NSString
        let line: CTLine
        if let hit = Self.glyphLineStore.cache.object(forKey: key) {
            line = hit.line
        } else {
            let font = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foreground,
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
        // Flip locally around the text position.
        context.saveGState()
        context.translateBy(x: 0, y: fontSize)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Line Drawing

    private func drawLine(
        from: CGPoint,
        to: CGPoint,
        thickness: CGFloat,
        in context: CGContext,
        foreground: CGColor
    ) {
        context.setStrokeColor(foreground)
        context.setLineWidth(thickness)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
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
