import Observation
import UIKit

/// A shell route whose page is pinned to one server: Server Settings and Usage.
///
/// A page never swaps servers itself. Each page is made for one server and holds its
/// store, model, and every action for that server only. This route resolves the visible
/// server (`ServerSelection.resolveVisible`: the active server, else the one the route
/// opened for) and shows that server's page; when the visible server changes, a
/// subclass closes what the old page pushed (`willReplace`) and the route replaces the
/// page with a new one. A response that lands after the switch settles into the old
/// page's own model, which nothing shows any more.
///
/// The page's server switcher is the bar item (the page writes it to this route's
/// navigation item, `UIViewController.pinnedRouteNavigationItem`); this route adds the
/// split detail root's sidebar toggle. The route tracks the selection itself, because a
/// page pushed above it hides its view and a hidden view's `updateProperties()` does not
/// run, so a switch made from the sidebar would otherwise not reach it.
@MainActor
class PinnedServerRouteViewController<Page: UIViewController>: UIViewController, PinnedServerRouting {
    /// The split detail root carries the sidebar toggle.
    var showsSidebarToggle: Bool {
        didSet {
            guard showsSidebarToggle != oldValue else { return }
            setNeedsUpdateProperties()
        }
    }

    let root: AppRootEnvironment
    /// The server the route opened for: the visible one while none is active.
    let openedServerId: String?
    /// The server the page on screen is pinned to; nil while none is paired.
    private(set) var pinnedServerId: String?
    private(set) var page: Page?
    private let makePage: (PairedServer) -> Page
    private var hasShownPage = false
    private var sidebarToggle: UIBarButtonItem?
    private var isFinishing = false

    init(
        root: AppRootEnvironment,
        openedServerId: String?,
        showsSidebarToggle: Bool,
        title: String,
        makePage: @escaping (PairedServer) -> Page
    ) {
        self.root = root
        self.openedServerId = openedServerId
        self.showsSidebarToggle = showsSidebarToggle
        self.makePage = makePage
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var coordinator: ConnectionCoordinator { root.coordinator }

    /// The visible server: the active one, else the one this route opened for.
    /// Reads what a switch changes, so it can be tracked.
    private func visibleServer() -> PairedServer? {
        ServerSelection.resolveVisible(
            activeId: coordinator.activeServerId,
            frozenId: openedServerId,
            from: coordinator.serverStore.servers
        )
    }

    // MARK: - Hooks

    /// Closes what `page` pushed, before the route replaces it.
    func willReplace(_ page: Page) {}

    /// What the route shows while no server is paired for it.
    func unavailableContent(palette: ThemePalette) -> UIContentUnavailableConfiguration {
        ControlScreenList.unavailable(
            String(localized: "Server Unavailable"),
            systemImage: "server.rack",
            description: String(localized: "This paired server is no longer available."),
            palette: palette
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

    /// Shows the visible server's page. A different server closes what the old page
    /// pushed, then replaces it.
    private func reconcile() {
        guard !isFinishing, isViewLoaded else { return }
        let server = visibleServer()
        guard !hasShownPage || server?.id != pinnedServerId else { return }
        hasShownPage = true
        if let page { willReplace(page) }
        removePage()
        pinnedServerId = server?.id
        // The old page's bar items are not the new page's.
        navigationItem.rightBarButtonItems = nil
        guard let server else {
            var unavailable = unavailableContent(palette: root.themeStore.activeThemeID.palette)
            unavailable.background.backgroundColor = root.themeStore.backgroundColor
            contentUnavailableConfiguration = unavailable
            return
        }
        contentUnavailableConfiguration = nil
        let page = makePage(server)
        embed(page)
        self.page = page
    }

    private func removePage() {
        guard let page else { return }
        self.page = nil
        page.willMove(toParent: nil)
        page.view.removeFromSuperview()
        page.removeFromParent()
    }

    private func embed(_ page: Page) {
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

/// A route that shows one pinned page and owns the navigation bar for it.
@MainActor
protocol PinnedServerRouting: UIViewController {}

extension UIViewController {
    /// The navigation item a pinned page's bar shows: its route's when the page is
    /// embedded in one, its own otherwise (a preview, a test).
    var pinnedRouteNavigationItem: UINavigationItem {
        (parent as? any PinnedServerRouting)?.navigationItem ?? navigationItem
    }
}

/// The server switcher in a pinned page's bar: a menu of the paired servers, for the
/// server the page is pinned to. Choosing another changes the visible server, and the
/// route then replaces the page.
@MainActor
final class PinnedServerSwitcher {
    private var switcher: SessionListServerSwitcher?
    private var loadedMetrics = false

    func update(
        server: PairedServer,
        destination: HostSwitcherDestination,
        root: AppRootEnvironment,
        traits: UITraitCollection,
        item: UINavigationItem
    ) {
        let coordinator = root.coordinator
        let joinsRail = SessionListBarItems.joinsRail(traits)
        let model = HostSwitcherModel(
            coordinator: coordinator,
            serverStore: coordinator.serverStore,
            navigation: root.navigation,
            current: server,
            destination: destination
        )
        if let switcher, switcher.joinsRail == joinsRail {
            switcher.update(model)
        } else {
            switcher = SessionListServerSwitcher(model: model, joinsRail: joinsRail)
        }
        guard let switcher else { return }
        let trailing = [joinsRail ? SessionListBarItems.railItem(switcher.item, priority: .keep) : switcher.item]
        if !(item.rightBarButtonItems ?? []).elementsEqual(trailing, by: ===) {
            item.rightBarButtonItems = trailing
        }
        if !loadedMetrics {
            loadedMetrics = true
            // Once per connection: a known value is never refetched.
            Task { await model.loadServerMetricsEnabled() }
        }
    }
}
