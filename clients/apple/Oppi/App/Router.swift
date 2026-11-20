import UIKit

// UIKit owns modal presentation and navigation pushes for iOS. This file is
// the UIKit half of the router: presentation styles, the modal navigation
// container, and the host-owned search bar.
//
// Policy: dev/architecture-client.md, "UIKit and SwiftUI ownership".

/// How the router shows a modal screen.
@MainActor
struct ModalPresentation {
    var style: UIModalPresentationStyle
    /// Sheet detents. Empty keeps UIKit's default (large).
    var detents: [UISheetPresentationController.Detent] = []
    var prefersGrabberVisible = false
    /// The detent the sheet opens at. Nil opens at the smallest detent.
    /// A UIKit screen moves it later with `Router.selectSheetDetent`.
    var selectedDetent: UISheetPresentationController.Detent.Identifier?
    /// Sheet corner radius. Nil keeps UIKit's.
    var sheetCornerRadius: CGFloat?
    /// Whether the screen is wrapped in a `RouterNavigationController`. It then
    /// gets a UIKit navigation bar for its title and bar items, and pushes with
    /// `Router.push`.
    var wrapsInNavigation = false
    var permittedArrowDirections: UIPopoverArrowDirection = .any
    /// A popover becomes a page sheet in compact width, as SwiftUI does
    /// (`PopoverAdaptsToSheet`; UIKit alone would cover the screen).
    /// `keepsPopoverInCompactWidth()` matches `.presentationCompactAdaptation(.popover)`.
    var adaptsPopoverToSheetInCompactWidth = true

    /// SwiftUI `.sheet`: a form sheet (a page sheet in compact width).
    static var sheet: Self { Self(style: .formSheet) }
    static var pageSheet: Self { Self(style: .pageSheet) }
    /// SwiftUI `.fullScreenCover`.
    static var fullScreen: Self { Self(style: .fullScreen) }
    /// SwiftUI `.popover`, anchored to the view that declares it, or to the
    /// `sourceView` a UIKit caller passes.
    static var popover: Self { Self(style: .popover) }
    /// A popover at its control when wide, which UIKit adapts to a sheet with
    /// these detents when compact, live on a fold or a resize. For a choice or
    /// options panel opened from a control (HIG, Popovers). Pass the control as
    /// the presenter's `source`; a call site never reads the size class.
    static func popoverOrSheet(
        detents: [UISheetPresentationController.Detent] = [.medium(), .large()],
        selected: UISheetPresentationController.Detent.Identifier? = nil,
        grabber: Bool = false,
        cornerRadius: CGFloat? = nil
    ) -> Self {
        Self(
            style: .popover,
            detents: detents,
            prefersGrabberVisible: grabber,
            selectedDetent: selected,
            sheetCornerRadius: cornerRadius
        )
    }

    /// Document and file viewers: covers the window when it is wide, a large
    /// page sheet with a grabber when compact. The window of `view` decides,
    /// not the pane it sits in, which may lay out compact beside another.
    static func largeViewer(over view: UIView) -> Self {
        if AdaptiveWidth.windowIsWide(view) {
            return Self(style: .overFullScreen)
        }
        return Self(style: .pageSheet, detents: [.large()], prefersGrabberVisible: true)
    }

    func detents(
        _ detents: [UISheetPresentationController.Detent],
        grabber: Bool = false,
        selected: UISheetPresentationController.Detent.Identifier? = nil,
        cornerRadius: CGFloat? = nil
    ) -> Self {
        var copy = self
        copy.detents = detents
        copy.prefersGrabberVisible = grabber
        copy.selectedDetent = selected
        copy.sheetCornerRadius = cornerRadius
        return copy
    }

    func inNavigation() -> Self {
        var copy = self
        copy.wrapsInNavigation = true
        return copy
    }

    func arrowDirections(_ directions: UIPopoverArrowDirection) -> Self {
        var copy = self
        copy.permittedArrowDirections = directions
        return copy
    }

    func keepsPopoverInCompactWidth() -> Self {
        var copy = self
        copy.adaptsPopoverToSheetInCompactWidth = false
        return copy
    }

