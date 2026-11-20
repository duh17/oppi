import CoreGraphics
import Foundation

/// Thin dispatcher for native Mermaid diagrams.
///
/// The renderer owns semantic diagram fills only. Its full canvas stays
/// transparent so inline, file, focused, and export surfaces each own their
/// intended background. `MermaidFlowchartRenderer.layout` owns the per-kind
/// dispatch: flowchart (+ state-as-flowchart) stays there; the other kinds
/// use dedicated renderers that return its layout bag.
struct MermaidRenderer: GraphicalDocumentRenderer, Sendable {
    typealias Document = MermaidDiagram
    typealias LayoutResult = MermaidFlowchartRenderer.FlowchartLayout

    private let flowchartRenderer = MermaidFlowchartRenderer()

    nonisolated func layout(
        _ document: MermaidDiagram,
        configuration: RenderConfiguration
    ) -> LayoutResult {
        flowchartRenderer.layout(document, configuration: configuration)
    }

    nonisolated func draw(
        _ layout: LayoutResult,
        in ctx: CGContext,
        at origin: CGPoint
    ) {
        flowchartRenderer.draw(layout, in: ctx, at: origin)
    }

    nonisolated func boundingBox(_ layout: LayoutResult) -> CGSize {
        flowchartRenderer.boundingBox(layout)
    }

    nonisolated func semanticAnnotationMap(
        source: String,
        document: MermaidDiagram,
        layout: LayoutResult
    ) -> SemanticAnnotationMap? {
        MermaidSemanticAnnotation.map(source: source, diagram: document, layout: layout)
    }
}
