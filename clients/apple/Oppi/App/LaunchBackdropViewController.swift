import UIKit

/// What the window shows while pairing identity and the cache load, a brief
/// local-only gate: the theme's page color and nothing else, so the app opens
/// in the theme (Light or Dark) with no flash of the system background.
/// Network transport preparation begins after the paired shell appears.
@MainActor
final class LaunchBackdropViewController: UIViewController {
    private let themeStore: ThemeStore

    init(themeStore: ThemeStore) {
        self.themeStore = themeStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = themeStore.backgroundColor
    }

    override func updateProperties() {
        super.updateProperties()
        // Read here, so a theme change runs this again.
        view.backgroundColor = themeStore.backgroundColor
    }
}
