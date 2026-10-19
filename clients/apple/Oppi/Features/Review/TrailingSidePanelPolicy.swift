import SwiftUI
import UIKit

/// When auxiliary side content opens as a trailing column instead of a sheet:
/// chat's side panels (Outline, Files, Context), a commit's diff, and a
/// review's file list. Regular width gets the column, with or without a
/// vertical toolbar rail: iPad and the Duo's inner portrait are regular
/// without one, and a rotation must not turn an open column into a sheet.
/// Compact, including the Duo's cover display, keeps the sheet or stack so a
/// column does not adapt into a second one.
enum TrailingSidePanelPolicy {
    static func usesTrailingColumn(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass == .regular
    }
}

extension View {
    /// A side panel in a full-height trailing column beside this screen,
    /// hosted by UIKit, like an iPadOS inspector. Replaces SwiftUI
    /// `.inspector`.
    ///
    /// `item` shows the column; nil hides it. The caller applies
    /// `TrailingSidePanelPolicy` and, at compact width, presents the same
    /// panel with `routerModal` instead. The panel is a `HostFactory` screen
    /// (or a UIKit controller, `RouterScreen.controller`) at the root of the
    /// column's own `RouterNavigationController`, for its title and bar items,
    /// level with this screen's bar; a hosted panel pushes and searches
    /// through its `ScreenNavigator`. A new `item.id` replaces the
    /// panel. The column sits on the navigation controller that holds this
    /// screen while the screen is on screen, and that controller's safe area
    /// makes room for it: this screen's bar items and content stay beside
    /// the column. Content that ignores the trailing safe area runs under it.
    ///
    /// The panel content runs in its own graph with the app root services.
    /// Presenter-local values (server scope, review scope, bindings into an
    /// `@Observable`) go on `content` explicitly. Close it through the
    /// caller's state: the column is neither pushed nor presented, so
    /// `ScreenNavigator.finish()` has nothing to close.
    func routerTrailingColumn<Item: Identifiable, Panel: View>(
        item: Item?,
        minWidth: CGFloat,
        idealWidth: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Panel
    ) -> some View {
        routerTrailingColumn(item: item, minWidth: minWidth, idealWidth: idealWidth, screen: { item in
            RouterScreen.hosted { AnyView(content(item)) }
        })
    }

    /// `routerTrailingColumn(item:minWidth:idealWidth:content:)` whose panel
    /// may be a UIKit view controller (`RouterScreen.controller`), built once
    /// per `item.id`.
    func routerTrailingColumn<Item: Identifiable>(
        item: Item?,
        minWidth: CGFloat,
        idealWidth: CGFloat,
        screen: @escaping (Item) -> RouterScreen
    ) -> some View {
        background {
            RouterTrailingColumnHost(
                panel: item.map { item in
                    TrailingColumnController.Panel(
                        id: AnyHashable(item.id),
                        minWidth: minWidth,
                        idealWidth: idealWidth,
                        screen: screen(item)
                    )
                }
            )
            .frame(width: 0, height: 0)
        }
    }
}

private struct RouterTrailingColumnHost: UIViewControllerRepresentable {
    let panel: TrailingColumnController.Panel?
    @Environment(\.appRootEnvironment) private var root

    func makeUIViewController(context: Context) -> TrailingColumnController {
        TrailingColumnController()
    }

    func updateUIViewController(_ column: TrailingColumnController, context: Context) {
        // The anchor is always there; only a shown panel needs the root.
        guard let panel else {
            column.show(nil, root: nil)
            return
        }
        guard let root else {
            preconditionFailure("routerTrailingColumn needs appRootEnvironment(_:) above its view")
        }
        column.show(panel, root: root)
    }

    static func dismantleUIViewController(_ column: TrailingColumnController, coordinator: ()) {
        column.show(nil, root: nil)
    }
}

/// UIKit owner of a trailing column: an invisible child of the screen that
/// asked for it. The panel is one screen (hosted or UIKit) at the root of the column's
/// own navigation controller, shown in a `TrailingColumnOverlayView` on top
/// of the navigation controller that holds the screen (the screen's top
/// ancestor outside one), whose child the column's controller becomes:
/// UIKit raises when a child's view sits outside its parent's. It attaches
/// while the screen is on screen, so a page pushed above the screen, or a
/// full-screen modal over it, never shows it, and the panel's own pushed
/// pages survive until the screen returns.
final class TrailingColumnController: UIViewController {
    struct Panel {
        let id: AnyHashable
        let minWidth: CGFloat
        let idealWidth: CGFloat
        let screen: RouterScreen
    }

