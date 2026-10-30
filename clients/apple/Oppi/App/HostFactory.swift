import SwiftUI
import UIKit

// The SwiftUI half of the router (UIKit half: `Router.swift`).
//
// Every SwiftUI view that becomes a UIKit controller goes through
// `HostFactory`. Screens get the app root services (`AppRootEnvironment`), a
// `ScreenNavigator`, their bar policy, and the theme's color scheme. Hosted
// screens never navigate or present by themselves: SwiftUI navigation inside
// a UIKit stack pushes pages without the app environment, and `dismiss()`
// does nothing at the root of a presented navigation controller. They ask the
// navigator, or declare `routerModal`, which UIKit carries out.
//
// Every hosted screen is its own SwiftUI graph, and SwiftUI stops updating a
// graph whose view left the window (covered by a push or a `.fullScreen`
// modal). So a screen's content is a closure evaluated in that screen's own
// graph: `@Observable` state it reads stays live there. A `@Binding` into
// another screen's `@State` does not refresh across screens; state that two
// screens edit belongs in an `@Observable` model.

// MARK: - Factory

@MainActor
enum HostFactory {
    /// A screen: root services, a navigator, bar policy, theme color scheme.
    /// `content` runs in the screen's own graph, so `@Observable` reads in it
    /// stay live while the screen is up.
    static func screen<Content: View>(
        root: AppRootEnvironment,
        bars: ScreenBars = ScreenBars(),
        @ViewBuilder content: @escaping () -> Content
    ) -> HostedScreenController {
        HostedScreenController(root: root, bars: bars, content: content)
    }

    /// SwiftUI content embedded in a UIKit view, not a screen, with the app
    /// root of the view tree it sits in. Pass the root explicitly (from the
    /// embedding representable's environment, or `AppRootEnvironment.near(_:)` once attached):
    /// embedded hosts are often not child controllers, so they cannot rely on
    /// inheriting it.
    static func content<Content: View>(_ content: Content, root: AppRootEnvironment?) -> HostedContentController {
        guard let root else {
            preconditionFailure("HostFactory.content needs appRootEnvironment(_:) above \(Content.self)")
        }
        return HostedContentController(content: content, root: root)
    }
}

extension Router {
    /// Hosts `content` as a screen and presents it from UIKit.
    ///
    /// The root services come from `root`, or from the app root published
    /// above `presenter`. Presenter-local values go on `content` explicitly
    /// (for example `withServerScopedEnvironment(connection)`); they override
    /// the root's.
    @discardableResult
    static func present<Content: View>(
        root: AppRootEnvironment? = nil,
        presentation: ModalPresentation,
        from presenter: UIViewController,
        sourceView: UIView? = nil,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> HostedScreenController {
        guard let root = root ?? AppRootEnvironment.near(presenter) else {
            preconditionFailure(
                "Router.present needs appRootEnvironment(_:) above \(type(of: presenter))"
            )
        }
        let screen = HostFactory.screen(root: root, bars: presentation.navigation ?? ScreenBars(), content: content)
        if presentation.style == .popover {
            screen.sizingOptions = .preferredContentSize
        }
        present(
            screen,
            presentation: presentation,
            from: presenter,
            sourceView: sourceView,
            theme: root.themeStore,
            onDismiss: onDismiss
        )
        return screen
    }
}

// MARK: - Hosting controllers

/// A hosted SwiftUI screen. Created only by `HostFactory.screen`.
final class HostedScreenController: UIHostingController<AnyView>, RouterModalContainer {
    let navigator: ScreenNavigator
    private let root: AppRootEnvironment
    private let bars: ScreenBars
    private let content: ScreenContent
    var onDismissed: (() -> Void)?

    /// On a vertical toolbar rail (iPhone Duo), where a large title showed
    /// nothing; reported by the screen's content.
    fileprivate var isOnVerticalRail = false {
        didSet {
            guard isOnVerticalRail != oldValue else { return }
            applyTitleDisplayMode()
        }
    }

    fileprivate init<Content: View>(
        root: AppRootEnvironment,
        bars: ScreenBars,
        content make: @escaping () -> Content
    ) {
        let content = ScreenContent { AnyView(make()) }
        let navigator = ScreenNavigator(root: root)
        let railReport = ScreenRailReport()
        self.root = root
        self.bars = bars
        self.content = content
        self.navigator = navigator
        super.init(rootView: AnyView(
            ScreenContentView(content: content, railReport: bars.largeTitle ? railReport : nil)
                .environment(\.screenNavigator, navigator)
                .appRootEnvironment(root)
        ))
        navigator.controller = self
        railReport.controller = self
        // UIKit content inside the screen, and controllers it presents, find
        // the root through the trait bridge.
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        return nil
    }

