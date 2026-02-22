import SwiftUI
import UIKit

/// Full-screen content viewer for tool output.
///
/// Supports three modes:
/// - `.code`: syntax-highlighted source with line numbers
/// - `.diff`: unified diff with add/remove coloring
/// - `.markdown`: full markdown note/reader rendering
enum FullScreenCodeContent {
    case code(content: String, language: String?, filePath: String?, startLine: Int)
    case diff(oldText: String, newText: String, filePath: String?, precomputedLines: [DiffLine]?)
    case markdown(content: String, filePath: String?)
}

/// SwiftUI wrapper around ``FullScreenCodeViewController``.
///
/// Used by `.fullScreenCover` in `FileContentView`, `MarkdownText`,
/// and `DiffContentView`. All rendering is UIKit.
struct FullScreenCodeView: UIViewControllerRepresentable {
    let content: FullScreenCodeContent

    func makeUIViewController(context: Context) -> FullScreenCodeViewController {
        FullScreenCodeViewController(content: content)
    }

    func updateUIViewController(_ uiViewController: FullScreenCodeViewController, context: Context) {
        // Content is immutable — nothing to update.
    }
}
