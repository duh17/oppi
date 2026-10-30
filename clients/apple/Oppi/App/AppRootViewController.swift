import UIKit

/// The window's root. UIKit owns what the window shows: the launch backdrop,
/// onboarding, or the workspace shell, with Quick Session
/// (`QuickSessionPresentation`) above them. It presents the app-wide modals
/// (`AppRootModals`: extension dialogs and notices, What's New), applies the
/// theme to the window, follows the system appearance in the theme's system
/// mode, hides the app from VoiceOver while App Lock covers it, and shows the
/// root prompts `OppiApp` raises. A DEBUG E2E launch also carries the
/// diagnostics the E2E tests read, beneath the content.
final class AppRootViewController: UIViewController {
    private enum Content: Equatable {
        case launching
        case pairedServersUnavailable
        case onboarding
        case shell
    }

    private let app: OppiApp
    private var root: AppRootEnvironment { app.root }
    private var navigation: AppNavigation { root.navigation }
#if DEBUG
    private var e2eDiagnostics: E2EDiagnosticsView?
#endif
    private var content: UIViewController?
    private var contentKind: Content?
    private var pairingWait: PairingWaitCoverViewController?
    private var pairingWaitExpiresAt: Int64?
    private weak var resourceChoiceAlert: UIAlertController?
    private var resourceChoiceShown: [String]?
    /// Workspace creation the shell starts (`oppi://workspace`, the guided first workspace):
    /// exists while the shell shows, so its state starts over with the next shell.
    private let workspaceCreation = WorkspaceCreationIntakeHolder()
    private lazy var modals = AppRootModals(root: root, anchor: self)
    private var mediaOverlay: WorkspaceMediaOverlayObserver?
    private lazy var quickSession = QuickSessionPresentation(root: root, host: self)
    /// The pairing approval sheet, over whatever the window shows.
    private lazy var pairingApprovals = PairingApprovalPresentation(
        controller: .shared, root: root, anchor: self
    )

#if DEBUG
    /// What the app-wide dialog slot holds, for an E2E's failure message.
    var modalDiagnostics: String { modals.dialogDebugSummary }
#endif

