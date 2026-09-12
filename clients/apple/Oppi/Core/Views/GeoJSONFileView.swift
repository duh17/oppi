import SwiftUI

/// Rendered GeoJSON/TopoJSON map with source toggle.
///
/// All chrome handled by ``RenderableDocumentView``.
struct GeoJSONFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    var body: some View {
        let plan = resolvedPlan
        RenderableDocumentWrapper(
            config: .geoJSON(kind: plan.kind),
            content: content,
            filePath: filePath,
            presentation: presentation,
            fullScreenContent: .geoJSON(content: content, filePath: filePath),
            renderedViewFactory: {
                GeoJSONMapView(plan: plan)
            }
        )
    }

    private var resolvedPlan: GeoJSONViewerPlan {
        GeoJSONViewerPlan.resolved(path: filePath, text: content)
    }
}
