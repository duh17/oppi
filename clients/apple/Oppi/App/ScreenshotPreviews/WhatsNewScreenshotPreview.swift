#if DEBUG
import SwiftUI

// MARK: - What’s New Preview

/// Renders the production What’s New view with an explicit Oppi theme.
///
/// The wrapper owns only deterministic preview setup; the screen content stays
/// in `WhatsNewView` so screenshot acceptance cannot drift from production UI.
struct WhatsNewScreenshotPreview: View {
    let themeID: ThemeID

    init(themeID: ThemeID) {
        self.themeID = themeID
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        WhatsNewView(onContinue: {})
            .environment(\.theme, themeID.appTheme)
            .environment(\.themeID, themeID)
            .tint(.themeBlue)
            .preferredColorScheme(themeID.preferredColorScheme)
            .onAppear {
                ThemeRuntimeState.setThemeID(themeID)
            }
            .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