    private var panelID: AnyHashable?
    private var root: AppRootEnvironment?
    /// Set when the panel is a hosted SwiftUI screen.
    private var hostedScreen: HostedScreenController?
    private var container: RouterNavigationController?
    private var overlay: TrailingColumnOverlayView?
    /// The controller whose safe area makes room for the column, and the
    /// trailing inset this column added to it.
    private weak var host: UIViewController?
    private var hostInset: CGFloat = 0
    /// The hosted screen beside the column while it is attached.
    private weak var screen: HostedScreenController?
    private var isOnScreen = false

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(inputBeganEditing(_:)),
                name: name,
                object: nil
            )
        }
    }

    func show(_ panel: Panel?, root: AppRootEnvironment?) {
        guard let panel, let root else {
            requested = nil
            removePanel()
            return
        }
        self.root = root
        requested = panel
        if panel.id == panelID, container != nil, !isRemoving {
            // The presenter re-rendered: refresh the content it builds.
            if case .hosted(let makeContent) = panel.screen {
                hostedScreen?.setContent(makeContent)
            }
            overlay?.widths = (panel.minWidth, panel.idealWidth)
            return
        }
        removePanel()
    }

    /// The panel the presenter asked for last; installed once any panel
    /// being removed is gone.
    private var requested: Panel?
    /// True while a removed panel waits for its search to end.
    private var isRemoving = false

    private func installRequestedPanel() {
        guard let panel = requested, let root, container == nil else { return }
        let screen: UIViewController
        switch panel.screen {
        case .hosted(let makeContent):
            let hosted = HostFactory.screen(root: root, content: makeContent)
            hostedScreen = hosted
            screen = hosted
        case .controller(let makeController, _):
            screen = makeController()
        }
        let container = RouterNavigationController(rootViewController: screen)
        let themeStore = root.themeStore
        container.interfaceStyle = { themeStore.userInterfaceStyle }
        // A narrow column lays out compact, as an inspector or a split
        // view's side column does. In a regular-width window an inset
        // grouped list (Context) misplaced and clipped its rows.
        container.traitOverrides.horizontalSizeClass = .compact
        container.onSafeAreaInsetsChange = { [weak self] in
            self?.overlay?.setNeedsLayout()
        }
        let overlay = TrailingColumnOverlayView(column: container.view)
        overlay.widths = (panel.minWidth, panel.idealWidth)
        overlay.onColumnWidth = { [weak self] width in
            self?.makeRoom(for: width)
        }

        panelID = panel.id
        self.container = container
        self.overlay = overlay
        setNeedsUpdateProperties()
        attach()
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        guard let themeStore = root?.themeStore else { return }
        container?.view.backgroundColor = themeStore.backgroundColor
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        attach()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isOnScreen = false
        detach()
    }

    /// The navigation controller that holds the hosted screen this column
    /// belongs to, so the column runs beside its bar; a screen outside one
    /// hosts the column itself. A harness with no hosted screen uses its top
    /// ancestor.
    private var hostController: UIViewController? {
        if let screen = owningScreen {
            return screen.navigationController ?? screen
        }
        var top: UIViewController = self
        while let parent = top.parent { top = parent }
        return top === self ? nil : top
    }

    /// The hosted screen that asked for this column.
    private var owningScreen: HostedScreenController? {
        var candidate = parent
        while let current = candidate {
            if let screen = current as? HostedScreenController { return screen }
            candidate = current.parent
        }
        return nil
    }

    private func attach() {
        guard isOnScreen, let overlay, let container, overlay.superview == nil,
              let host = hostController else { return }
        self.host = host
        screen = owningScreen
        host.addChild(container)
        overlay.frame = host.view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(overlay)
        container.didMove(toParent: host)
        // A navigation controller forwards appearance to its stack only.
        if !host.shouldAutomaticallyForwardAppearanceMethods {
            container.beginAppearanceTransition(true, animated: false)
            container.endAppearanceTransition()
        }
    }

    private func detach() {
        guard let host else { return }
        if let container, container.parent === host {
            if !host.shouldAutomaticallyForwardAppearanceMethods {
                container.beginAppearanceTransition(false, animated: false)
            }
            container.willMove(toParent: nil)
            overlay?.removeFromSuperview()
            container.removeFromParent()
            if !host.shouldAutomaticallyForwardAppearanceMethods {
                container.endAppearanceTransition()
            }
        }
        makeRoom(for: 0)
        screenFollowsKeyboard(true)
        screen = nil
        self.host = nil
    }

    /// The keyboard spans the window, so a field in the panel (the Outline's
    /// search) lifted the composer and pills of the chat beside it over its
    /// timeline. While the column is up, the screen follows the keyboard only
    /// for its own inputs; the panel avoids the keyboard itself. An input
    /// begins editing before the keyboard moves, so the screen is settled
    /// when it does.
    @objc private func inputBeganEditing(_ notification: Notification) {
        guard let screen, let input = notification.object as? UIView,
              let window = screen.viewIfLoaded?.window, input.window === window else { return }
        screenFollowsKeyboard(input.isDescendant(of: screen.view))
    }

    private func screenFollowsKeyboard(_ follows: Bool) {
        guard let screen else { return }
        let regions: SafeAreaRegions = follows ? .all : .container
        if screen.safeAreaRegions != regions {
            screen.safeAreaRegions = regions
        }
    }

    /// Insets the host's safe area so the screen's bar items and content stop
    /// at the column. The system already insets the host by the device's
    /// trailing inset (a landscape iPhone's sensor housing), which the column
    /// covers, so only the rest of the column's width is added; adding all of
    /// it left a housing-wide gap before the column. Recomputed on every
    /// layout, so a rotation, and a detach at width 0, settle on the right
    /// amount. The column sits on the host's view, so it takes the host
    /// view's own top and bottom insets (status bar, home indicator), not the
    /// bar insets a navigation controller hands its children, which put the
    /// column's bar a bar lower than the screen's; and the device's trailing
    /// inset, not the room made for it.
    private func makeRoom(for width: CGFloat) {
        guard let host else { return }
        let room = max(0, width - deviceTrailingInset(of: host.view))
        if room != hostInset {
            host.additionalSafeAreaInsets.right += room - hostInset
            hostInset = room
        }
        guard let container else { return }
        var insets = UIEdgeInsets.zero
        if width > 0, container.parent === host {
            let current = container.view.safeAreaInsets
            let added = container.additionalSafeAreaInsets
            insets.top = host.view.safeAreaInsets.top - (current.top - added.top)
            insets.bottom = host.view.safeAreaInsets.bottom - (current.bottom - added.bottom)
            insets.right = deviceTrailingInset(of: host.view) - (current.right - added.right)
        }
        if container.additionalSafeAreaInsets != insets {
            container.additionalSafeAreaInsets = insets
        }
    }

    /// The window's trailing safe-area inset where `view` reaches the
    /// window's trailing edge, else 0 (a centered sheet).
    private func deviceTrailingInset(of view: UIView) -> CGFloat {
        guard let window = view.window else { return 0 }
        let maxX = view.convert(view.bounds, to: window).maxX
        return maxX >= window.bounds.maxX - 0.5 ? window.safeAreaInsets.right : 0
    }

    /// Removes the current panel, then installs the requested one. A panel
    /// removed under an active search left its bar over the chat, as a
    /// dismissed modal did (`Router.dismiss`), so the panel stays until the
    /// search has ended; ending a presented search completes later.
    private func removePanel() {
        guard !isRemoving else { return }
        guard let container else {
            installRequestedPanel()
            return
        }
        isRemoving = true
        // Holds `self` until the panel is gone: a dismantled column must
        // still take its overlay off the host.
        Router.endSearch(in: container) { [self] in
            self.detach()
            self.container = nil
            self.hostedScreen = nil
            self.overlay = nil
            self.panelID = nil
            self.isRemoving = false
            self.installRequestedPanel()
        }
    }
}

