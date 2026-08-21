import CoreGraphics
import Foundation

/// Thin dispatcher for native Mermaid diagrams.
///
/// Flowchart (+ state-as-flowchart) stays on `MermaidFlowchartRenderer`.
/// Sequence, gantt, mindmap, pie, timeline, class, and ER have dedicated
/// renderers. New diagram types hook in with one `MermaidDiagram` case
/// plus one switch arm here.
struct MermaidRenderer: GraphicalDocumentRenderer, Sendable {
    typealias Document = MermaidDiagram
    typealias LayoutResult = MermaidFlowchartRenderer.FlowchartLayout

    private let flowchartRenderer = MermaidFlowchartRenderer()

    nonisolated func layout(
        _ document: MermaidDiagram,
        configuration: RenderConfiguration
    ) -> LayoutResult {
        switch document {
        case .flowchart, .state:
            return flowchartRenderer.layout(document, configuration: configuration)
        case .sequence(let diagram):
            return MermaidSequenceRenderer.layout(diagram, configuration: configuration)
        case .gantt(let diagram):
            return MermaidGanttRenderer.layout(diagram, configuration: configuration)
        case .mindmap(let diagram):
            return MermaidMindmapRenderer.layout(diagram, configuration: configuration)
        case .pie(let diagram):
            return MermaidPieRenderer.layout(diagram, configuration: configuration)
        case .timeline(let diagram):
            return MermaidTimelineRenderer.layout(diagram, configuration: configuration)
        case .classDiagram(let diagram):
            return MermaidClassRenderer.layout(diagram, configuration: configuration)
        case .erDiagram(let diagram):
            return MermaidERRenderer.layout(diagram, configuration: configuration)
        case .unsupported(let type):
            return flowchartRenderer.placeholderLayout(
                text: "Unsupported diagram type: \(type)",
                configuration: configuration
            )
        }
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
}
