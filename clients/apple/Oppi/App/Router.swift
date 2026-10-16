import UIKit

// UIKit owns modal presentation and navigation pushes for iOS. This file is
// the UIKit half of the router: presentation styles, bar policy, the modal
// navigation container, and the host-owned search bar. SwiftUI screens become
// controllers through `HostFactory` (`HostFactory.swift`), which also holds the
// SwiftUI-facing API (`routerModal`, `routerSearchable`, and the
// `screenNavigator` environment value with `present`, `push`, and `finish`).
//
// Policy: dev/architecture-client.md, "UIKit and SwiftUI ownership".

/// What a hosted screen wants from the UIKit bars of the navigation controller
/// it sits in. Applied every time the screen appears, so popping back restores
/// the previous screen's policy.
struct ScreenBars: Equatable {
    /// Large title. Inline otherwise. SwiftUI's `navigationBarTitleDisplayMode`
    /// is ignored in a UIKit navigation bar until the bar prefers large titles.
    /// On a vertical toolbar rail (iPhone Duo) the title stays inline: a large
    /// title there showed no title at all.
    var largeTitle = false
    /// Shows the navigation controller's toolbar while the screen has SwiftUI
    /// `.bottomBar` items. A hidden toolbar drops them silently; an empty one
    /// still takes the bottom inset.
    var showsToolbar = false
}

/// How the router shows a modal screen.
@MainActor
struct ModalPresentation {
    var style: UIModalPresentationStyle
    /// Sheet detents. Empty keeps UIKit's default (large).
    var detents: [UISheetPresentationController.Detent] = []
    var prefersGrabberVisible = false
    /// The detent the sheet opens at. Nil opens at the smallest detent.
    /// The screen moves it later with `ScreenNavigator.selectSheetDetent`.
    var selectedDetent: UISheetPresentationController.Detent.Identifier?
    /// Sheet corner radius (SwiftUI `presentationCornerRadius`). Nil keeps UIKit's.
    var sheetCornerRadius: CGFloat?
    /// Non-nil wraps the screen in a `RouterNavigationController` with these
    /// bars for the root screen. The screen then gets a UIKit navigation bar
    /// for its title and toolbar items, pushes with `ScreenNavigator.push`,
    /// and needs no SwiftUI `NavigationStack` of its own.
    var navigation: ScreenBars?
    var permittedArrowDirections: UIPopoverArrowDirection = .any
    /// UIKit turns a popover into a sheet in compact width, as SwiftUI does.
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