/// Covers the host's view and shows the column at its trailing edge, above
/// the host's navigation bar, with a hairline divider. Touches outside the
/// column reach the views below. Sizes the column on every layout: up to the
/// ideal width; narrower windows split the space, down to the minimum.
final class TrailingColumnOverlayView: UIView {
    var widths: (minimum: CGFloat, ideal: CGFloat) = (0, 0) {
        didSet { setNeedsLayout() }
    }
    var onColumnWidth: ((CGFloat) -> Void)?

    private let column: UIView
    private let divider = UIView()

    init(column: UIView) {
        self.column = column
        super.init(frame: .zero)
        backgroundColor = .clear
        divider.backgroundColor = .separator
        addSubview(divider)
        addSubview(column)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    private var columnWidth: CGFloat {
        min(widths.ideal, max(widths.minimum, bounds.width / 2))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The host may add views (a toolbar) above this one.
        superview?.bringSubviewToFront(self)
        let width = columnWidth
        let hairline = 1 / max(traitCollection.displayScale, 1)
        column.frame = CGRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height)
        divider.frame = CGRect(x: column.frame.minX - hairline, y: 0, width: hairline, height: bounds.height)
        onColumnWidth?(width)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        // The host's insets moved (its bar or the status bar): re-measure.
        setNeedsLayout()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard column.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
