#if DEBUG
import notify
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
        let reuses = HarnessLaunchReset.isEnabled
        // Before a preview pins its own values in the argument domain.
        let launchArguments = reuses ? HarnessLaunchReset.argumentDomain : [:]
        guard let controller = makeHarnessRoot(root: root, generation: reuses ? 0 : nil) else { return nil }
        if reuses {
            // Nothing came before this root, so there is nothing to wait for.
            controller.publishResetMarker()
            HarnessLaunchReset.install(root: root, controller: controller, launchArguments: launchArguments)
        }
        return controller
    }

    /// A fresh harness window root. `generation` is the reuse generation the
    /// root publishes as its marker (`HarnessLaunchReset`); nil for a launch
    /// that is not reused.
    static func makeHarnessRoot(root: AppRootEnvironment, generation: UInt64?) -> HarnessRootViewController? {
        guard let content = harnessContent(root: root) else { return nil }
        // Harnesses and previews render app screens and the timeline without
        // the app's root controller. The window needs the app root above them
        // there too, and the theme applied the way the app root does.
        return HarnessRootViewController(
            content: content,
            themeStore: root.themeStore,
            resetGeneration: generation
        )
    }

    /// What the harness window root shows: the harness or screenshot preview
    /// the launch arguments chose, or nil for the app. A screenshot preview
    /// the build does not serve shows its name, after the UI-hang harness had
    /// its chance.
    private static func harnessContent(root: AppRootEnvironment) -> UIViewController? {
        if WikiLineAnchorHarnessConfig.isEnabled {
            return WikiLineAnchorHarnessViewController()
        }
        if SemanticPickHarnessConfig.isEnabled {
            return SemanticPickHarnessViewController()
        }
        if FullScreenReviewCommentHarnessConfig.isEnabled {
            return FullScreenReviewCommentHarnessViewController()
        }
        if CodeBlockWrappingHarnessConfig.isEnabled {
            return HarnessViewHostController(content: CodeBlockWrappingHarnessRootView())
        }
        if ScreenshotPreviewConfig.isEnabled, let preview = screenshotPreview(root: root) {
            return preview
        }
        if UIHangHarnessConfig.isEnabled {
            return UIHangHarnessViewController.screenStack(root: root)
        }
        if ScreenshotPreviewConfig.isEnabled {
            return PreviewHost.unknownScreen("Unknown screen: \(ScreenshotPreviewConfig.screen)")
        }
        return nil
    }

    /// The screenshot preview `SCREENSHOT_SCREEN` names (`--screenshot-preview`),
    /// or nil for a name this build does not serve.
    private static func screenshotPreview(root: AppRootEnvironment) -> UIViewController? {
        switch ScreenshotPreviewConfig.screen {
        case "ask-card-intent-regression": return AskCardIntentRegressionPreviewController()
        case "ask-card-tall-scroll": return AskCardTallScrollPreviewController()
        case "settings-sweep": return SettingsSweepPreviewController()
        case "workspace-settings": return WorkspaceSettingsPreviewController()
        case "settings-chat": return SettingsPagePreviewController(themeStore: root.themeStore)
        // The router family: its routes, the modal sites behind it, and the
        // shell those routes are drawn in.
        case "router-routes": return RouterRoutesPreviewController()
        case "router-modal-sites": return RouterModalSitesPreviewController()
        case "workspace-shell": return WorkspaceShellPreviewController()
        // The chat over the chat-routes fixtures. `chat-routes` pins the panel
        // buttons its tests drive; the top-bar screens pin the bar under test.
        case "chat-routes":
            return ChatRoutesPreviewController(root: root, topBar: ChatTopBarLayout(
                order: ChatTopBarAction.allCases, shown: [.files, .git, .outline, .context]
            ))
        case "chat-top-bar-default":
            return ChatRoutesPreviewController(root: root, topBar: ChatTopBarLayout(
                order: ChatTopBarAction.allCases, shown: ChatTopBarAction.defaultShown
            ))
        case "chat-top-bar-all":
            return ChatRoutesPreviewController(root: root, topBar: ChatTopBarLayout(
                order: ChatTopBarAction.allCases, shown: Set(ChatTopBarAction.allCases)
            ))
        case "chat-top-bar-reordered":
            return ChatRoutesPreviewController(root: root, topBar: ChatTopBarLayout(
                order: [.outline, .files, .context, .git, .terminal], shown: Set(ChatTopBarAction.allCases)
            ))
        case "session-timeline": return SessionTimelinePreviewController(root: root)
        // The files, terminal, and audio family: the motion captures, the
        // terminal's three fixture connections, and the script reader.
        case "file-browser-motion": return FileBrowserMotionPreviewController(review: false)
        case "review-file-motion": return FileBrowserMotionPreviewController(review: true)
        case "ssh-terminal": return SSHTerminalPreviewController()
        case "ssh-terminal-status-blocked": return SSHTerminalPreviewController(status: .blocked)
        case "ssh-terminal-rex-panes": return SSHTerminalPreviewController(status: .rexPanes)
        case "ssh-terminal-rex-list": return SSHTerminalRexListPreviewController()
        case "audio-script-reader": return AudioScriptReaderPreviewController(themeStore: root.themeStore)
        default: return nil
        }
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
/// tests it writes the next test's screen environment (the `SCREENSHOT_*` keys a
/// preview reads when it builds its root) as a JSON object to the file named by
/// `OPPI_TEST_REUSE_SCREEN_FILE`, then posts the Darwin notification
/// `dev.chenda.Oppi.test.reset` with a generation as the notification state
/// (`QAVerificationSupport/OppiTestLaunch.swift` repeats these names). The app
/// then swaps its `SCREENSHOT_*` environment for the file's, puts the argument
/// domain back to the launch's (a preview pins its theme and seeds there), runs
/// the launch contract's reset in process (`TestLaunchContract.applyInProcessReset`),
/// drops the process-wide caches and harness fixture records a fresh process would
/// not have, puts the persisted theme back, dismisses what is presented, and swaps
/// the window root for a fresh harness root. It publishes
/// the generation as `harness.reset.generation` only once the previous root and
/// its content are gone; if they are not, it publishes `harness.reset.failure`
/// with the reason instead, so a test fails on a leak rather than run on one.
/// Nothing is written to persistent defaults beyond the contract's own
/// bookkeeping, and a launch without the environment and a reset token never
/// listens.
@MainActor
final class HarnessLaunchReset {
    static let launchKey = "OPPI_TEST_REUSE_LAUNCH"
    static let screenFileKey = "OPPI_TEST_REUSE_SCREEN_FILE"
    static let screenEnvironmentPrefix = "SCREENSHOT_"
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
    private let launchArguments: [String: Any]
    private weak var current: HarnessRootViewController?
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    private init(root: AppRootEnvironment, launchArguments: [String: Any]) {
        self.root = root
        self.launchArguments = launchArguments
    }

    /// The argument domain as it stands: the launch arguments, plus whatever the
    /// harness root pinned there once it was built.
    static var argumentDomain: [String: Any] {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    static func install(root: AppRootEnvironment, controller: HarnessRootViewController, launchArguments: [String: Any]) {
        guard installed == nil else { return }
        let reset = HarnessLaunchReset(root: root, launchArguments: launchArguments)
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
        guard let current, let window = current.view.window else { return }
        do {
            try Self.applyScreenEnvironment()
        } catch {
            current.publishResetFailure("screen environment for generation \(generation) unreadable: \(error)")
            return
        }
        UserDefaults.standard.setVolatileDomain(launchArguments, forName: UserDefaults.argumentDomain)
        TestLaunchContract.applyInProcessReset(generation: generation)
        Self.resetProcessCaches()
        Self.resetHarnessFixtures()
        // The new root's state starts from the theme in effect when it is built, so the
        // last test's theme must be gone first; the old root restores its own on disappear.
        ThemeRuntimeState.setThemeID(ThemeID.loadPersisted())
        window.endEditing(true)

        let swapRoot = { [self] in
            let old = window.rootViewController as? HarnessRootViewController
            guard let fresh = DebugHarnessLaunch.makeHarnessRoot(root: root, generation: generation) else { return }
            self.current = fresh
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

    /// The next test's `SCREENSHOT_*` environment, from the file the test wrote
    /// before it posted the reset. A launch without the file key keeps its own.
    private static func applyScreenEnvironment() throws {
        guard let path = ProcessInfo.processInfo.environment[screenFileKey] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let next = try JSONDecoder().decode([String: String].self, from: data)
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix(screenEnvironmentPrefix) && next[key] == nil {
            unsetenv(key)
        }
        for (key, value) in next where key.hasPrefix(screenEnvironmentPrefix) {
            setenv(key, value, 1)
        }
    }

    /// What a harness or preview's fixture server recorded, kept process-wide
    /// for its labels: a fresh process starts each one empty.
    private static func resetHarnessFixtures() {
        RouterRoutesSaves.resetForTesting()
        SettingsSweepWrites.resetForTesting()
        ChatRoutesFixture.resetForTesting()
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
        FileBrowserViewOptionsStore.shared.resetForTesting()
    }
}

#endif
