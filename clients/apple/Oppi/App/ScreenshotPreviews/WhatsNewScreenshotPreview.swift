#if DEBUG
import SwiftUI
import UIKit

// MARK: - What’s New Preview

/// Renders the production What’s New controller with an explicit Oppi theme.
///
/// The wrapper owns only deterministic preview setup; the screen content stays
/// in `WhatsNewViewController` so screenshot acceptance cannot drift from
/// production UI. The controller reads its theme from an app root, so the
/// preview gives it one whose theme store holds `themeID`.
struct WhatsNewScreenshotPreview: UIViewControllerRepresentable {
    let themeID: ThemeID
    /// Scrolls the list to its end so the last rows can be reviewed. The
    /// screen is marked ready once the scroll has held for a moment.
    var scrollsToBottom = false

    func makeUIViewController(context: Context) -> WhatsNewViewController {
        // Before `ThemeStore()`: its setters would persist the theme.
        ScreenshotVolatileDefaults.applyTheme(themeID)
        let themeStore = ThemeStore()
        let root = AppRootEnvironment.preview(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            themeStore: themeStore
        )
        let controller = WhatsNewViewController { _ in }
        controller.traitOverrides.appRootEnvironment = root
        if scrollsToBottom {
            Task { @MainActor [weak controller] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let controller, let scrollView = controller.view.firstDescendant(UIScrollView.self) else { return }
                // The content size and offset keep changing for a few seconds
                // after the first frame (layout passes, safe-area updates), so
                // keep scrolling to the end until the capture has been taken.
                for pass in 0..<80 {
                    controller.view.setNeedsLayout()
                    controller.view.layoutIfNeeded()
                    let bottom = scrollView.contentSize.height - scrollView.bounds.height
                        + scrollView.adjustedContentInset.bottom
                    scrollView.setContentOffset(CGPoint(x: 0, y: max(bottom, 0)), animated: false)
                    if pass == 6 { controller.view.accessibilityIdentifier = "screenshot.ready" }
                    try? await Task.sleep(for: .seconds(0.25))
                }
            }
        } else {
            controller.view.accessibilityIdentifier = "screenshot.ready"
        }
        return controller
    }

    func updateUIViewController(_ controller: WhatsNewViewController, context: Context) {}
}

private extension UIView {
    func firstDescendant<T: UIView>(_ type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(type) { return match }
        }
        return nil
    }
}
#endif