    /// Sets `container` up for this presentation before it is presented: the
    /// style, a popover's `source` (the view it points at, or the sheet it adapts
    /// to), and the sheet's detents. `Router.present` and a presenter of its own
    /// (the reader's menus) share it.
    func apply(to container: UIViewController, source: UIView?) {
        container.modalPresentationStyle = style
        switch style {
        case .popover:
            guard let popover = container.popoverPresentationController else { return }
            if let source {
                popover.sourceView = source
                popover.sourceRect = source.bounds
            }
            popover.permittedArrowDirections = permittedArrowDirections
            if adaptsPopoverToSheetInCompactWidth {
                popover.delegate = PopoverAdaptsToSheet.shared
                if !detents.isEmpty {
                    configure(popover.adaptiveSheetPresentationController)
                }
            } else {
                popover.delegate = PopoverInCompactWidth.shared
            }
        case .formSheet, .pageSheet:
            if let sheet = container.sheetPresentationController {
                configure(sheet)
            }
        default:
            break
        }
    }

    private func configure(_ sheet: UISheetPresentationController) {
        if !detents.isEmpty {
            sheet.detents = detents
        }
        sheet.prefersGrabberVisible = prefersGrabberVisible
        sheet.selectedDetentIdentifier = selectedDetent
        if let sheetCornerRadius {
            sheet.preferredCornerRadius = sheetCornerRadius
        }
    }
}

/// A controller the router presents. It reports once UIKit has finished
/// dismissing it, whatever caused the dismissal: swipe-down, `Router.finish`,
/// a cleared binding, or the presenter going away.
@MainActor
protocol RouterModalContainer: UIViewController {
    var onDismissed: (() -> Void)? { get set }
}

