import Observation
import UIKit

/// The shell's `.serverDetails` route: Server Settings for the visible server.
///
/// Server Settings follows the host switcher, but a page never swaps servers
/// itself: each `ServerSettingsViewController` is pinned to one server for its
/// whole life (its store, its model, and every action it runs). This screen
/// resolves the visible server (`ServerSelection.resolveVisible`: the active
/// server, else the one the route opened for) and shows that server's page.
/// When the visible server changes it pops whatever was pushed above it,
/// since those pages are pinned to the old server too, and replaces the page.
/// A response that lands after the switch settles into the old page's own
/// model, which nothing shows any more.
///
/// The switcher is the page's bar item (it writes it to this screen's
/// navigation item); this screen adds the split detail root's sidebar toggle.
@MainActor
final class ServerSettingsRouteViewController: UIViewController {
    let target: ServerDetailsNavTarget
    /// The split detail root carries the sidebar toggle.
    var showsSidebarToggle: Bool {
        didSet {
            guard showsSidebarToggle != oldValue else { return }
            setNeedsUpdateProperties()
        }
    }

    let root: AppRootEnvironment
    /// The server the page on screen is pinned to; nil while none is paired.
    private(set) var pinnedServerId: String?
    private(set) var page: ServerSettingsViewController?
    private var hasShownPage = false
    private var sidebarToggle: UIBarButtonItem?
    private var isFinishing = false

    init(target: ServerDetailsNavTarget, root: AppRootEnvironment, showsSidebarToggle: Bool = false) {
        self.target = target
        self.root = root
        self.showsSidebarToggle = showsSidebarToggle
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
        title = HostSwitcherDestination.serverSettings.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var coordinator: ConnectionCoordinator { root.coordinator }

    /// The visible server: the active one, else the one this route opened for.
    /// Reads what a switch changes, so it can be tracked.
    private func visibleServer() -> PairedServer? {
        ServerSelection.resolveVisible(
            activeId: coordinator.activeServerId,
            frozenId: target.serverId,
            from: coordinator.serverStore.servers
        )
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        reconcile()
        observeSelection()
    }

    override func updateProperties() {
        super.updateProperties()
        view.backgroundColor = root.themeStore.backgroundColor
        reconcile()
        updateLeadingItems()
    }

    /// A page pushed above this screen hides its view, and a hidden view's
    /// `updateProperties()` does not run. Tracking the selection itself is what
    /// lets a switch made from the sidebar pop that page.
    private func observeSelection() {
        withObservationTracking {
            _ = visibleServer()?.id
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconcile()
                self.observeSelection()
            }
        }
    }

    /// Remove Server was confirmed: this screen is about to close, so the server
    /// the removal makes the active one must not get a page of its own.
    func willFinish() {
        isFinishing = true
    }

    func finish() {
        isFinishing = true
        Router.finish(self)
    }

    // MARK: - Page

    /// Shows the visible server's page. A different server pops the pages above
    /// this screen first, then replaces the page.
    private func reconcile() {
        guard !isFinishing, isViewLoaded else { return }
        let server = visibleServer()
        guard !hasShownPage || server?.id != pinnedServerId else { return }
        hasShownPage = true
        popToSelf()
        removePage()
        pinnedServerId = server?.id
        // The old page's bar items are not the new page's.
        navigationItem.rightBarButtonItems = nil
        guard let server else {
            showUnavailable()
            return
        }
        contentUnavailableConfiguration = nil
        let page = ServerSettingsViewController(server: server, root: root)
        embed(page)
        self.page = page
    }

    private func popToSelf() {
        guard let navigation = navigationController,
              navigation.viewControllers.contains(self),
              navigation.topViewController !== self else { return }
        navigation.popToViewController(self, animated: false)
    }

    private func removePage() {
        guard let page else { return }
        self.page = nil
        page.willMove(toParent: nil)
        page.view.removeFromSuperview()
        page.removeFromParent()
    }

    private func embed(_ page: ServerSettingsViewController) {
        addChild(page)
        page.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page.view)
        NSLayoutConstraint.activate([
            page.view.topAnchor.constraint(equalTo: view.topAnchor),
            page.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        page.didMove(toParent: self)
    }

    private func showUnavailable() {
        var unavailable = ControlScreenList.unavailable(
            "Server Unavailable",
            systemImage: "server.rack",
            description: "This paired server is no longer available.",
            palette: root.themeStore.activeThemeID.palette
        )
        unavailable.background.backgroundColor = root.themeStore.backgroundColor
        contentUnavailableConfiguration = unavailable
    }

    // MARK: - Bar

    private func updateLeadingItems() {
        var leading: [UIBarButtonItem] = []
        if showsSidebarToggle {
            let toggle = sidebarToggle ?? WorkspaceSplitSidebarToggle.makeItem(root: root)
            sidebarToggle = toggle
            WorkspaceSplitSidebarToggle.sync(toggle, root: root)
            leading = [toggle]
        }
        if !(navigationItem.leftBarButtonItems ?? []).elementsEqual(leading, by: ===) {
            navigationItem.leftBarButtonItems = leading
        }
    }
}
