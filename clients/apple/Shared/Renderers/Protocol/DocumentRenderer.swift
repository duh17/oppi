import CoreGraphics
import CoreText
import Foundation

// MARK: - Render Output

/// Output produced by a document renderer.
///
/// Two rendering strategies depending on format:
/// - Text-based formats (org mode) produce attributed strings rendered in text views.
/// - Graphical formats (LaTeX math, Mermaid, Graphviz) produce draw commands for Core Graphics.
enum RenderOutput: @unchecked Sendable {
    /// Attributed string for text view rendering (UITextView / NSTextView).
    /// Used by text-based formats (org mode, future markup formats).
    case attributedString(NSAttributedString)

    /// Positioned elements for Core Graphics `draw(rect:)`.
    /// Used by graphical formats (LaTeX math, diagrams).
    case graphical(GraphicalRenderResult)
}

/// Result of a graphical layout + render pass.
///
/// Contains positioned elements ready to draw in a CGContext,
/// plus the bounding box for scroll view content sizing.
struct GraphicalRenderResult: Sendable {
    /// Total size of the rendered content.
    let boundingBox: CGSize

    /// Draw the content into the given context at the given origin.
    /// Called from UIView.draw / NSView.draw.
    let draw: @Sendable (CGContext, CGPoint) -> Void
}

// MARK: - Render Configuration

/// Configuration passed to renderers.
///
/// Contains theme, font size, and display constraints shared across
/// all renderer types. Platform-agnostic — uses CGColor for colors.
struct RenderConfiguration: Sendable {
    /// Base font size in points. Renderers scale relative to this.
    let fontSize: CGFloat

    /// Available width for text wrapping and layout.
    let maxWidth: CGFloat

    /// Theme colors for rendering.
    let theme: RenderTheme

    /// Display mode hint. Some formats render differently
    /// in inline vs fullscreen (e.g. LaTeX display mode vs inline mode).
    let displayMode: RenderDisplayMode

    /// Tallest the surface shows content before scaling it down (the inline
    /// diagram cap). Nil when the surface scrolls or zooms instead
    /// (full screen, export), so height never shrinks the content.
    var maxDisplayHeight: CGFloat? = nil

    static func `default`(maxWidth: CGFloat = 360) -> Self {
        Self(
            fontSize: 14,
            maxWidth: maxWidth,
            theme: .fallback,
            displayMode: .document
        )
    }

    /// Scale the surface shows content of `size` at: 1 when it fits, else
    /// whatever fits it within `maxWidth` and `maxDisplayHeight`.
    func displayScale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        var scale = min(1, maxWidth / size.width)
        if let maxDisplayHeight {
            scale = min(scale, maxDisplayHeight / size.height)
        }
        return scale
    }
}

/// Picks among layouts of one diagram by the scale each will be shown at,
/// so text stays as large as possible on screen.
///
/// Candidates rank least change first, starting with the natural layout:
/// tighter spacing, then narrower wrapping, then a turned direction or an
/// alternate arrangement. The choice shows the largest; ties go to the
/// smaller change, and it never shows smaller than the natural layout.
struct RenderFitChoice<Candidate> {
    private(set) var best: Candidate
    private(set) var bestScale: CGFloat
    private var bestSize: CGSize
    private var bestRank = 0
    private let naturalWidth: CGFloat
    private let configuration: RenderConfiguration
    /// Only overflowing the width starts fitting. A diagram that fits the
    /// width keeps its natural layout even when the height cap shrinks it.
    let needsFit: Bool

    /// Scale gains below this are ties.
    private static var tolerance: CGFloat { 0.001 }

    init(natural: Candidate, size: CGSize, configuration: RenderConfiguration) {
        best = natural
        bestSize = size
        bestScale = configuration.displayScale(for: size)
        naturalWidth = size.width
        self.configuration = configuration
        needsFit = size.width > configuration.maxWidth + 0.5
    }

    /// Whether a candidate could still show larger than the best, so it is
    /// worth laying out. `minimumWidth` and `minimumHeight` are lower bounds
    /// on the candidate's size. A nil `minimumHeight` means the candidate is
    /// no shorter than the best so far: wrapping and turning trade width for
    /// height, so such a candidate cannot help once the height cap is what
    /// shrinks the best.
    func canImprove(minimumWidth: CGFloat, minimumHeight: CGFloat? = nil) -> Bool {
        guard needsFit, bestScale < 1 - Self.tolerance else { return false }
        var ceiling: CGFloat = minimumWidth > 0 ? min(1, configuration.maxWidth / minimumWidth) : 1
        if let cap = configuration.maxDisplayHeight {
            let height = minimumHeight ?? bestSize.height
            if height > 0 { ceiling = min(ceiling, cap / height) }
        }
        return ceiling > bestScale + Self.tolerance
    }

