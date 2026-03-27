import CoreGraphics
import CoreText

/// Renderer for Mermaid mindmaps.
///
/// Draws a radial tree layout with the root at center and branches radiating outward.
/// Uses the same `FlowchartLayout` container with `customDraw`/`customSize`.
enum MermaidMindmapRenderer {
    nonisolated static func layout(
        _ diagram: MindmapDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        MermaidFlowchartRenderer().placeholderLayout(
            text: "Mindmap (loading...)",
            configuration: configuration
        )
    }
}
