import UIKit

/// A screen's attached leaf: the panel it shows beside itself in its pane
/// host's companion slot, like an iPadOS inspector (the chat's Files, Git,
/// Outline, Context, Share and readers; a commit's diff; a review's file
/// list). An invisible child of the screen that asked for it: the screen
/// calls `show` with the panel (nil hides it), and presents the same panel
/// as a sheet instead where `opensBeside` is false (compact width, or no
/// host). A new panel id with the leaf already open replaces its content
/// without re-running the open transition; nil, from nothing, and from
/// something each animate. The panel is one UIKit screen at the root of the
/// leaf's own navigation controller.
///
/// It mounts while its screen is in the window, so a page pushed above the
/// screen, or a full-screen modal over it, parks the leaf
/// (`PaneHostController.parkCompanion`), and the leaf's own pushed pages
/// survive until the screen returns. A memory warning while parked drops the
/// leaf's screens; it is rebuilt from the panel when the screen returns.
final class AttachedLeafController: UIViewController {
    struct Panel {
        let id: AnyHashable
        let minWidth: CGFloat
        let idealWidth: CGFloat
        /// The soft ceiling of ordinary dragging; nil picks a width generous
        /// enough for most content without being the whole window.
        var maxWidth: CGFloat? = nil
        /// The panel's link, when it has one, so the window can restore it.
        var route: PaneStackEntry? = nil
        /// Builds the panel's UIKit screen when the leaf installs it.
        let makeScreen: () -> UIViewController

        var widths: PaneCompanionWidths {
            PaneCompanionWidths(minimum: minWidth, ideal: idealWidth, maximum: maxWidth)
        }
    }

    /// The divider was dragged or flung past the close threshold, same as
    /// the panel's own Close or Done. The owner closes the same way that
    /// control does, so the model stays the single source of truth and this
    /// leaf never reopens itself on the next update pass.
    var onDismissRequested: (() -> Void)?

    private weak var owningScreen: UIViewController?
    private var root: AppRootEnvironment?
    /// The panel the screen asked for last; installed once any panel being
    /// removed is gone.
    private var requested: Panel?
    /// The panel the leaf shows, mounted, parked, or dropped by a memory
    /// warning (then `container` is nil until the screen returns).
    private var installed: (id: AnyHashable, widths: PaneCompanionWidths, route: PaneStackEntry?)?
    private var container: RouterNavigationController?
    /// The host the leaf is mounted or parked in.
    private weak var host: PaneHostController?
    private var isMounted = false
    private var isOnScreen = false
    /// True while a removed panel waits for its search to end and slide out.
    private var isRemoving = false
    /// Work waiting for the panel being removed to be gone (`whenClosed`).
    private var closedWaiters: [() -> Void] = []