    /// Keeps `candidate` when it shows larger than the best so far, or as
    /// large with a smaller change. `changeRank` orders candidates by how
    /// much they change the drawing (natural is 0); callers that offer them
    /// least change first can omit it, and a tie then keeps the earlier one.
    /// Variants exist to narrow a diagram that overflows the width; one that
    /// comes out wider than the natural layout (packed parts rearranged into
    /// a shorter, wider block) is never used.
    mutating func consider(_ candidate: Candidate, size: CGSize, changeRank: Int? = nil) {
        guard size.width <= naturalWidth + 0.5 else { return }
        let scale = configuration.displayScale(for: size)
        let rank = changeRank ?? Int.max
        let wins = scale > bestScale + Self.tolerance
            || (scale >= bestScale - Self.tolerance && rank < bestRank)
        guard wins else { return }
        best = candidate
        bestScale = scale
        bestSize = size
        bestRank = rank
    }
}

enum RenderDisplayMode: Sendable {
    /// Compact rendering for inline tool output cards.
    case inline
    /// Full rendering for file browser and fullscreen views.
    case document
}

/// Theme colors for renderers.
///
/// Uses CGColor for cross-platform compatibility (iOS + Mac).
/// Platform-specific view code bridges from UIColor/NSColor when constructing.
struct RenderTheme: Sendable {
    let foreground: CGColor
    let foregroundDim: CGColor
    let background: CGColor
    let backgroundDark: CGColor
    let comment: CGColor
    let keyword: CGColor
    let string: CGColor
    let number: CGColor
    let function: CGColor
    let type: CGColor
    let link: CGColor
    let heading: CGColor
    let accentBlue: CGColor
    let accentCyan: CGColor
    let accentGreen: CGColor
    let accentOrange: CGColor
    let accentPurple: CGColor
    let accentRed: CGColor
    let accentYellow: CGColor

    /// Stable cycle for multi-series mermaid ink. Renderers must not invent hues.
    var diagramAccents: [CGColor] {
        [accentBlue, accentGreen, accentOrange, accentPurple, accentRed, accentYellow, accentCyan]
    }

    /// Every token a mermaid renderer may paint, including syntax-mapped inks.
    var paletteInks: [CGColor] {
        [
            foreground, foregroundDim, background, backgroundDark, comment,
            keyword, string, number, function, type, link, heading,
        ] + diagramAccents
    }

    /// Neutral fallback for tests and platforms without theme context.
    static let fallback = Self(
        foreground: CGColor(gray: 0.9, alpha: 1),
        foregroundDim: CGColor(gray: 0.6, alpha: 1),
        background: CGColor(gray: 0.12, alpha: 1),
        backgroundDark: CGColor(gray: 0.08, alpha: 1),
        comment: CGColor(gray: 0.45, alpha: 1),
        keyword: CGColor(red: 0.78, green: 0.46, blue: 0.92, alpha: 1),
        string: CGColor(red: 0.58, green: 0.79, blue: 0.39, alpha: 1),
        number: CGColor(red: 0.82, green: 0.58, blue: 0.34, alpha: 1),
        function: CGColor(red: 0.38, green: 0.68, blue: 0.94, alpha: 1),
        type: CGColor(red: 0.38, green: 0.68, blue: 0.94, alpha: 1),
        link: CGColor(red: 0.38, green: 0.68, blue: 0.94, alpha: 1),
        heading: CGColor(gray: 0.9, alpha: 1),
        accentBlue: CGColor(red: 0.38, green: 0.68, blue: 0.94, alpha: 1),
        accentCyan: CGColor(red: 0.47, green: 0.73, blue: 0.70, alpha: 1),
        accentGreen: CGColor(red: 0.58, green: 0.79, blue: 0.39, alpha: 1),
        accentOrange: CGColor(red: 0.82, green: 0.58, blue: 0.34, alpha: 1),
        accentPurple: CGColor(red: 0.78, green: 0.46, blue: 0.92, alpha: 1),
        accentRed: CGColor(red: 0.88, green: 0.43, blue: 0.45, alpha: 1),
        accentYellow: CGColor(red: 0.78, green: 0.71, blue: 0.47, alpha: 1)
    )

