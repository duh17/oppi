#if DEBUG
import UIKit

/// Fixtures for `SCREENSHOT_SCREEN=viewing-options` (code: text size and wrap) and
/// `viewing-options-markdown` (text size and spacing): the production
/// `FullScreenViewingOptionsController` at the top of a themed page, full
/// width as in a compact sheet, at the height its sheet detent would take.
/// `ScreenshotPreviewView` mounts it. The real panel in the real reader is
/// `fullscreen-code` driven by `OPPI_UI_VALIDATE_TAPS=fullscreen.viewingOptions.button`.
/// Dump with `UIValidateTests`, `OPPI_UI_VALIDATE_READY=fullscreen.viewingOptions`.
enum ViewingOptionsScreenshotFixture {
    @MainActor
    static func makeController(family: FullScreenReaderContentFamily) -> UIViewController {
        let themeID: ThemeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light" ? .light : .dark
        ThemeRuntimeState.setThemeID(themeID)
        let page = PanelPageController(family: family)
        page.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        return page
    }

    private final class PanelPageController: UIViewController {
        private let options: FullScreenViewingOptionsController
        private let height: NSLayoutConstraint

        init(family: FullScreenReaderContentFamily) {
            options = FullScreenViewingOptionsController(
                family: family,
                preferences: FullScreenReaderPreferences(textScale: 1.15, spacing: .relaxed, wrapsText: true),
                onTextScaleChanged: { _ in },
                onWrappingChanged: { _ in },
                onSpacingChanged: { _ in },
                onReset: {}
            )
            height = options.view.heightAnchor.constraint(equalToConstant: 0)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .themeBg
            addChild(options)
            options.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(options.view)
            NSLayoutConstraint.activate([
                options.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                options.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                options.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                height,
            ])
            options.didMove(toParent: self)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // The sheet's detent: the panel's height at the page width, up to the screen.
            let available = view.bounds.height - view.safeAreaInsets.top
            let next = min(options.preferredSheetHeight, available)
            if height.constant != next { height.constant = next }
        }
    }
}
#endif
