import SwiftUI

/// Embeds ``FullScreenCodeViewController`` inside a SwiftUI NavigationStack.
///
/// The UIKit view controller provides its own internal `UINavigationController`
/// with Liquid Glass floating pills — identical chrome to the sheet presentation
/// used by the timeline full-screen viewer. The hosting SwiftUI view should hide
/// its navigation bar (`.toolbarVisibility(.hidden, for: .navigationBar)`) to
/// avoid double nav bars.
///
/// The dismiss (back) button calls SwiftUI's `dismiss()` to pop the navigation.
///
/// Usage:
/// ```swift
/// NavigationLink {
///     EmbeddedFileViewerView(
///         content: .fromText(text, filePath: path)
///     )
///     .ignoresSafeArea(edges: .top)
///     .toolbarVisibility(.hidden, for: .navigationBar)
/// } label: { ... }
/// ```
struct EmbeddedFileViewerView: UIViewControllerRepresentable {
    let content: FullScreenCodeContent
    var selectedTextPiRouter: SelectedTextPiActionRouter?
    var selectedTextSessionId: String?
    var selectedTextSourceLabel: String?

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> FullScreenCodeViewController {
        let dismissAction = dismiss
        return FullScreenCodeViewController(
            content: content,
            presentationMode: .embedded(onDismiss: { dismissAction() }),
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSessionId: selectedTextSessionId,
            selectedTextSourceLabel: selectedTextSourceLabel
        )
    }

    func updateUIViewController(
        _ uiViewController: FullScreenCodeViewController,
        context: Context
    ) {
        // Content is immutable — nothing to update.
    }
}
