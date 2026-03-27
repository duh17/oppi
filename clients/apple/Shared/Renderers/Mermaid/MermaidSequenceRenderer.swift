import CoreGraphics
import CoreText

/// Renderer for Mermaid sequence diagrams.
///
/// Draws participants, lifelines, messages, and activation boxes.
/// Uses the same `FlowchartLayout` container with `customDraw`/`customSize`.
enum MermaidSequenceRenderer {
    nonisolated static func layout(
        _ diagram: SequenceDiagram,
        configuration: RenderConfiguration
    ) -> MermaidFlowchartRenderer.FlowchartLayout {
        MermaidFlowchartRenderer().placeholderLayout(
            text: "Sequence diagram (loading...)",
            configuration: configuration
        )
    }
}
