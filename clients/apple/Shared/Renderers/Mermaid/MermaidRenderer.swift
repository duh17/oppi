import CoreGraphics
import Foundation

/// Thin dispatcher for native Mermaid diagrams.
///
/// The renderer owns semantic diagram fills only. Its full canvas stays
/// transparent so inline, file, focused, and export surfaces each own their
/// intended background. Flowchart (+ state-as-flowchart) stays on
/// `MermaidFlowchartRenderer`; the other kinds use dedicated renderers.
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
        case .xyChart(let diagram):
            return MermaidXYChartRenderer.layout(diagram, configuration: configuration)
        case .gitGraph(let diagram):
            return MermaidGitGraphRenderer.layout(diagram, configuration: configuration)
        case .quadrantChart(let diagram):
            return MermaidQuadrantRenderer.layout(diagram, configuration: configuration)
        case .sankey(let diagram):
            return MermaidSankeyRenderer.layout(diagram, configuration: configuration)
        case .kanban(let diagram):
            return MermaidKanbanRenderer.layout(diagram, configuration: configuration)
        case .journey(let diagram):
            return MermaidJourneyRenderer.layout(diagram, configuration: configuration)
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
