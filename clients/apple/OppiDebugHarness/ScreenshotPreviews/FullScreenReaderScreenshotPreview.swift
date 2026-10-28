#if DEBUG
import UIKit

/// Fixtures for `SCREENSHOT_SCREEN=fullscreen-code` and `fullscreen-markdown`:
/// the production full-screen reader over a short code or Markdown document,
/// so a UIValidate drive can tap `fullscreen.viewingOptions.button` and capture
/// the real Viewing Options panel (a sheet in compact width, a popover in
/// regular width). `ScreenshotPreviewView` mounts it.
enum FullScreenReaderScreenshotFixture {
    enum Kind {
        case code, markdown
    }

    @MainActor
    static func makeController(kind: Kind) -> UIViewController {
        let themeID: ThemeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light" ? .light : .dark
        ThemeRuntimeState.setThemeID(themeID)
        let content: FullScreenCodeContent = switch kind {
        case .code:
            .code(
                content: "func greet(_ name: String) -> String {\n    \"Hello, \\(name)\"\n}\n",
                language: "swift",
                filePath: "Greeter.swift",
                startLine: 1
            )
        case .markdown:
            .markdown(content: "# Reader\n\nSome **Markdown** to read.\n\n- one\n- two\n", filePath: "notes.md")
        }
        let viewer = FullScreenCodeViewController.makeHarnessController(
            content: content,
            reviewCommentSelectionContext: nil
        )
        viewer.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        return viewer
    }
}
#endif
