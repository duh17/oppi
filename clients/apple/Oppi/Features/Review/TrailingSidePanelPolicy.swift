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
    /// at the root of the column's own `RouterNavigationController`, for its
    /// title and bar items, level with this screen's bar; it pushes and
    /// searches through its `ScreenNavigator`. A new `item.id` replaces the
    /// panel. The column sits on the navigation controller that holds this
    /// screen while the screen is on screen, and that controller's safe area
    /// makes room for it: this screen's bar items and content stay beside
    /// the column. Content that ignores the trailing safe area runs under it.
    ///
    /// The panel must not bring its own SwiftUI `NavigationStack`: the column
    /// is a child controller, and a stack hosted there reset an enclosing
    /// SwiftUI `NavigationStack` to its root.
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
        background {
            RouterTrailingColumnHost(
                panel: item.map { item in
                    TrailingColumnController.Panel(
                        id: AnyHashable(item.id),
                        minWidth: minWidth,
                        idealWidth: idealWidth
                    ) {
                        AnyView(content(item))
                    }
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
/// asked for it. The panel is one hosted screen at the root of the column's
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
        let makeContent: () -> AnyView
    }

    private var panelID: AnyHashable?
    private var root: AppRootEnvironment?
    private var screen: HostedScreenController?
    private var container: RouterNavigationController?
    private var overlay: TrailingColumnOverlayView?
    /// The controller whose safe area makes room for the column, and the
    /// trailing inset this column added to it.
    private weak var host: UIViewController?
    private var hostInset: CGFloat = 0
    private var isOnScreen = false

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    func show(_ panel: Panel?, root: AppRootEnvironment?) {
        guard let panel, let root else {
            removePanel()
            return
        }
        self.root = root
        if panel.id == panelID, let screen {
            // The presenter re-rendered: refresh the content it builds.
            screen.setContent(panel.makeContent)
            overlay?.widths = (panel.minWidth, panel.idealWidth)
            return
        }
        removePanel()

        let screen = HostFactory.screen(root: root, content: panel.makeContent)
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
        self.screen = screen
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
    /// hosts the column itself. Not a SwiftUI `NavigationStack`'s own
    /// controller inside the screen: a column there reset the stack. A
    /// harness with no hosted screen uses its top ancestor.
    private var hostController: UIViewController? {
        var candidate = parent
        while let current = candidate {
            if let screen = current as? HostedScreenController {
                return screen.navigationController ?? screen
            }
            candidate = current.parent
        }
        var top: UIViewController = self
        while let parent = top.parent { top = parent }
        return top === self ? nil : top
    }

    private func attach() {
        guard isOnScreen, let overlay, let container, overlay.superview == nil,
              let host = hostController else { return }
        self.host = host
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
        self.host = nil
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

    private func removePanel() {
        detach()
        container = nil
        screen = nil
        overlay = nil
        panelID = nil
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
