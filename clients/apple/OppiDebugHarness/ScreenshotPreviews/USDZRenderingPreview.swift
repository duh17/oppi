#if DEBUG
import Foundation
import SwiftUI

// MARK: - USDZ inspect preview

/// Production RealityView USDZ viewer. Not a snapshot Image.
struct USDZRenderingPreview: View {
    private let themeID: ThemeID

    init() {
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light
            : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        Group {
            if let url = Bundle.main.url(
                forResource: "suzanne-garden",
                withExtension: "usdz"
            ) {
                FileBrowserUSDZPreview(fileURL: url, accessibilityName: "Suzanne garden")
            } else {
                Text("Missing suzanne-garden.usdz")
                    .foregroundStyle(.red)
            }
        }
        .preferredColorScheme(themeID == .light ? .light : .dark)
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