    /// Document and file viewers: covers the window in regular width, a large
    /// page sheet with a grabber in compact width.
    static func largeViewer(for traitCollection: UITraitCollection) -> Self {
        if FullScreenViewerPresentationPolicy.prefersFullScreenOverlay(for: traitCollection) {
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

    func inNavigation(_ bars: ScreenBars = ScreenBars()) -> Self {
        var copy = self
        copy.navigation = bars
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
}

/// A navigation controller whose root screen can close without being popped
/// or dismissed: the split shell's detail column shows its list instead.
@MainActor
protocol RouterRootClosing: UINavigationController {
    func closeRoot()
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
    var interfaceStyle: (() -> UIUserInterfaceStyle)? {
        didSet { setNeedsUpdateProperties() }
    }
    /// Runs after UIKit recomputes this controller's safe area. A trailing
    /// column uses it to keep its own insets in step with its host.
    var onSafeAreaInsetsChange: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        onSafeAreaInsetsChange?()
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        // A pushed file reader hides this bar for its own chrome
        // (`toolbarVisibility(.hidden, for: .navigationBar)`), and nothing
        // shows it again when the reader pops: the screen below lost its
        // title, items, and search bar. Every screen starts with the bar;
        // content that hides it hides it again.
        setNavigationBarHidden(false, animated: animated)
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

@MainActor
enum Router {
    /// Presents `screen` above everything in the presenter's window.
    ///
    /// `screen` must be a `RouterModalContainer` unless the presentation wraps
    /// it in navigation. `onDismiss` runs after UIKit finished dismissing it,
    /// however that happened. `theme` drives the navigation container's color
    /// scheme; hosted screens follow the theme themselves.
    static func present(
        _ screen: UIViewController,
        presentation: ModalPresentation,
        from presenter: UIViewController,
        sourceView: UIView? = nil,
        theme: ThemeStore?,
        onDismiss: (() -> Void)?
    ) {
        let container: RouterModalContainer
        if presentation.navigation != nil {
            let navigation = RouterNavigationController(rootViewController: screen)
            if let theme {
                navigation.interfaceStyle = { theme.userInterfaceStyle }
            }
            container = navigation
        } else if let screen = screen as? RouterModalContainer {
            container = screen
        } else {
            preconditionFailure("Router.present needs a RouterModalContainer or a navigation presentation")
        }

        container.modalPresentationStyle = presentation.style
        switch presentation.style {
        case .popover:
            if let popover = container.popoverPresentationController {
                let anchor = sourceView ?? presenter.view
                popover.sourceView = anchor
                popover.sourceRect = anchor?.bounds ?? .zero
                popover.permittedArrowDirections = presentation.permittedArrowDirections
                if !presentation.adaptsPopoverToSheetInCompactWidth {
                    popover.delegate = PopoverInCompactWidth.shared
                }
            }
        case .formSheet, .pageSheet:
            if let sheet = container.sheetPresentationController {
                if !presentation.detents.isEmpty {
                    sheet.detents = presentation.detents
                }
                sheet.prefersGrabberVisible = presentation.prefersGrabberVisible
                sheet.selectedDetentIdentifier = presentation.selectedDetent
                if let cornerRadius = presentation.sheetCornerRadius {
                    sheet.preferredCornerRadius = cornerRadius
                }
            }
        default:
            break
        }
        container.onDismissed = onDismiss
        if presentation.style == .overFullScreen {
            // A window-covering modal that keeps the presenter in the window:
            // drop the presenter's keyboard, as `.fullScreen` does by taking
            // the presenter out of the window. It would float over the modal.
            presenter.view.window?.endEditing(true)
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
    static func push(_ screen: UIViewController, from host: UIViewController) {
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
    /// controller's root, where `dismiss()` does nothing. The root of a shell
    /// stack closes the way its stack defines (`RouterRootClosing`).
    static func finish(_ screen: UIViewController) {
        if pop(screen) { return }
        let container = screen.navigationController ?? screen
        if container.presentingViewController != nil {
            dismiss(container)
            return
        }
        guard let stack = screen.navigationController as? RouterRootClosing else {
            assertionFailure("Router.finish on \(type(of: screen)), which is neither pushed nor presented")
            return
        }
        stack.closeRoot()
    }

    /// Dismisses the presented `container` and everything above it, ending
    /// an active search first (see `endSearch(in:then:)`).
    static func dismiss(_ container: UIViewController) {
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
        guard let activeSearch, activeSearch.presentingViewController != nil else {
            activeSearch?.isActive = false
            completion?()
            return
        }
        activeSearch.dismiss(animated: false, completion: completion)
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

/// Host-owned search bar for a hosted screen.
///
/// SwiftUI `.searchable` does not reach a UIKit navigation bar, so
/// `routerSearchable` installs this on the hosting controller's navigation
/// item and keeps the screen's search text and the bar in sync both ways.
@MainActor
final class ScreenSearchController: NSObject, UISearchResultsUpdating, UISearchControllerDelegate {
    let searchController = UISearchController(searchResultsController: nil)
    var onTextChange: (String) -> Void = { _ in }
    private var hidesWhenScrolling = true
    /// The search became active or ended, by the user or by `setPresented`.
    var onPresentationChange: (Bool) -> Void = { _ in }

    init(prompt: String) {
        super.init()
        searchController.searchResultsUpdater = self
        searchController.delegate = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = prompt
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

    func updateSearchResults(for searchController: UISearchController) {
        onTextChange(text)
    }

    func didPresentSearchController(_ searchController: UISearchController) {
        onPresentationChange(true)
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        onPresentationChange(false)
    }
}
