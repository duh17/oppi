import SwiftUI

/// Rendered CSV/TSV table with source toggle.
///
/// All chrome handled by ``RenderableDocumentView``.
struct DelimitedTableFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    var body: some View {
        let plan = resolvedPlan
        RenderableDocumentWrapper(
            config: .delimitedTable(kind: plan.kind),
            content: content,
            filePath: filePath,
            presentation: presentation,
            fullScreenContent: .delimitedTable(content: content, filePath: filePath),
            renderedViewFactory: {
                DelimitedTableRenderView(plan: plan)
            }
        )
    }

    private var resolvedPlan: DelimitedTableViewerPlan {
        DelimitedTableViewerPlan.resolved(path: filePath, text: content)
    }
}
