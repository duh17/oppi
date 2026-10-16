import UIKit

/// The window's root. UIKit owns what the window shows: the launch backdrop,
/// onboarding, or the workspace shell, with the app root's SwiftUI layer
/// (`AppRootLayer`) beneath them for app-wide modals and the Quick Session
/// overlay. It also applies the theme to the window, follows the system
/// appearance in the theme's system mode, hides the app from VoiceOver while
/// App Lock covers it, and shows the root prompts `OppiApp` raises.
final class AppRootViewController: UIViewController {
    private enum Content: Equatable {
        case launching
        case onboarding
        case shell
    }

    private let app: OppiApp
    private var root: AppRootEnvironment { app.root }
    private var navigation: AppNavigation { root.navigation }
    private let layer: HostedContentController
    private var content: UIViewController?
    private var contentKind: Content?
    private var pairingWait: HostedContentController?
    private var pairingWaitExpiresAt: Int64?
    private weak var resourceChoiceAlert: UIAlertController?
    private var resourceChoiceShown: [String]?

    init(app: OppiApp) {
        self.app = app
        layer = HostFactory.content(AppRootLayer(root: app.root), root: app.root)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        layer.view.backgroundColor = .clear
        embed(layer, at: 0)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (root: Self, _: UITraitCollection) in
            root.followSystemAppearance()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        applyTheme()
    }

    override func updateProperties() {
        super.updateProperties()
        applyTheme()
        showContent(Self.content(for: navigation))

        // The overlay takes the screen: the content under it neither takes
        // touches nor reads to VoiceOver.
        let showsQuickSession = navigation.showQuickSession
        if showsQuickSession {
            view.bringSubviewToFront(layer.view)
        } else {
            view.sendSubviewToBack(layer.view)
        }
        content?.view.isUserInteractionEnabled = !showsQuickSession
        content?.view.accessibilityElementsHidden = showsQuickSession

        showPairingWait(expiresAt: app.invitePairingWaitExpiresAt)
        // The App Lock cover sits in its own window above this one.
        view.accessibilityElementsHidden = AppLockService.shared.isLocked
        showResourceChoice(app.pendingResourceReferenceChoice)
    }

    private static func content(for navigation: AppNavigation) -> Content {
        switch navigation.launchPhase {
        case .resolving: .launching
        case .ready: navigation.showOnboarding ? .onboarding : .shell
        }
    }

    // MARK: Theme

    private func applyTheme() {
        // Observation tracking re-runs `updateProperties` when the theme changes.
        view.window?.overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        followSystemAppearance()
    }

    /// In the theme's system mode the window shows the system appearance;
    /// the theme follows it.
    private func followSystemAppearance() {
        root.themeStore.followSystemAppearance(traitCollection.userInterfaceStyle)
    }

    // MARK: Content

    private func showContent(_ kind: Content) {
        guard kind != contentKind else { return }
        contentKind = kind
        if let content {
            unembed(content)
        }
        let next: UIViewController = switch kind {
        case .launching: HostFactory.content(AppRootLayer.launchBackdrop, root: root)
        case .onboarding: HostFactory.screen(root: root) { OnboardingView() }
        case .shell: WorkspaceShellController(root: root)
        }
        content = next
        embed(next, above: layer)
    }

    private func showPairingWait(expiresAt: Int64?) {
        guard expiresAt != pairingWaitExpiresAt else { return }
        pairingWaitExpiresAt = expiresAt
        if let pairingWait {
            unembed(pairingWait)
            self.pairingWait = nil
        }
        guard let expiresAt else { return }
        let cover = HostFactory.content(
            AppRootLayer.pairingWaitCover(expiresAt: expiresAt) { [weak app] in app?.cancelInvitePairing() },
            root: root
        )
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

    private func embed(_ child: UIViewController, above sibling: UIViewController) {
        let index = view.subviews.firstIndex(of: sibling.view).map { $0 + 1 } ?? view.subviews.count
        embed(child, at: index)
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
            let action = UIAlertAction(title: match.choiceLabel, style: .default) { [weak app] _ in
                app?.startOpeningResourceReferenceMatch(match)
            }
            action.accessibilityLabel = match.accessibilityLabel
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak app] _ in
            app?.cancelResourceReferenceRequest()
        })
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        resourceChoiceAlert = alert
        Router.topPresenter(from: self).present(alert, animated: true)
    }
}
