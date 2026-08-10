import SwiftUI

/// Rendered LaTeX math with source toggle.
///
/// All chrome handled by ``RenderableDocumentView``.
struct LaTeXFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    var body: some View {
        RenderableDocumentWrapper(
            config: .latex,
            content: content,
            filePath: filePath,
            presentation: presentation,
            fullScreenContent: .latex(content: content, filePath: filePath),
            renderedViewFactory: { [content] in
                let config = RenderConfiguration(
                    fontSize: 20,
                    maxWidth: 600,
                    theme: ThemeRuntimeState.currentRenderTheme(),
                    displayMode: .document
                )
                let multiLayout = DocumentRenderPipeline.layoutLatexExpressions(
                    text: content, config: config
                )
                return Self.makeLatexView(multiLayout)
            }
        )
    }

    @MainActor
    private static func makeLatexView(_ layout: DocumentRenderPipeline.LatexMultiLayout) -> UIView {
        if let source = layout.exactSourceFallback {
            return DocumentRenderPipeline.makeLatexSourceFallbackView(
                source: source,
                palette: ThemeRuntimeState.currentPalette()
            )
        }

        let container = UIView()
        container.backgroundColor = .clear
        var yOffset: CGFloat = 0
        for (expr, source) in zip(layout.expressions, layout.sources) {
            let graphical = ZoomableGraphicalView(size: expr.size, draw: expr.draw)
            graphical.isAccessibilityElement = true
            graphical.accessibilityLabel = FlatSegment.formulaAccessibilityLabel(for: source)
            graphical.accessibilityTraits = [.image]
            graphical.semanticContentAttribute = .forceLeftToRight
            graphical.frame = CGRect(x: 0, y: yOffset, width: expr.size.width, height: max(expr.size.height, 30))
            container.addSubview(graphical)
            yOffset += max(expr.size.height, 30) + layout.spacing
        }
        let totalHeight = max(yOffset - layout.spacing, 0)
        container.frame = CGRect(x: 0, y: 0, width: layout.totalSize.width, height: totalHeight)
        return container
    }
}
