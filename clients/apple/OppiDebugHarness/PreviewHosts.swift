#if DEBUG
import UIKit

/// UIKit hosts shared by the previews that are their own window root: the router
/// stack a preview's screen sits in, the `screenshot.ready` marker a capture or
/// UI test waits on, and the window's fixture app root. They replace what a
/// preview got from modifiers on its SwiftUI body (`RouterPreviewControllerStack`,
/// `.accessibilityIdentifier("screenshot.ready")`,
/// `.publishesAppRootToWindow(_:)`); the previews still dispatched as SwiftUI
/// views keep using those.
@MainActor
enum PreviewHost {
    /// A preview's screen at the root of a `RouterNavigationController`, the way
    /// the router presents a screen with `.inNavigation()`: the screen carries
    /// the fixture app root in its traits, and the navigation follows the theme's
    /// interface style. The app puts the theme's appearance on its window and
    /// system chrome that reads the window, such as the Duo's vertical rail,
    /// follows it there; a harness's window keeps the system appearance, which
    /// drew a light rail beside a dark chat, so the navigation asks for the
    /// theme's scheme itself.
    static func screenStack(
        root: AppRootEnvironment,
        screen makeScreen: @escaping () -> UIViewController
    ) -> RouterNavigationController {
        let screen = makeScreen()
        screen.traitOverrides.appRootEnvironment = root
        let navigation = RouterNavigationController(rootViewController: screen)
        let themeStore = root.themeStore
        navigation.interfaceStyle = { themeStore.userInterfaceStyle }
        return navigation
    }

    /// Publishes `screenshot.ready` in `host`, the marker the screenshot guard and
    /// the UI test lanes wait on. SwiftUI stamped the preview body with it; on a
    /// view that would take a screen's own identifier with it, so one marker view
    /// carries it instead (`HarnessLaunchReset.markerView`'s pattern, which
    /// XCUITest already reads at 0.02 alpha).
    static func publishScreenshotReady(in host: UIViewController) {
        guard host.view.viewWithTag(screenshotReadyTag) == nil else { return }
        host.view.addSubview(HarnessLaunchReset.markerView(
            id: "screenshot.ready", value: "ready", tag: screenshotReadyTag
        ))
    }

    /// Publishes `root` as the window's app root, for UIKit code anywhere in the
    /// window and for a sheet presented by a controller that does not carry the
    /// fixture root in its own traits: the UIKit form of
    /// `.publishesAppRootToWindow(_:)`.
    static func publishAppRootToWindow(_ root: AppRootEnvironment, from host: UIViewController) {
        host.view.window?.traitOverrides.appRootEnvironment = root
    }

    /// Pins `child` to `parent`'s view edges.
    static func fill(_ parent: UIViewController, with child: UIViewController) {
        parent.addChild(child)
        child.view.frame = parent.view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
    }

    /// A page the launch names but this build does not serve, where the SwiftUI
    /// previews said `Text("Unknown …")`: a deleted sub-page key shows in the
    /// run instead of as an empty window.
    static func unknownScreen(_ message: String) -> UIViewController {
        let controller = UIViewController()
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16),
        ])
        return controller
    }

    private static let screenshotReadyTag = 0x0F51_0011
}

/// A preview that is its own window root: the fixture app root in the
/// controller's traits, its screen filling the view, the `screenshot.ready`
/// marker, and the window's theme and app root, which every preview that is its
/// own controller had spelled out separately.
@MainActor
class PreviewRootController: UIViewController {
    private let root: AppRootEnvironment
    private let themeStore: ThemeStore
    private let content: UIViewController

    init(root: AppRootEnvironment, themeStore: ThemeStore, content: UIViewController) {
        self.root = root
        self.themeStore = themeStore
        self.content = content
        super.init(nibName: nil, bundle: nil)
        // Sheets a screen presents find the fixture root here even when they
        // leave the screen's own trait chain (the window carries it too).
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = themeStore.backgroundColor
        PreviewHost.fill(self, with: content)
        PreviewHost.publishScreenshotReady(in: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Before the first frame a reader waits on `screenshot.ready` for: the
        // window's style comes from the app root's theme store, which was built
        // before this preview pinned `SCREENSHOT_COLOR_SCHEME`, so put this
        // preview's scheme on the window as `.preferredColorScheme` did for the
        // SwiftUI body of these previews.
        themeStore.applyToWindow(of: self)
        PreviewHost.publishAppRootToWindow(root, from: self)
    }
}

/// A screen a preview shows once one fixture fact is in place: a spinner until
/// `prepare` returns, then `content`. The settings pages need this for the
/// server's capabilities (`/server/info`, which the Skill file editor reads
/// before it opens a file) and for the catalog cache on disk, which outlives
/// launches and would show an earlier page's catalog.
@MainActor
final class PreviewLoadingController: UIViewController {
    private let prepare: () async -> Void
    private let makeContent: () -> UIViewController
    private var task: Task<Void, Never>?
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(prepare: @escaping () async -> Void, content: @escaping () -> UIViewController) {
        self.prepare = prepare
        self.makeContent = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        // The task holds the controller weakly across `prepare`, so a window that
        // drops the preview reaches this and cancels work the fixture may never
        // finish.
        task?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()
        let prepare = prepare
        task = Task { @MainActor [weak self] in
            await prepare()
            guard !Task.isCancelled, let self else { return }
            self.spinner.stopAnimating()
            self.spinner.removeFromSuperview()
            PreviewHost.fill(self, with: self.makeContent())
        }
    }
}
#endif