    init(app: OppiApp) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    /// The screen the status bar follows is the content showing, so a screen
    /// that paints its own background (the SSH terminal) can choose the clock's
    /// color. Quick Session covers the content with the app's own surface.
    override var childForStatusBarStyle: UIViewController? {
        navigation.showQuickSession ? nil : content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
#if DEBUG
        if E2EDiagnosticsView.isEnabled {
            let diagnostics = E2EDiagnosticsView(coordinator: root.coordinator)
            view.insertSubview(diagnostics, at: 0)
            e2eDiagnostics = diagnostics
        }
#endif
        mediaOverlay = WorkspaceMediaOverlayObserver(root: root)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: Self, _: UITraitCollection) in
            controller.root.themeStore.followSystemAppearance(from: controller)
        }
        PairingApprovalController.shared.startSyncing(coordinator: root.coordinator)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A request that came in before the window was up presents now.
        pairingApprovals.anchorDidAppear()
        workspaceCreation.anchorDidAppear()
        modals.anchorDidAppear()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        applyTheme()
    }

    override func updateProperties() {
        super.updateProperties()
        applyTheme()
        showContent(Self.content(for: navigation, pairedServersUnavailable: app.pairedServersUnavailable))
        updateWorkspaceCreation()
        modals.update()

        // Quick Session takes the screen: the content under it neither takes
        // touches nor reads to VoiceOver.
        quickSession.update()
        let showsQuickSession = navigation.showQuickSession
        if let quickSessionView = quickSession.controller?.view {
            view.bringSubviewToFront(quickSessionView)
        }
        setNeedsStatusBarAppearanceUpdate()
        content?.view.isUserInteractionEnabled = !showsQuickSession
        content?.view.accessibilityElementsHidden = showsQuickSession

        pairingApprovals.update()

        // A Quick Session parked during launch/onboarding can run now that the
        // root shows the shell.
        root.opener.presentationDidUpdate()
        showPairingWait(expiresAt: root.opener.invitePairingWaitExpiresAt)
        // The App Lock cover sits in its own window above this one.
        view.accessibilityElementsHidden = AppLockService.shared.isLocked
        showResourceChoice(root.opener.pendingResourceReferenceChoice)
    }

    /// Only the shell starts workspace creation by itself.
    private func updateWorkspaceCreation() {
        workspaceCreation.update(showsShell: contentKind == .shell, root: root, anchor: self)
    }

    private static func content(for navigation: AppNavigation, pairedServersUnavailable: Bool) -> Content {
        switch navigation.launchPhase {
        case .resolving: pairedServersUnavailable ? .pairedServersUnavailable : .launching
        case .ready: navigation.showOnboarding ? .onboarding : .shell
        }
    }

    // MARK: Theme

    private func applyTheme() {
        // Observation tracking re-runs `updateProperties` when the theme changes.
        root.themeStore.applyToWindow(of: self)
        // Behind the content: what shows if a layout change leaves a gap.
        view.backgroundColor = root.themeStore.backgroundColor
    }

    // MARK: Content

    private func showContent(_ kind: Content) {
        guard kind != contentKind else { return }
        contentKind = kind
        if let content {
            unembed(content)
        }
        let next: UIViewController = switch kind {
        case .launching: LaunchBackdropViewController(themeStore: root.themeStore)
        case .pairedServersUnavailable: Self.pairedServersUnavailableScreen { [weak app] in
            app?.retryPairedServerLoad()
        }
        case .onboarding: OnboardingViewController(root: root)
        case .shell: WorkspaceShellController(root: root)
        }
        content = next
        embed(next, at: contentIndex)
        setNeedsStatusBarAppearanceUpdate()
    }

    /// The saved servers could not be read with the device unlocked. The
    /// pairings may be intact, so this is never onboarding.
    private static func pairedServersUnavailableScreen(retry: @escaping @MainActor () -> Void) -> UIViewController {
        let screen = UIViewController()
        let palette = ThemeRuntimeState.currentPalette()
        screen.view.backgroundColor = UIColor(palette.bg)
        screen.contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
            .failed(
                title: String(localized: "Can\u{2019}t Read Saved Servers"),
                message: String(localized: "Oppi can\u{2019}t read its saved servers. Unlock your device or restart Oppi."),
                retry: RetryAction(run: retry)
            ),
            palette: palette,
            background: UIColor(palette.bg)
        )
        return screen
    }

    private func showPairingWait(expiresAt: Int64?) {
        guard expiresAt != pairingWaitExpiresAt else { return }
        pairingWaitExpiresAt = expiresAt
        if let pairingWait {
            unembed(pairingWait)
            self.pairingWait = nil
        }
        guard let expiresAt else { return }
        let cover = PairingWaitCoverViewController(expiresAt: expiresAt) { [weak opener = app.root.opener] in
            opener?.cancelInvitePairing()
        }
        embed(cover, at: view.subviews.count)
        pairingWait = cover
    }

    private func embed(_ child: UIViewController, at index: Int) {
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(child.view, at: index)
        child.didMove(toParent: self)
    }

    /// The content sits at the bottom, above only the E2E diagnostics.
    private var contentIndex: Int {
#if DEBUG
        e2eDiagnostics == nil ? 0 : 1
#else
        0
#endif
    }

    private func unembed(_ child: UIViewController) {
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }

    // MARK: Resource choice

    /// `[[target]]` matched more than one resource: an action sheet asks which.
    private func showResourceChoice(_ choice: PendingResourceReferenceChoice?) {
        let identity = choice.map { [$0.reference.target] + $0.matches.map(\.id) }
        guard identity != resourceChoiceShown else { return }
        resourceChoiceShown = identity
        // Answered, cancelled, or superseded by a newer tap.
        resourceChoiceAlert?.dismiss(animated: true)
        resourceChoiceAlert = nil
        guard let choice else { return }
        let alert = UIAlertController(
            title: String(localized: "Choose a resource"),
            message: String(localized: "[[\(choice.reference.target)]] matches more than one resource."),
            preferredStyle: .actionSheet
        )
        for match in choice.matches {
            let action = UIAlertAction(title: match.choiceLabel, style: .default) { [weak opener = app.root.opener] _ in
                opener?.startOpeningResourceReferenceMatch(match)
            }
            action.accessibilityLabel = match.accessibilityLabel
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak opener = app.root.opener] _ in
            opener?.cancelResourceReferenceRequest()
        })
        resourceChoiceAlert = alert
        AlertAnchor.present(alert, from: self, anchor: nil)
    }
}

extension ThemeStore {
    /// The window root's half of the theme: the window takes the theme's color
    /// scheme, and in the theme's system mode the theme follows the system
    /// appearance the window then shows. Without it a system-mode store keeps
    /// the scheme it guessed at launch, so router sheets (whose navigation
    /// controllers leave system mode to the window) drew light bars and titles
    /// over a dark palette. Call from `updateProperties()` and on appearance.
    func applyToWindow(of root: UIViewController) {
        root.view.window?.overrideUserInterfaceStyle = userInterfaceStyle
        followSystemAppearance(from: root)
    }

    /// Call on a `UITraitUserInterfaceStyle` change of the window root too.
    func followSystemAppearance(from root: UIViewController) {
        followSystemAppearance(root.traitCollection.userInterfaceStyle)
    }
}
