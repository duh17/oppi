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
            // Nothing came before this root, so there is nothing to wait for.
            controller.publishResetMarker()
            HarnessLaunchReset.install(root: root, controller: controller)
        }
        return controller
    }

    /// A fresh harness window root. `generation` is the reuse generation the
    /// root publishes as its marker (`HarnessLaunchReset`); nil for a launch
    /// that is not reused.
    static func makeHarnessRoot(root: AppRootEnvironment, generation: UInt64?) -> HarnessRootViewController? {
        guard let content = harnessContent(root: root) else { return nil }
        // Harnesses and previews render app screens, the timeline, and
        // UIKit-hosted SwiftUI without the app's root controller. The
        // router and HostFactory need the app root above them there too,
        // and the window needs the theme applied the way the app root does.
        return HarnessRootViewController(
            content: content,
            themeStore: root.themeStore,
            resetGeneration: generation
        )
    }

    /// What the harness window root shows: a harness's own UIKit controller
    /// when it has one, else `HostFactory.content` around its SwiftUI view
    /// until T16-z moves the rest off the SwiftUI dispatch.
    private static func harnessContent(root: AppRootEnvironment) -> UIViewController? {
        if let controller = uiKitHarness(root: root) {
            return controller
        }
        guard let harness = harnessView else { return nil }
        return HostFactory.content(harness, root: root)
    }

    /// The harnesses that are their own UIKit screen, so the window hosts a
    /// controller instead of a SwiftUI representable. Each family that drops
    /// its wrappers adds its configs here.
    private static func uiKitHarness(root: AppRootEnvironment) -> UIViewController? {
        if HTMLDOMAnnotationHarnessConfig.isEnabled {
            return HTMLDOMAnnotationHarnessViewController()
        }
        if WikiLineAnchorHarnessConfig.isEnabled {
            return WikiLineAnchorHarnessViewController()
        }
        if SemanticPickHarnessConfig.isEnabled {
            return SemanticPickHarnessViewController()
        }
        if FullScreenReviewCommentHarnessConfig.isEnabled {
            return FullScreenReviewCommentHarnessViewController()
        }
        if CodeGutterAlignmentHarnessConfig.isEnabled {
            return HarnessViewHostController(content: CodeGutterAlignmentHarnessRootView())
        }
        if CodeBlockWrappingHarnessConfig.isEnabled {
            return HarnessViewHostController(content: CodeBlockWrappingHarnessRootView())
        }
        // The ask-card and settings previews are UIKit roots too, so the preview
        // switch (`ScreenshotPreviewView`) no longer carries them.
        if ScreenshotPreviewConfig.isEnabled {
            if ScreenshotPreviewConfig.screen == "ask-card-intent-regression" {
                return AskCardIntentRegressionPreviewController()
            }
            if ScreenshotPreviewConfig.screen == "ask-card-tall-scroll" {
                return AskCardTallScrollPreviewController()
            }
            if ScreenshotPreviewConfig.screen == "settings-sweep" {
                return SettingsSweepPreviewController()
            }
            if ScreenshotPreviewConfig.screen == "workspace-settings" {
                return WorkspaceSettingsPreviewController()
            }
            if ScreenshotPreviewConfig.screen == "settings-chat"
                || ScreenshotPreviewConfig.screen == "settings-chat-top-bar" {
                return SettingsPagePreviewController(
                    screen: ScreenshotPreviewConfig.screen,
                    themeStore: root.themeStore
                )
            }
            // The router family: its routes, the modal sites behind it, and the
            // shell those routes are drawn in.
            if ScreenshotPreviewConfig.screen == "router-routes" {
                return RouterRoutesPreviewController()
            }
            if ScreenshotPreviewConfig.screen == "router-modal-sites" {
                return RouterModalSitesPreviewController()
            }
            if ScreenshotPreviewConfig.screen == "workspace-shell" {
                return WorkspaceShellPreviewController()
            }
            // The files, terminal, and audio family: the motion captures, the
            // terminal's three fixture connections, and the script reader.
            switch ScreenshotPreviewConfig.screen {
            case "file-browser-motion": return FileBrowserMotionPreviewController(review: false)
            case "review-file-motion": return FileBrowserMotionPreviewController(review: true)
            case "ssh-terminal": return SSHTerminalPreviewController()
            case "ssh-terminal-status-blocked": return SSHTerminalPreviewController(status: .blocked)
            case "ssh-terminal-rex-panes": return SSHTerminalPreviewController(status: .rexPanes)
            case "ssh-terminal-rex-list": return SSHTerminalRexListPreviewController()
            case "audio-script-reader": return AudioScriptReaderPreviewController(themeStore: root.themeStore)
            default: break
            }
        }
        return nil
    }

    /// The SwiftUI harness or screenshot preview chosen by launch arguments, or
    /// nil for the app.
    private static var harnessView: AnyView? {
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
    let content: UIViewController
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
        PreviewHost.fill(self, with: content)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: Self, _: UITraitCollection) in
            controller.themeStore.followSystemAppearance(from: controller)
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        themeStore.applyToWindow(of: self)
    }

    /// Publishes the reuse generation this root was built for, once.
    func publishResetMarker() {
        guard let resetGeneration, view.viewWithTag(HarnessLaunchReset.markerTag) == nil else { return }
        view.addSubview(HarnessLaunchReset.markerView(
            id: HarnessLaunchReset.markerID, value: String(resetGeneration), tag: HarnessLaunchReset.markerTag
        ))
    }

    /// Says why a reset could not be vouched for, in place of the generation marker.
    func publishResetFailure(_ reason: String) {
        guard view.viewWithTag(HarnessLaunchReset.failureTag) == nil else { return }
        view.addSubview(HarnessLaunchReset.markerView(
            id: HarnessLaunchReset.failureID, value: reason, tag: HarnessLaunchReset.failureTag
        ))
    }

    override func updateProperties() {
        super.updateProperties()
        themeStore.applyToWindow(of: self)
        // VoiceOver skips the harness content while the App Lock cover
        // window is up above it.
        content.view.accessibilityElementsHidden = appLock.isLocked
    }
}

