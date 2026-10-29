#if DEBUG
import notify
import SwiftUI
import UIKit

/// Launch-argument dispatch for the debug harnesses and screenshot previews.
///
/// This folder (clients/apple/OppiDebugHarness) compiles into the Oppi app
/// target in Debug only; Release excludes it (`EXCLUDED_SOURCE_FILE_NAMES` in
/// project.yml). `OppiApp.makeRootViewController()` calls `rootViewController`
/// under `#if DEBUG`, and that call is the app's only reference to this folder.
@MainActor
enum DebugHarnessLaunch {
    /// The window root for the harness or screenshot preview the launch
    /// arguments chose, or nil for the app.
    static func rootViewController(root: AppRootEnvironment) -> UIViewController? {
        if ReviewCommentStashHarnessConfig.isEnabled {
            return ReviewCommentStashHarnessController(root: root)
        }
        guard let controller = makeHarnessRoot(root: root, generation: HarnessLaunchReset.isEnabled ? 0 : nil) else { return nil }
        if HarnessLaunchReset.isEnabled {
            HarnessLaunchReset.install(root: root, controller: controller)
        }
        return controller
    }

    /// A fresh harness window root. `generation` is the reuse generation the
    /// root publishes as its marker (`HarnessLaunchReset`); nil for a launch
    /// that is not reused.
    static func makeHarnessRoot(root: AppRootEnvironment, generation: UInt64?) -> HarnessRootViewController? {
        guard let harness = harnessView else { return nil }
        // Harnesses and previews render app screens, the timeline, and
        // UIKit-hosted SwiftUI without the app's root controller. The
        // router and HostFactory need the app root above them there too,
        // and the window needs the theme applied the way the app root does.
        return HarnessRootViewController(
            content: HostFactory.content(harness, root: root),
            themeStore: root.themeStore,
            resetGeneration: generation
        )
    }

    /// The harness or screenshot preview chosen by launch arguments, or nil
    /// for the app.
    private static var harnessView: AnyView? {
        if HTMLDOMAnnotationHarnessConfig.isEnabled {
            return AnyView(HTMLDOMAnnotationHarnessView().ignoresSafeArea())
        }
        if WikiLineAnchorHarnessConfig.isEnabled {
            return AnyView(WikiLineAnchorHarnessView().ignoresSafeArea())
        }
        if SemanticPickHarnessConfig.isEnabled {
            return AnyView(SemanticPickHarnessView().ignoresSafeArea())
        }
        if FullScreenReviewCommentHarnessConfig.isEnabled {
            return AnyView(FullScreenReviewCommentHarnessView().ignoresSafeArea())
        }
        if CodeGutterAlignmentHarnessConfig.isEnabled {
            return AnyView(CodeGutterAlignmentHarnessView().ignoresSafeArea())
        }
        if CodeBlockWrappingHarnessConfig.isEnabled {
            return AnyView(CodeBlockWrappingHarnessView().ignoresSafeArea())
        }
        if ChatOutlineColdHarnessConfig.isEnabled {
            return AnyView(ChatOutlineColdHarnessView())
        }
        if NavigationChromeProfileConfig.isEnabled {
            return AnyView(NavigationChromeProfileHarnessView())
        }
        if UIHangHarnessConfig.isEnabled {
            return AnyView(UIHangHarnessView())
        }
        if ScreenshotPreviewConfig.isEnabled {
            return AnyView(ScreenshotPreviewView())
        }
        return nil
    }
}

/// The window root for debug harnesses and screenshot previews, which render
/// app screens without `AppRootViewController`: it applies the theme to the
/// window the same way, so a preview's sheets match its content.
final class HarnessRootViewController: UIViewController {
    private let themeStore: ThemeStore
    private let content: UIViewController
    private let appLock = AppLockService.shared
    private let resetGeneration: UInt64?

    init(content: UIViewController, themeStore: ThemeStore, resetGeneration: UInt64? = nil) {
        self.content = content
        self.themeStore = themeStore
        self.resetGeneration = resetGeneration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
        if let resetGeneration {
            view.addSubview(HarnessLaunchReset.markerView(generation: resetGeneration))
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: Self, _: UITraitCollection) in
            controller.themeStore.followSystemAppearance(from: controller)
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        themeStore.applyToWindow(of: self)
    }

    override func updateProperties() {
        super.updateProperties()
        themeStore.applyToWindow(of: self)
        // VoiceOver skips the harness content while the App Lock cover
        // window is up above it.
        content.view.accessibilityElementsHidden = appLock.isLocked
    }
}

/// Opt-in launch reuse for debug harnesses and previews: a UI test class sets
/// `OPPI_TEST_REUSE_LAUNCH=1` and keeps one app launch across its tests. Between
/// tests it posts the Darwin notification `dev.chenda.Oppi.test.reset` with a
/// generation as the notification state (`QAVerificationSupport/OppiTestLaunch.swift`
/// repeats these names). The app then runs the launch contract's reset in process
/// (`TestLaunchContract.applyInProcessReset`), dismisses what is presented, and
/// swaps the window root for a fresh harness root. That root carries the
/// generation as `harness.reset.generation`, so a test can fail with the stale
/// marker when a reset did not take. Nothing is written to persistent defaults
/// beyond the contract's own bookkeeping, and a launch without the environment
/// never listens.
@MainActor
final class HarnessLaunchReset {
    static let launchKey = "OPPI_TEST_REUSE_LAUNCH"
    static let notificationName = "dev.chenda.Oppi.test.reset"
    static let markerID = "harness.reset.generation"

    static var isEnabled: Bool { ProcessInfo.processInfo.environment[launchKey] == "1" }

    private static var installed: HarnessLaunchReset?

    private let root: AppRootEnvironment
    private weak var current: HarnessRootViewController?
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    private init(root: AppRootEnvironment) {
        self.root = root
    }

    static func install(root: AppRootEnvironment, controller: HarnessRootViewController) {
        guard installed == nil else { return }
        let reset = HarnessLaunchReset(root: root)
        reset.current = controller
        installed = reset
        reset.listen()
    }

    /// An invisible accessibility element that names the generation this root was built for.
    static func markerView(generation: UInt64) -> UIView {
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        marker.alpha = 0.02
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = markerID
        marker.accessibilityLabel = "Harness reset generation"
        marker.accessibilityValue = String(generation)
        return marker
    }

    private func listen() {
        notify_register_dispatch(Self.notificationName, &token, DispatchQueue.main) { [weak self] registered in
            var state: UInt64 = 0
            notify_get_state(registered, &state)
            MainActor.assumeIsolated { self?.reset(generation: state) }
        }
    }

    private func reset(generation: UInt64) {
        guard let window = current?.view.window else { return }
        TestLaunchContract.applyInProcessReset(generation: generation)
        window.endEditing(true)
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        guard let fresh = DebugHarnessLaunch.makeHarnessRoot(root: root, generation: generation) else { return }
        current = fresh
        window.rootViewController = fresh
    }
}
#endif