    init(screen: UIViewController) {
        owningScreen = screen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(memoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    /// Whether a panel opens beside the screen: a wide screen in a pane
    /// host's primary leaf. Elsewhere (compact width, a sheet, a screen
    /// inside a companion) the screen presents it as a sheet.
    var opensBeside: Bool {
        guard let owningScreen else { return false }
        return AdaptiveWidth.isWide(owningScreen.traitCollection) && PaneHostController.hosting(owningScreen) != nil
    }

    /// The screen in front inside the open panel, for the commands that ask
    /// what the panel shows.
    var frontScreen: UIViewController? { isMounted ? container?.topViewController : nil }

    func show(_ panel: Panel?, root: AppRootEnvironment?) {
        guard let panel, let root else {
            requested = nil
            removePanel()
            return
        }
        self.root = root
        requested = panel
        if let installed, installed.id == panel.id, !isRemoving {
            // Already open on this id: a content-only refresh (new widths
            // from the same screen) never replays the open transition.
            self.installed?.widths = panel.widths
            if let container { host?.updateCompanionWidths(container, panel.widths) }
            return
        }
        if installed != nil, !isRemoving {
            // A different panel while the leaf is open: swap the screen in
            // place. The width and full state are untouched, so the leaf
            // does not close and reopen for a second reflow.
            swapPanel(panel)
            return
        }
        removePanel()
    }

    /// Runs `body` once no panel is mounted: now when none is, otherwise
    /// after the one being removed has slid out and left the host. Close
    /// the panel (`show(nil, root:)`) first. A push onto the screen's stack
    /// waits for this: the close animates the host's layout, which under a
    /// running push transition left the screen's view out of the window
    /// after Back.
    func whenClosed(_ body: @escaping () -> Void) {
        guard installed != nil || isRemoving else {
            body()
            return
        }
        closedWaiters.append(body)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        attach(opening: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isOnScreen = false
        guard isMounted, let container, let host else { return }
        isMounted = false
        host.parkCompanion(container)
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        guard let themeStore = root?.themeStore else { return }
        container?.view.backgroundColor = themeStore.backgroundColor
    }

    /// The host's divider asked to close (`onDismissRequested`).
    func dividerRequestedClose() {
        onDismissRequested?()
    }

    private func makeContainer(_ panel: Panel) -> RouterNavigationController {
        let container = RouterNavigationController(rootViewController: panel.makeScreen())
        let themeStore = root?.themeStore
        container.interfaceStyle = { themeStore?.userInterfaceStyle ?? .unspecified }
        // The leaf lays out compact, as an inspector or a split view's side
        // column does. In a regular-width window an inset grouped list
        // (Context) misplaced and clipped its rows.
        container.traitOverrides.horizontalSizeClass = .compact
        container.view.backgroundColor = themeStore?.backgroundColor
        return container
    }

    private func installRequestedPanel() {
        guard let panel = requested, root != nil, installed == nil else { return }
        installed = (panel.id, panel.widths, panel.route)
        container = makeContainer(panel)
        setNeedsUpdateProperties()
        attach(opening: true)
    }

    /// Mounts the leaf in the screen's host while the screen is on screen.
    /// A leaf dropped by a memory warning is rebuilt from its panel here.
    private func attach(opening: Bool) {
        guard isOnScreen, !isMounted, !isRemoving, let installed,
              let owningScreen, let host = PaneHostController.hosting(owningScreen) else { return }
        if container == nil, let requested { container = makeContainer(requested) }
        guard let container else { return }
        self.host = host
        isMounted = true
        host.mountCompanion(container, widths: installed.widths, route: installed.route, owner: self, opening: opening)
    }

    private func swapPanel(_ panel: Panel) {
        let swap = { [weak self] in
            guard let self else { return }
            let old = self.container
            let new = self.makeContainer(panel)
            self.installed = (panel.id, panel.widths, panel.route)
            self.container = new
            if let old, self.isMounted, let host = self.host {
                host.replaceCompanion(old, with: new, widths: panel.widths, route: panel.route)
            } else if let old {
                self.host?.releaseParked(old)
            }
            self.setNeedsUpdateProperties()
        }
        guard let container else {
            swap()
            return
        }
        Router.endSearch(in: container, then: swap)
    }

    /// Removes the current panel, then installs the requested one. A panel
    /// removed under an active search left its bar over the chat, as a
    /// dismissed modal did (`Router.dismiss`), so the panel stays until the
    /// search has ended; ending a presented search completes later.
    private func removePanel() {
        guard !isRemoving else { return }
        guard installed != nil else {
            installRequestedPanel()
            return
        }
        isRemoving = true
        // Holds `self` until the panel is gone: a dismantled screen must
        // still take its leaf off the host.
        let finish = { [self] in
            self.container = nil
            self.installed = nil
            self.isMounted = false
            self.host = nil
            self.isRemoving = false
            let waiters = self.closedWaiters
            self.closedWaiters = []
            for waiter in waiters { waiter() }
            self.installRequestedPanel()
        }
        guard let container else {
            finish()
            return
        }
        Router.endSearch(in: container) { [self] in
            if self.isMounted, let host = self.host {
                host.closeCompanion(container, completion: finish)
            } else {
                self.host?.releaseParked(container)
                finish()
            }
        }
    }

    /// A parked leaf gives its screens back; the panel rebuilds them when
    /// the screen returns.
    @objc private func memoryWarning() {
        guard !isMounted, !isRemoving, let container else { return }
        host?.releaseParked(container)
        self.container = nil
    }

    // MARK: - Testing

    /// The panel's own screen, mounted at the root of the leaf's navigation
    /// controller, so a test can assert which destination it shows.
    var mountedScreenForTesting: UIViewController? { isMounted ? container?.viewControllers.first : nil }
    /// Every screen on the leaf's navigation controller, root first.
    var mountedStackForTesting: [UIViewController]? { isMounted ? container?.viewControllers : nil }
    /// The leaf's navigation controller while it exists, mounted or parked.
    var containerForTesting: UIViewController? { container }
    var hostForTesting: PaneHostController? { owningScreen.flatMap(PaneHostController.hosting) }
}
