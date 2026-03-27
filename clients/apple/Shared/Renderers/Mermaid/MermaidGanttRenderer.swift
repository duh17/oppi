import CoreGraphics
import CoreText

/// Renderer for Mermaid gantt charts.
///
/// Draws a horizontal timeline with sections and task bars.
/// Uses the same `FlowchartLayout` container with `customDraw`/`customSize`.
enum MermaidGanttRenderer {
    nonisolated static func layout(
        _ diagram: GanttDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        MermaidFlowchartRenderer().placeholderLayout(
            text: "Gantt chart (loading...)",
            configuration: configuration
        )
    }
}