    /// Stable identity for raster caches and reusable renderer views.
    /// Every color that can affect graphical output participates.
    var renderIdentity: String {
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
            componentString(foreground), componentString(foregroundDim),
            componentString(background), componentString(backgroundDark),
            componentString(comment), componentString(keyword),
            componentString(string), componentString(number),
            componentString(function), componentString(type),
            componentString(link), componentString(heading),
            componentString(accentBlue), componentString(accentCyan),
            componentString(accentGreen), componentString(accentOrange),
            componentString(accentPurple), componentString(accentRed),
            componentString(accentYellow),
        ].joined(separator: ";")
    }

    /// Built-in light render theme for tests and light-mode exports.
    static let light = Self(
        foreground: CGColor(gray: 0.1, alpha: 1),
        foregroundDim: CGColor(gray: 0.4, alpha: 1),
        background: CGColor(gray: 1.0, alpha: 1),
        backgroundDark: CGColor(gray: 0.96, alpha: 1),
        comment: CGColor(gray: 0.55, alpha: 1),
        keyword: CGColor(red: 0.46, green: 0.38, blue: 0.66, alpha: 1),
        string: CGColor(red: 0.23, green: 0.52, blue: 0.31, alpha: 1),
        number: CGColor(red: 0.66, green: 0.46, blue: 0.19, alpha: 1),
        function: CGColor(red: 0.20, green: 0.47, blue: 0.78, alpha: 1),
        type: CGColor(red: 0.18, green: 0.54, blue: 0.51, alpha: 1),
        link: CGColor(red: 0.20, green: 0.47, blue: 0.78, alpha: 1),
        heading: CGColor(gray: 0.1, alpha: 1),
        accentBlue: CGColor(red: 0.20, green: 0.47, blue: 0.78, alpha: 1),
        accentCyan: CGColor(red: 0.18, green: 0.54, blue: 0.51, alpha: 1),
        accentGreen: CGColor(red: 0.23, green: 0.52, blue: 0.31, alpha: 1),
        accentOrange: CGColor(red: 0.66, green: 0.46, blue: 0.19, alpha: 1),
        accentPurple: CGColor(red: 0.46, green: 0.38, blue: 0.66, alpha: 1),
        accentRed: CGColor(red: 0.78, green: 0.31, blue: 0.35, alpha: 1),
        accentYellow: CGColor(red: 0.76, green: 0.61, blue: 0.24, alpha: 1)
    )
}

// MARK: - Renderer Protocols

/// Protocol for document renderers.
///
/// Renderers convert a parsed document AST into visual output.
/// Two specializations:
/// - `AttributedStringDocumentRenderer` for text-based formats
/// - `GraphicalDocumentRenderer` for diagram/math formats
///
/// Every renderer ships with:
/// - Render correctness tests (verify attributes or layout positions)
/// - Performance benchmarks (METRIC lines for parse-render pipeline)
protocol DocumentRenderer: Sendable {
    associatedtype Document: Equatable & Sendable

    /// Render a parsed document into visual output.
    nonisolated func render(_ document: Document, configuration: RenderConfiguration) -> RenderOutput
}

/// Convenience protocol for text-based renderers producing attributed strings.
///
/// Used by org mode and future markup renderers. Output goes directly into
/// UITextView (iOS) or NSTextView (Mac).
protocol AttributedStringDocumentRenderer: DocumentRenderer {
    /// Render directly to NSAttributedString.
    nonisolated func renderAttributedString(
        _ document: Document,
        configuration: RenderConfiguration
    ) -> NSAttributedString
}

extension AttributedStringDocumentRenderer {
    nonisolated func render(
        _ document: Document,
        configuration: RenderConfiguration
    ) -> RenderOutput {
        .attributedString(renderAttributedString(document, configuration: configuration))
    }
}

/// Protocol for graphical renderers (diagrams, math).
///
/// Separates layout (positioning) from drawing so layout can be cached
/// and drawing stays cheap on scroll/zoom.
protocol GraphicalDocumentRenderer: DocumentRenderer {
    associatedtype LayoutResult: Sendable

    /// Layout pass: compute positions and sizes.
    nonisolated func layout(
        _ document: Document,
        configuration: RenderConfiguration
    ) -> LayoutResult

    /// Draw pass: render positioned elements into a Core Graphics context.
    nonisolated func draw(
        _ layout: LayoutResult,
        in context: CGContext,
        at origin: CGPoint
    )

    /// Bounding box of the layout result for scroll view content sizing.
    nonisolated func boundingBox(_ layout: LayoutResult) -> CGSize

    /// Optional selection map. Default is none; renderers that emit regions override it.
    nonisolated func semanticAnnotationMap(
        source: String,
        document: Document,
        layout: LayoutResult
    ) -> SemanticAnnotationMap?
}

extension GraphicalDocumentRenderer {
    nonisolated func semanticAnnotationMap(
        source: String,
        document: Document,
        layout: LayoutResult
    ) -> SemanticAnnotationMap? {
        nil
    }
}

extension GraphicalDocumentRenderer {
    nonisolated func render(
        _ document: Document,
        configuration: RenderConfiguration
    ) -> RenderOutput {
        let layoutResult = layout(document, configuration: configuration)
        let box = boundingBox(layoutResult)
        return .graphical(GraphicalRenderResult(
            boundingBox: box,
            draw: { [self] ctx, origin in
                self.draw(layoutResult, in: ctx, at: origin)
            }
        ))
    }
}
