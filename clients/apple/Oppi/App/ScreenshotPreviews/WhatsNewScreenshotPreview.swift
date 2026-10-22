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

    func makeUIViewController(context: Context) -> WhatsNewViewController {
        // Before `ThemeStore()`: its setters would persist the theme.
        ScreenshotVolatileDefaults.applyDarkTheme(themeID == .dark)
        let themeStore = ThemeStore()
        let root = AppRootEnvironment.preview(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            themeStore: themeStore
        )
        let controller = WhatsNewViewController { _ in }
        controller.traitOverrides.appRootEnvironment = root
        controller.view.accessibilityIdentifier = "screenshot.ready"
        return controller
    }

    func updateUIViewController(_ controller: WhatsNewViewController, context: Context) {}
}
#endif