/// A harness screen that is a bare view, refreshing its own diagnostics (the
/// code gutter and code block harnesses).
@MainActor
protocol HarnessDiagnosticsView: UIView {
    func updateDiagnostics()
}

/// Hosts a harness screen that is a bare view, refreshing its diagnostics as
/// the SwiftUI representable's `updateUIView` did.
@MainActor
final class HarnessViewHostController<Content: HarnessDiagnosticsView>: UIViewController {
    private let content: Content

    init(content: Content) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        content.updateDiagnostics()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.updateDiagnostics()
    }
}

/// Opt-in launch reuse for debug harnesses and previews: a UI test class sets
/// `OPPI_TEST_REUSE_LAUNCH=1` and keeps one app launch across its tests. Between
/// tests it posts the Darwin notification `dev.chenda.Oppi.test.reset` with a
/// generation as the notification state (`QAVerificationSupport/OppiTestLaunch.swift`
/// repeats these names). The app then runs the launch contract's reset in process
/// (`TestLaunchContract.applyInProcessReset`), drops the process-wide caches a
/// fresh process would not have, puts the persisted theme back, dismisses what is
/// presented, and swaps the window root for a fresh harness root. It publishes
/// the generation as `harness.reset.generation` only once the previous root and
/// its content are gone; if they are not, it publishes `harness.reset.failure`
/// with the reason instead, so a test fails on a leak rather than run on one.
/// Nothing is written to persistent defaults beyond the contract's own
/// bookkeeping, and a launch without the environment and a reset token never
/// listens.
@MainActor
final class HarnessLaunchReset {
    static let launchKey = "OPPI_TEST_REUSE_LAUNCH"
    static let notificationName = "dev.chenda.Oppi.test.reset"
    static let markerID = "harness.reset.generation"
    static let failureID = "harness.reset.failure"
    static let markerTag = 0x0F51_0001
    static let failureTag = 0x0F51_0002

    /// Run-loop turns (50 ms apart) the previous root and content get to be released before the reset is failed.
    private static let releaseAttempts = 20

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[launchKey] == "1"
            && UserDefaults.standard.string(forKey: TestLaunchContract.resetTokenKey) != nil
    }

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

    /// An invisible accessibility element carrying `value`.
    static func markerView(id: String, value: String, tag: Int) -> UIView {
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        marker.tag = tag
        marker.alpha = 0.02
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = id
        marker.accessibilityLabel = value
        marker.accessibilityValue = value
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
        Self.resetProcessCaches()
        // The new root's state starts from the theme in effect when it is built, so the
        // last test's theme must be gone first; the old root restores its own on disappear.
        ThemeRuntimeState.setThemeID(ThemeID.loadPersisted())
        window.endEditing(true)

        let swapRoot = { [self] in
            let old = window.rootViewController as? HarnessRootViewController
            guard let fresh = DebugHarnessLaunch.makeHarnessRoot(root: root, generation: generation) else { return }
            current = fresh
            window.rootViewController = fresh
            let released = ReleasedCheck(old: old, content: old?.content)
            confirmReleased(released, fresh: fresh, attempt: 0)
        }
        if let presenter = window.rootViewController, presenter.presentedViewController != nil {
            presenter.dismiss(animated: false, completion: swapRoot)
        } else {
            swapRoot()
        }
    }

    /// Weak references only: the check must not be what keeps the old root alive.
    private struct ReleasedCheck {
        weak var old: HarnessRootViewController?
        weak var content: UIViewController?
        var survivors: [String] {
            var names: [String] = []
            if old != nil { names.append("HarnessRootViewController") }
            if content != nil { names.append("its content controller") }
            return names
        }
    }

    private func confirmReleased(_ released: ReleasedCheck, fresh: HarnessRootViewController, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self, weak fresh] in
            MainActor.assumeIsolated {
                guard let self, let fresh else { return }
                let survivors = released.survivors
                if survivors.isEmpty {
                    fresh.publishResetMarker()
                } else if attempt >= Self.releaseAttempts {
                    fresh.publishResetFailure("previous harness still alive after reset: \(survivors.joined(separator: ", "))")
                } else {
                    self.confirmReleased(released, fresh: fresh, attempt: attempt + 1)
                }
            }
        }
    }

    /// One entry point per cache owner, so a reused test runs as cold as a launched one.
    private static func resetProcessCaches() {
        ToolRowRenderCache.evictAll()
        MarkdownSegmentCache.shared.clearAll()
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        NativeExpandedToolViewCaches.resetForTesting()
        ImageDecodeCache.resetForTesting()
        SyntaxHighlighter.resetCachesForTesting()
        ANSIRenderingCaches.resetForTesting()
        DiffAttributedStringBuilder.resetCachesForTesting()
        NativeMarkdownImageView.resetCachesForTesting()
        FeatureEducationTipPresentationCoordinator.shared.resetForTesting()
        InlineVideoStillFrameStore.shared.removeAll()
    }
}
#endif