/// The navigation controller the router presents modally around a screen.
/// It follows the app theme's color scheme, so the bar and the sheet chrome
/// match the hosted content in light, dark, and system themes.
final class RouterNavigationController: UINavigationController, RouterModalContainer,
    UINavigationControllerDelegate {
    var onDismissed: (() -> Void)?
    /// How the root screen closes when this stack is not presented: a split
    /// pane's stack closes its pane. Nil for a stack that never shows a root
    /// on its own (a modal, which `Router.finish` dismisses instead).
    var onCloseRoot: (() -> Void)?
    var interfaceStyle: (() -> UIUserInterfaceStyle)? {
        didSet { setNeedsUpdateProperties() }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        // The panel lost its title, Done, and search after a reader popped.
        applyNavigationBar(forIncoming: viewController, animated: animated)
        PaneHostController.containing(self)?.leafWillShowScreen()
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        // A page pushed inside a pane's companion hears the leaf's visibility.
        PaneHostController.containing(self)?.leafDidShowScreen()
    }

    func closeRoot() {
        guard let onCloseRoot else {
            assertionFailure("Router.finish on the root of a stack that cannot close it")
            return
        }
        onCloseRoot()
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        if let interfaceStyle {
            overrideUserInterfaceStyle = interfaceStyle()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Swipe-down ends here, not in `Router.dismiss`. End an active search
        // the same way, or the dismissed sheet leaves its bar taking taps.
        if isBeingDismissed {
            Router.endSearch(in: self)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Once per presentation: UIKit can report the disappearance again.
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }
}

/// A screen that brings its own Back and actions, so the stack's navigation
/// bar stays hidden while the screen is on top and `hidesNavigationBar` is
/// true (the SSH terminal, a chat reader showing a page, a file reader showing
/// a file). Every other screen shows the bar.
///
/// The bar's hidden state follows the screen in front and nothing else sets
/// it: no other code calls `setNavigationBarHidden`, which the UIKit structure
/// guard enforces. A stack's delegate calls `applyNavigationBar(forIncoming:)`
/// as each screen comes forward. A screen whose answer changes while it is on
/// top (a file finishing its load, a lock cover replacing a page) calls
/// `updateNavigationBar(for:animated:)`. A screen that only wraps one of these
/// (a screen that embeds a file viewer) need not conform: the policy asks its
/// child controllers.
@MainActor
protocol NavigationBarHiding: UIViewController {
    var hidesNavigationBar: Bool { get }
}

@MainActor
private func screenHidesNavigationBar(_ screen: UIViewController) -> Bool {
    if let hiding = screen as? NavigationBarHiding { return hiding.hidesNavigationBar }
    return screen.children.contains(where: screenHidesNavigationBar)
}

extension UINavigationController {
    /// Call from `navigationController(_:willShow:animated:)`: the incoming
    /// screen's bar state replaces the outgoing one's, so the screen below a
    /// reader gets its Back button, title, items, and search bar back when the
    /// reader pops. A cancelled back swipe leaves the old screen on top, so its
    /// bar state comes back.
    func applyNavigationBar(forIncoming incoming: UIViewController, animated: Bool) {
        let wasHidden = isNavigationBarHidden
        let hidden = screenHidesNavigationBar(incoming)
        guard wasHidden != hidden else { return }
        setNavigationBarHidden(hidden, animated: animated)
        transitionCoordinator?.notifyWhenInteractionChanges { [weak self] context in
            guard context.isCancelled else { return }
            self?.setNavigationBarHidden(wasHidden, animated: true)
        }
    }

    /// A screen's `hidesNavigationBar` changed (or a child that decides it came
    /// or went). `screen` is the stack's screen or any controller inside it;
    /// nothing happens unless that screen is on top, since the screen in front
    /// owns the bar.
    func updateNavigationBar(for screen: UIViewController, animated: Bool) {
        var stackScreen = screen
        while stackScreen.parent !== self {
            guard let parent = stackScreen.parent else { return }
            stackScreen = parent
        }
        guard topViewController === stackScreen else { return }
        let hidden = screenHidesNavigationBar(stackScreen)
        guard isNavigationBarHidden != hidden else { return }
        setNavigationBarHidden(hidden, animated: animated)
    }
}

@MainActor
enum Router {
    /// Presents `screen` above everything in the presenter's window.
    ///
    /// `screen` must be a `RouterModalContainer` unless the presentation wraps
    /// it in navigation. `onDismiss` runs after UIKit finished dismissing it,
    /// however that happened. The navigation container follows the color
    /// scheme of `theme`, else of the app root above `presenter`.
    static func present(
        _ screen: UIViewController,
        presentation: ModalPresentation,
        from presenter: UIViewController,
        sourceView: UIView? = nil,
        theme: ThemeStore? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        let container: RouterModalContainer
        if presentation.wrapsInNavigation {
            let navigation = RouterNavigationController(rootViewController: screen)
            if let theme = theme ?? AppRootEnvironment.near(presenter)?.themeStore {
                navigation.interfaceStyle = { theme.userInterfaceStyle }
            } else {
                assertionFailure(
                    "Router.present with navigation needs a theme or an app root above \(type(of: presenter))"
                )
            }
            container = navigation
        } else if let screen = screen as? RouterModalContainer {
            container = screen
        } else {
            preconditionFailure("Router.present needs a RouterModalContainer or a navigation presentation")
        }

        presentation.apply(to: container, source: sourceView ?? presenter.view)
        container.onDismissed = onDismiss
        if presentation.style == .overFullScreen || presentation.style == .fullScreen {
            // A window-covering modal: drop the presenter's keyboard. Over
            // `.overFullScreen` it would float over the modal. `.fullScreen`
            // takes the presenter out of the window, and a field kept first
            // responder there came back under a stale keyboard inset with
            // nothing left to dismiss it.
            presenter.view.window?.endEditing(true)
        }
        // A pane of a window with several: one sheet at a time across them.
        if let host = PaneHostController.containing(presenter), host.panes.cellLayout.leaves.count > 1,
           let owner = host.cell(holding: presenter) {
            let arbiter = host.panes.sheets
            container.onDismissed = {
                onDismiss?()
                arbiter.sheetDidDismiss()
            }
            arbiter.request(owner: owner, container: container, onCancel: onDismiss) { [weak presenter] in
                guard let presenter, presenter.view.window != nil else { return false }
                topPresenter(from: presenter).present(container, animated: true)
                return true
            }
            return
        }
        topPresenter(from: presenter).present(container, animated: true)
    }

    /// Moves the sheet `screen` is the root of to `detent`, animated.
    static func selectSheetDetent(
        _ detent: UISheetPresentationController.Detent.Identifier,
        of screen: UIViewController
    ) {
        let container = screen.navigationController ?? screen
        guard let sheet = container.sheetPresentationController,
              sheet.selectedDetentIdentifier != detent else { return }
        sheet.animateChanges {
            sheet.selectedDetentIdentifier = detent
        }
    }

    /// Pushes `screen` onto the navigation controller that holds `host`. A
    /// push asked for while a pop is still animating (the SSH host list opens
    /// the host's form as the terminal above it closes) waits for it to end.
    ///
    /// A screen without the app root as a trait gets `host`'s, so it finds the
    /// root before it is in a window that publishes one (the SSH host list and
    /// the Tailnet page read it while they build).
    static func push(_ screen: UIViewController, from host: UIViewController) {
        if screen.traitOverrides.appRootEnvironment == nil,
           let root = AppRootEnvironment.near(host) {
            screen.traitOverrides.appRootEnvironment = root
        }
        guard let navigation = host.navigationController else {
            assertionFailure("Router.push from \(type(of: host)), which is not in a navigation controller")
            return
        }
        guard let transition = navigation.transitionCoordinator else {
            navigation.pushViewController(screen, animated: true)
            return
        }
        transition.animate(alongsideTransition: nil) { _ in
            navigation.pushViewController(screen, animated: true)
        }
    }

    /// Closes `screen` deterministically, where SwiftUI `dismiss()` is not:
    /// pops it (and anything above it) when it was pushed, otherwise dismisses
    /// the modal it is the root of, including a presented navigation
    /// controller's root, where `dismiss()` does nothing. The root of a side
    /// pane's stack closes its pane (`RouterNavigationController.closeRoot`).
    /// A shell stack's root is a place, which has nothing to close to.
    static func finish(_ screen: UIViewController) {
        if pop(screen) { return }
        let container = screen.navigationController ?? screen
        if container.presentingViewController != nil {
            dismiss(container)
            return
        }
        guard let stack = screen.navigationController as? RouterNavigationController else {
            assertionFailure("Router.finish on \(type(of: screen)), which is neither pushed nor presented")
            return
        }
        stack.closeRoot()
    }

    /// Dismisses the presented `container` and everything above it, ending
    /// an active search first (see `endSearch(in:then:)`).
    static func dismiss(_ container: UIViewController) {
        // A pane's sheet still waiting its turn leaves the line instead.
        if PaneSheetArbiter.cancel(container) { return }
        guard let presenting = container.presentingViewController else { return }
        endSearch(in: container) {
            presenting.dismiss(animated: true)
        }
    }

    /// Ends an active `UISearchController` on `container`'s screens without
    /// animation, then runs `completion`. A modal dismissed under an active
    /// search left its navigation bar on screen, still taking taps (iOS 27
    /// simulator), whether the dismissal was programmatic or a swipe.
    static func endSearch(in container: UIViewController, then completion: (() -> Void)? = nil) {
        let screens = (container as? UINavigationController)?.viewControllers ?? [container]
        let activeSearch = screens
            .compactMap(\.navigationItem.searchController)
            .first { $0.isActive }
        guard let activeSearch else {
            completion?()
            return
        }
        endSearch(activeSearch, then: completion)
    }

    /// Ends `search` without animation, then runs `completion`.
    static func endSearch(_ search: UISearchController, then completion: (() -> Void)? = nil) {
        guard search.isActive else {
            completion?()
            return
        }
        guard search.presentingViewController != nil else {
            search.isActive = false
            completion?()
            return
        }
        search.dismiss(animated: false) {
            search.isActive = false
            completion?()
        }
    }

    /// Pops `screen` and anything pushed above it. Returns false when `screen`
    /// is the root of its stack or not in one.
    @discardableResult
    static func pop(_ screen: UIViewController) -> Bool {
        guard let navigation = screen.navigationController,
              let index = navigation.viewControllers.firstIndex(of: screen),
              index > 0 else { return false }
        navigation.popToViewController(navigation.viewControllers[index - 1], animated: true)
        return true
    }

    /// The screen an action with no screen of its own lands on in `window` (a
    /// link, a notification, a keyboard command): the top of a sheet's stack
    /// over the window, else the front screen of the focused pane leaf. A
    /// presented controller with no stack of its own (an alert, a plain sheet)
    /// leaves the stack underneath. Another window is never asked.
    static func focusedScreen(in window: UIWindow) -> UIViewController? {
        window.rootViewController.flatMap(front(of:))
    }

    /// The front screen of each leaf of the pane host that holds `window`'s
    /// focus, the focused leaf's first. The window's host wraps the shell and
    /// the chat's own host sits inside it, so this follows the focused leaves
    /// down to the innermost. Empty when the window has no panes.
    static func paneScreens(in window: UIWindow) -> [UIViewController] {
        guard let root = window.rootViewController,
              var host = root as? PaneHostController ?? paneHost(under: root) else { return [] }
        while let inner = host.focusedLeafController as? PaneHostController ?? paneHost(under: host.focusedLeafController) {
            host = inner
        }
        return host.leafScreens
    }

    /// The controller that presents for `view`: its own screen, or what its
    /// window already presents above that. Nil outside a window.
    static func presenter(near view: UIView) -> UIViewController? {
        guard view.window != nil, let screen = view.nearestViewController else { return nil }
        return topPresenter(from: screen)
    }

    private static func front(of controller: UIViewController) -> UIViewController? {
        if let presented = controller.presentedViewController, !presented.isBeingDismissed,
           !(presented is UISearchController), let found = front(of: presented) {
            return found
        }
        if let navigation = controller as? UINavigationController {
            guard let top = navigation.topViewController else { return nil }
            // The stack's top is the screen, unless it presents over itself
            // or holds the window's panes; a screen's own children (a file
            // browser's tree and file) are parts of it.
            if top.presentedViewController != nil || top is UISplitViewController || paneHost(under: top) != nil {
                return front(of: top) ?? top
            }
            return top
        }
        if let host = controller as? PaneHostController {
            return front(of: host.focusedLeafController)
        }
        if let split = controller as? UISplitViewController {
            let column = split.isCollapsed ? split.viewControllers.last : split.viewController(for: .secondary)
            return column.flatMap(front(of:))
        }
        // The window's panes hold the focus: a container's other children
        // (a drawer's sidebar, the Live Voice strip) never take it.
        if let host = paneHost(under: controller) {
            return front(of: host)
        }
        // Later children are in front of earlier ones in the shell's
        // containers; a hidden one (a parked companion) is not.
        for child in controller.children.reversed() where child.viewIfLoaded?.isHidden != true {
            if let found = front(of: child) { return found }
        }
        return controller.navigationController == nil ? nil : controller
    }

    private static func paneHost(under controller: UIViewController) -> PaneHostController? {
        for child in controller.children {
            if let host = child as? PaneHostController ?? paneHost(under: child) { return host }
        }
        return nil
    }

    /// The front-most controller in the window of `controller`, the one UIKit
    /// lets present.
    static func topPresenter(from controller: UIViewController) -> UIViewController {
        var top = controller.viewIfLoaded?.window?.rootViewController ?? controller
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// A popover in compact width becomes a page sheet: UIKit's own adaptation is
/// a full-screen cover, so the sheet has to be asked for. Wide keeps the popover.
@MainActor
private final class PopoverAdaptsToSheet: NSObject, UIPopoverPresentationControllerDelegate {
    static let shared = PopoverAdaptsToSheet()

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        AdaptiveWidth.isWide(traitCollection) ? .none : .pageSheet
    }
}

/// Keeps a popover a popover in compact width.
@MainActor
private final class PopoverInCompactWidth: NSObject, UIPopoverPresentationControllerDelegate {
    static let shared = PopoverInCompactWidth()

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }
}

/// Host-owned search bar for a screen.
///
/// UIKit's `UISearchController` installs on the screen's navigation item, and
/// this keeps the screen's search text and the bar in sync both ways.
@MainActor
final class ScreenSearchController: NSObject, UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate {
    let searchController = UISearchController(searchResultsController: nil)
    var onTextChange: (String) -> Void = { _ in }
    /// The person picked another scope button (`setScopes`).
    var onScopeChange: (Int) -> Void = { _ in }
    /// The scope bar's accessibility identifier. UIKit builds the bar's
    /// segmented control itself, when it first shows, so it is tagged then.
    var scopeAccessibilityIdentifier: String?
    private var hidesWhenScrolling = true
    private var keepsBarInWideWindow = false
    /// The search became active or ended, by the user or by `setPresented`.
    var onPresentationChange: (Bool) -> Void = { _ in }

    init(prompt: String) {
        super.init()
        searchController.searchResultsUpdater = self
        searchController.delegate = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = prompt
        searchController.searchBar.delegate = self
    }

    var text: String {
        searchController.searchBar.text ?? ""
    }

    func install(on host: UIViewController, alwaysVisible: Bool) {
        host.navigationItem.searchController = searchController
        host.navigationItem.preferredSearchBarPlacement = .stacked
        // A bar that hides when scrolling starts hidden in UIKit; SwiftUI's
        // drawer started shown. Shown until the screen appears.
        hidesWhenScrolling = !alwaysVisible
        host.navigationItem.hidesSearchBarWhenScrolling = false
        host.definesPresentationContext = true
    }

    /// The screen appeared with the bar shown; from now on it hides as the
    /// content scrolls, if asked to.
    func hostDidAppear(_ host: UIViewController) {
        guard host.navigationItem.searchController === searchController else { return }
        host.navigationItem.hidesSearchBarWhenScrolling = hidesWhenScrolling
        applyNavigationBarPolicy()
    }

    /// A panel keeps its title and Close while searching in a wide window,
    /// because the bar has room and no Cancel to end the search. The window's
    /// width decides, not the screen's: a panel in an attached leaf reads
    /// compact but sits in a wide window (`AdaptiveWidth.windowIsWide`).
    /// A narrow window hides the bar, as UIKit does by default.
    func keepsNavigationBarInWideWindow() {
        keepsBarInWideWindow = true
        applyNavigationBarPolicy()
    }

    private func applyNavigationBarPolicy() {
        guard keepsBarInWideWindow else { return }
        searchController.hidesNavigationBarDuringPresentation = !AdaptiveWidth.windowIsWide(searchController.searchBar)
    }

    /// The search `screen` owns while it is on screen: Find's surface. Its bar
    /// may be scrolled out of sight (`begin` brings it back).
    static func search(on screen: UIViewController) -> UISearchController? {
        guard screen.viewIfLoaded?.window != nil else { return nil }
        return screen.navigationItem.searchController
    }

    /// Starts the search and puts the cursor in the field, as tapping the bar
    /// does. A bar that hides while the content scrolls is shown first.
    static func begin(_ search: UISearchController, on screen: UIViewController) {
        if screen.navigationItem.hidesSearchBarWhenScrolling {
            screen.navigationItem.hidesSearchBarWhenScrolling = false
        }
        search.isActive = true
        search.searchBar.becomeFirstResponder()
    }

    /// Takes the bar off `host` again (the screen stopped asking for search).
    func uninstall(from host: UIViewController) {
        guard host.navigationItem.searchController === searchController else { return }
        searchController.isActive = false
        host.navigationItem.searchController = nil
    }

    /// Screen state to bar. Does not echo back through `onTextChange`.
    func setText(_ text: String) {
        guard self.text != text else { return }
        searchController.searchBar.text = text
    }

    /// Screen state to bar: starts or ends the search. Activating needs the
    /// bar on screen; a screen that is covered applies it when it returns.
    func setPresented(_ presented: Bool) {
        guard searchController.isActive != presented else { return }
        if presented, searchController.searchBar.window == nil { return }
        searchController.isActive = presented
    }

    /// Screen state to bar: the scope buttons shown while searching (nil for
    /// none) and the chosen one. Does not echo back through `onScopeChange`.
    func setScopes(_ titles: [String]?, selected: Int) {
        let bar = searchController.searchBar
        if bar.scopeButtonTitles != titles {
            bar.scopeButtonTitles = titles
            searchController.automaticallyShowsScopeBar = titles != nil
            if titles == nil, bar.showsScopeBar { bar.showsScopeBar = false }
        }
        if let titles, titles.indices.contains(selected), bar.selectedScopeButtonIndex != selected {
            bar.selectedScopeButtonIndex = selected
        }
        tagScopeBar()
    }

    /// A test aid: UIKit gives no handle on the scope bar, so this tags the
    /// first segmented control inside the search bar. It relies on
    /// UISearchBar's private layout and silently does nothing if that changes.
    private func tagScopeBar() {
        guard let scopeAccessibilityIdentifier else { return }
        func firstSegmentedControl(in view: UIView) -> UISegmentedControl? {
            for subview in view.subviews {
                if let control = subview as? UISegmentedControl { return control }
                if let control = firstSegmentedControl(in: subview) { return control }
            }
            return nil
        }
        let control = firstSegmentedControl(in: searchController.searchBar)
        if control?.accessibilityIdentifier != scopeAccessibilityIdentifier {
            control?.accessibilityIdentifier = scopeAccessibilityIdentifier
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        tagScopeBar()
        onTextChange(text)
    }

    func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
        onScopeChange(selectedScope)
    }

    func willPresentSearchController(_ searchController: UISearchController) {
        applyNavigationBarPolicy()
    }

    func didPresentSearchController(_ searchController: UISearchController) {
        tagScopeBar()
        onPresentationChange(true)
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        onPresentationChange(false)
    }
}
