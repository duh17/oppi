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

    static func `default`(maxWidth: CGFloat = 360) -> Self {
        RenderConfiguration(
            fontSize: 14,
            maxWidth: maxWidth,
            theme: .fallback,
            displayMode: .document
        )
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

    /// Neutral fallback for tests and platforms without theme context.
    static let fallback = RenderTheme(
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
        heading: CGColor(gray: 0.9, alpha: 1)
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