    /// Replaces the screen's content, keeping its root services and navigator.
    func setContent<Content: View>(@ViewBuilder _ make: @escaping () -> Content) {
        content.make = { AnyView(make()) }
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme store changes.
        overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        if modalPresentationStyle == .popover {
            // The theme's popover surface, as SwiftUI's presentationBackground
            // gave popovers, not the system background.
            let palette = root.themeStore.activeThemeID.palette
            let fill = UIColor(ThemeSurfaceStyle.resolve(.popover, palette: palette).fill)
            view.backgroundColor = fill
            popoverPresentationController?.backgroundColor = fill
        } else {
            // The theme's page, not the system background, behind content
            // that leaves it bare (list gaps, a page without a background).
            view.backgroundColor = root.themeStore.backgroundColor
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let navigation = navigationController else { return }
        applyTitleDisplayMode()
        navigation.setToolbarHidden(!showsToolbarNow, animated: animated)
    }

    // SwiftUI sets the screen's `.bottomBar` items here, after it appears and
    // whenever they change (the inbox drops them on the Duo rail).
    override var toolbarItems: [UIBarButtonItem]? {
        didSet { updateToolbarVisibility(animated: false) }
    }

    override func setToolbarItems(_ toolbarItems: [UIBarButtonItem]?, animated: Bool) {
        super.setToolbarItems(toolbarItems, animated: animated)
        updateToolbarVisibility(animated: animated)
    }

    private var showsToolbarNow: Bool {
        bars.showsToolbar && !(toolbarItems?.isEmpty ?? true)
    }

    private func updateToolbarVisibility(animated: Bool) {
        guard bars.showsToolbar,
              let navigation = navigationController,
              navigation.topViewController === self,
              navigation.isToolbarHidden == showsToolbarNow else { return }
        navigation.setToolbarHidden(!showsToolbarNow, animated: animated)
    }

    private func applyTitleDisplayMode() {
        let large = bars.largeTitle && !isOnVerticalRail
        navigationItem.largeTitleDisplayMode = large ? .always : .never
        if large {
            navigationController?.navigationBar.prefersLargeTitles = true
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigator.screenDidAppear()
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

/// The screen's current content. Replacing `make` re-renders the screen.
@MainActor @Observable
private final class ScreenContent {
    var make: () -> AnyView

    init(_ make: @escaping () -> AnyView) {
        self.make = make
    }
}

/// Tells a large-title screen whether it sits on a vertical toolbar rail.
@MainActor
private final class ScreenRailReport {
    weak var controller: HostedScreenController?
}

/// Reads `@Environment(\.toolbarVerticalEdge)` at the call site.
///
/// The value is the system's preferred edge, not "a pill is on screen". It is
/// nil where iOS never places a vertical bar (a regular iPhone, a full-screen
/// iPad) and non-nil on Duo's outer display even before a toolbar item joins
/// the rail. `verticalPreferred` items are what make the system draw that rail.
/// Below iOS 27.1 the edge is nil.
@MainActor
@ViewBuilder
private func readingToolbarVerticalEdge<Content: View>(
    @ViewBuilder content: @escaping (HorizontalEdge?) -> Content
) -> some View {
    if #available(iOS 27.1, *) {
        ToolbarVerticalEdgeReader(content: content)
    } else {
        content(nil)
    }
}

@available(iOS 27.1, *)
private struct ToolbarVerticalEdgeReader<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    @ViewBuilder var content: (HorizontalEdge?) -> Content

    var body: some View {
        content(edge)
    }
}

/// Evaluates the content closure inside the hosted screen's own graph.
private struct ScreenContentView: View {
    let content: ScreenContent
    let railReport: ScreenRailReport?

    var body: some View {
        if let railReport {
            readingToolbarVerticalEdge { edge in
                content.make()
                    .onChange(of: edge != nil, initial: true) { _, onRail in
                        railReport.controller?.isOnVerticalRail = onRail
                    }
            }
        } else {
            content.make()
        }
    }
}

/// SwiftUI content embedded in UIKit. Created only by `HostFactory.content`.
final class HostedContentController: UIHostingController<AnyView> {
    private let root: AppRootEnvironment

    fileprivate init<Content: View>(content: Content, root: AppRootEnvironment) {
        self.root = root
        super.init(rootView: Self.rootView(content, root: root))
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        return nil
    }

    /// Replaces the content, keeping its root services.
    func setContent<Content: View>(_ content: Content) {
        rootView = Self.rootView(content, root: root)
    }

    private static func rootView<Content: View>(_ content: Content, root: AppRootEnvironment) -> AnyView {
        AnyView(content.appRootEnvironment(root))
    }
}

// MARK: - Navigator

/// What a hosted screen uses instead of navigating or presenting by itself.
///
/// Read it with `@Environment(\.screenNavigator)`. Outcomes are the screen's
/// own typed closures (`onSave`, `onSelect`, ...); after reporting one, the
/// screen calls `finish()`.
@MainActor
final class ScreenNavigator {
    /// The default outside a hosted screen. Every call fails an assertion.
    static let unattached = ScreenNavigator(root: nil)

    /// The screen this navigator acts for: a hosted screen.
    fileprivate weak var controller: UIViewController?
    private let root: AppRootEnvironment?
    private var search: ScreenSearchController?
    /// The search anchors attached to this screen, newest last. Swapping one
    /// searchable view for another (the chat file panel's tabs) attaches the
    /// new anchor while the old one still updates until SwiftUI removes it.
    /// The newest drives the bar, which goes when the last anchor leaves.
    private var searchOwners: [ObjectIdentifier] = []

    fileprivate init(root: AppRootEnvironment?) {
        self.root = root
    }

    /// Pushes a screen onto the navigation controller that holds this one.
    /// Replaces `NavigationLink { destination }` and `navigationDestination`,
    /// whose pages lose the app environment in a UIKit stack. `content` runs
    /// in the pushed screen's graph, so `@Observable` reads in it stay live.
    @discardableResult
    func push<Content: View>(
        bars: ScreenBars = ScreenBars(),
        @ViewBuilder content: @escaping () -> Content
    ) -> HostedScreenController? {
        guard let controller, let root else {
            unattached("push")
            return nil
        }
        let screen = HostFactory.screen(root: root, bars: bars, content: content)
        Router.push(screen, from: controller)
        return screen
    }

    /// Pushes a UIKit screen onto the same stack, as `Router.push(_:from:)`
    /// does from a UIKit screen. Only the debug harness's hosted screens call
    /// it; it goes with the hosted screens.
    func push(_ screen: UIViewController) {
        guard let controller else { return unattached("push") }
        Router.push(screen, from: controller)
    }

    /// Closes this screen: pops it when pushed, otherwise dismisses the modal
    /// it is the root of. The presenter's `onDismiss` runs afterwards.
    func finish() {
        guard let controller else { return unattached("finish") }
        Router.finish(controller)
    }

    /// The bar for `owner`'s search, or nil while a newer anchor drives it.
    fileprivate func searchController(prompt: String, alwaysVisible: Bool, owner: AnyObject) -> ScreenSearchController? {
        let id = ObjectIdentifier(owner)
        if !searchOwners.contains(id) {
            searchOwners.append(id)
        }
        guard searchOwners.last == id else { return nil }
        if let search {
            search.searchController.searchBar.placeholder = prompt
            return search
        }
        guard let controller else {
            unattached("routerSearchable")
            return nil
        }
        let search = ScreenSearchController(prompt: prompt)
        search.install(on: controller, alwaysVisible: alwaysVisible)
        self.search = search
        return search
    }

    fileprivate func screenDidAppear() {
        guard let controller else { return }
        search?.hostDidAppear(controller)
    }

    fileprivate func removeSearchController(owner: AnyObject) {
        searchOwners.removeAll { $0 == ObjectIdentifier(owner) }
        guard searchOwners.isEmpty, let search else { return }
        self.search = nil
        if let controller {
            search.uninstall(from: controller)
        }
    }

    private func unattached(_ operation: String) {
        assertionFailure("ScreenNavigator.\(operation) outside a screen hosted by HostFactory")
    }
}

private struct ScreenNavigatorKey: EnvironmentKey {
    static var defaultValue: ScreenNavigator {
        MainActor.assumeIsolated { .unattached }
    }
}

extension EnvironmentValues {
    var screenNavigator: ScreenNavigator {
        get { self[ScreenNavigatorKey.self] }
        set { self[ScreenNavigatorKey.self] = newValue }
    }
}

extension View {
    /// The services of `connection` on this view's SwiftUI environment: its
    /// stores. The app root applies it for the active server; a hosted screen
    /// that belongs to another server applies it again to override the root's.
    func withServerScopedEnvironment(_ connection: ServerConnection) -> some View {
        self
            .environment(connection)
            .environment(connection.chatState)
            .environment(connection.sessionStore)
            .environment(connection.workspaceStore)
            .environment(connection.serverResourceStore)
            .environment(connection.askRequestStore)
            .environment(connection.audioPlayer)
            .environment(connection.gitStatusStore)
            .environment(connection.fileIndexStore)
            .environment(connection.messageQueueStore)
    }
}

// MARK: - Declarative presentation

/// The SwiftUI content of `RouterScreen.hosted`. Named here so
/// `RouterModalPresenter.swift` needs no `import SwiftUI`.
typealias RouterHostedContent = () -> AnyView

extension View {
    /// A modal that UIKit presents, hosted through `HostFactory`.
    ///
    /// Same contract as `.sheet(item:onDismiss:content:)`: setting the item
    /// presents, clearing it dismisses, a new id replaces the open modal, and
    /// `onDismiss` runs after every dismissal, including swipe-down and the
    /// content's `ScreenNavigator.finish()` (or `dismiss()` when the content is
    /// the presented controller itself). A popover anchors to this view.
    ///
    /// Pass a stored binding (`$state`). A `Binding(get:set:)` built in the
    /// presenter's body reads its getter there, so the whole presenter
    /// re-renders on every open and close; derive it in a small view instead.
    func routerModal<Item: Identifiable, ModalContent: View>(
        item: Binding<Item?>,
        presentation: ModalPresentation = .sheet,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> ModalContent
    ) -> some View {
        routerModal(item: item, presentation: presentation, onDismiss: onDismiss, screen: { item in
            RouterScreen.hosted { AnyView(content(item)) }
        })
    }

    /// `routerModal(item:presentation:onDismiss:content:)` whose root screen
    /// may be a UIKit view controller (`RouterScreen.controller`).
    func routerModal<Item: Identifiable>(
        item: Binding<Item?>,
        presentation: ModalPresentation = .sheet,
        onDismiss: (() -> Void)? = nil,
        screen: @escaping (Item) -> RouterScreen
    ) -> some View {
        background {
            RouterModalAnchor(
                item: item,
                presentation: presentation,
                onDismiss: onDismiss,
                screen: screen
            )
            .accessibilityHidden(true)
        }
    }

    /// Boolean form of `routerModal(item:presentation:onDismiss:screen:)`.
    /// Named apart from `routerModal(isPresented:...content:)`: that one's
    /// trailing-closure call sites would otherwise bind to this overload.
    func routerScreenModal(
        isPresented: Binding<Bool>,
        presentation: ModalPresentation = .sheet,
        onDismiss: (() -> Void)? = nil,
        screen: @escaping () -> RouterScreen
    ) -> some View {
        background {
            RouterModalFlagAnchor(
                isPresented: isPresented,
                presentation: presentation,
                onDismiss: onDismiss,
                screen: { _ in screen() }
            )
            .accessibilityHidden(true)
        }
    }

    /// Boolean form of `routerModal(item:presentation:onDismiss:content:)`.
    func routerModal<ModalContent: View>(
        isPresented: Binding<Bool>,
        presentation: ModalPresentation = .sheet,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> ModalContent
    ) -> some View {
        background {
            RouterModalFlagAnchor(
                isPresented: isPresented,
                presentation: presentation,
                onDismiss: onDismiss,
                screen: { _ in RouterScreen.hosted { AnyView(content()) } }
            )
            .accessibilityHidden(true)
        }
    }

    /// A search bar the host owns (`UISearchController`), bound to `text`
    /// both ways. Replaces `.searchable`, which does not reach a UIKit
    /// navigation bar. The screen must sit in a navigation controller: pushed,
    /// or presented with `ModalPresentation.inNavigation()`. `isPresented`
    /// follows the search becoming active and ends or starts it; set
    /// `hidesNavigationBarDuringPresentation` false to keep the title and
    /// toolbar items while searching (`.searchPresentationToolbarBehavior`).
    /// Removing the modifier takes the bar away.
    func routerSearchable(
        text: Binding<String>,
        isPresented: Binding<Bool>? = nil,
        prompt: String,
        alwaysVisible: Bool = false,
        hidesNavigationBarDuringPresentation: Bool = true
    ) -> some View {
        background {
            RouterSearchAnchor(
                text: text,
                isPresented: isPresented,
                prompt: prompt,
                alwaysVisible: alwaysVisible,
                hidesNavigationBarDuringPresentation: hidesNavigationBarDuringPresentation
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

private struct RouterPresentedFlag: Identifiable {
    var id: Int { 0 }
}

/// Derives the item binding in its own body. `Binding(get:set:)` calls its
/// getter when created: created in the presenter's body, that read made the
/// whole presenter re-render on every open and close.
private struct RouterModalFlagAnchor: View {
    @Binding var isPresented: Bool
    let presentation: ModalPresentation
    let onDismiss: (() -> Void)?
    let screen: (RouterPresentedFlag) -> RouterScreen

    var body: some View {
        RouterModalAnchor(
            item: $isPresented.routerPresentedFlag,
            presentation: presentation,
            onDismiss: onDismiss,
            screen: screen
        )
    }
}

private extension Binding where Value == Bool {
    var routerPresentedFlag: Binding<RouterPresentedFlag?> {
        Binding<RouterPresentedFlag?>(
            get: { wrappedValue ? RouterPresentedFlag() : nil },
            set: { wrappedValue = $0 != nil }
        )
    }
}

/// Invisible controller that marks where the declaring SwiftUI view lives,
/// sized to it so a popover can anchor to it.
final class RouterAnchorController: UIViewController {
    var onAttach: (() -> Void)?

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAttach?()
    }
}

// MARK: Modal anchor

private struct RouterModalAnchor<Item: Identifiable>: UIViewControllerRepresentable {
    @Binding var item: Item?
    let presentation: ModalPresentation
    let onDismiss: (() -> Void)?
    let screen: (Item) -> RouterScreen
    @Environment(\.appRootEnvironment) private var root

    func makeCoordinator() -> RouterModalPresenter {
        RouterModalPresenter()
    }

    func makeUIViewController(context: Context) -> RouterAnchorController {
        let anchor = RouterAnchorController()
        anchor.onAttach = { [weak presenter = context.coordinator] in
            presenter?.sync()
        }
        return anchor
    }

    func updateUIViewController(_ anchor: RouterAnchorController, context: Context) {
        let presenter = context.coordinator
        presenter.anchor = anchor
        presenter.onDismiss = onDismiss
        let binding = $item
        presenter.clearItem = { binding.wrappedValue = nil }
        if let item {
            guard let root else {
                preconditionFailure("routerModal needs appRootEnvironment(_:) above its presenter")
            }
            presenter.request = RouterModalPresenter.Request(
                id: AnyHashable(item.id),
                presentation: presentation,
                root: root,
                screen: screen(item)
            )
        } else {
            presenter.request = nil
        }
        presenter.sync()
    }

    static func dismantleUIViewController(_ anchor: RouterAnchorController, coordinator: RouterModalPresenter) {
        coordinator.request = nil
        coordinator.sync()
    }
}

// MARK: Search anchor

private struct RouterSearchAnchor: UIViewControllerRepresentable {
    @Binding var text: String
    let isPresented: Binding<Bool>?
    let prompt: String
    let alwaysVisible: Bool
    let hidesNavigationBarDuringPresentation: Bool
    @Environment(\.screenNavigator) private var navigator

    final class Coordinator {
        var search: ScreenSearchController?
        var navigator: ScreenNavigator?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> RouterAnchorController {
        let anchor = RouterAnchorController()
        // A screen that asked for search while covered starts it on return.
        anchor.onAttach = { [weak coordinator = context.coordinator, isPresented] in
            guard let presented = isPresented?.wrappedValue else { return }
            coordinator?.search?.setPresented(presented)
        }
        return anchor
    }

    func updateUIViewController(_ anchor: RouterAnchorController, context: Context) {
        let search = navigator.searchController(
            prompt: prompt,
            alwaysVisible: alwaysVisible,
            owner: context.coordinator
        )
        context.coordinator.search = search
        context.coordinator.navigator = navigator
        let binding = $text
        search?.onTextChange = { text in
            if binding.wrappedValue != text {
                binding.wrappedValue = text
            }
        }
        search?.searchController.hidesNavigationBarDuringPresentation = hidesNavigationBarDuringPresentation
        search?.setText(text)
        if let isPresented {
            search?.onPresentationChange = { presented in
                if isPresented.wrappedValue != presented {
                    isPresented.wrappedValue = presented
                }
            }
            search?.setPresented(isPresented.wrappedValue)
        }
    }

    static func dismantleUIViewController(_ anchor: RouterAnchorController, coordinator: Coordinator) {
        coordinator.navigator?.removeSearchController(owner: coordinator)
    }
}
