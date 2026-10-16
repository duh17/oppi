import Combine
import SwiftUI
import Testing
import UIKit
@testable import Oppi

/// What hosted screens rely on instead of SwiftUI navigation inside UIKit
/// containers. The UIKit navigation spike found each of these broken when a
/// SwiftUI screen navigated or searched by itself in a UIKit stack.
@MainActor
@Suite("UIKit router and host factory")
struct RouterHostFactoryTests {
    @Test("a screen pushed through the navigator gets the app services, and finish() pops it")
    func pushedScreenGetsAppServicesAndFinishPops() async throws {
        let root = makeTestAppRoot()
        let probe = ServiceProbe()
        let rootScreen = HostFactory.screen(root: root) { Text("Root") }
        let navigation = RouterNavigationController(rootViewController: rootScreen)
        let window = try showInWindow(navigation)
        defer { hide(window) }

        // A page a hosted screen pushed itself crashed on its first required
        // `@Environment(ThemeStore.self)` read.
        let pushed = try #require(rootScreen.navigator.push {
            ServiceReader(probe: probe)
        })
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            navigation.topViewController === pushed && probe.themeStore != nil
        })
        #expect(probe.themeStore === root.themeStore)
        #expect(probe.coordinator === root.coordinator)

        pushed.navigator.finish()
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            navigation.viewControllers.count == 1
        })
        #expect(navigation.topViewController === rootScreen)
    }

    @Test("finish() at the root of a presented navigation controller dismisses it and runs onDismiss once")
    func finishAtPresentedNavigationRootDismisses() async throws {
        let presenter = UIViewController()
        let window = try showInWindow(presenter)
        defer { hide(window) }
        var dismissals = 0

        // SwiftUI `dismiss()` does nothing here; the sheet stayed up.
        let screen = Router.present(
            root: makeTestAppRoot(),
            presentation: .sheet.inNavigation(),
            from: presenter,
            onDismiss: { dismissals += 1 }
        ) {
            Text("Modal root")
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })
        let navigation = try #require(presenter.presentedViewController as? RouterNavigationController)
        #expect(navigation.viewControllers.first === screen)

        screen.navigator.finish()
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            presenter.presentedViewController == nil && dismissals == 1
        })
        #expect(dismissals == 1)
    }

    @Test("bar policy applies per screen each time it appears, so popping restores the previous screen's bars")
    func barPolicyFollowsTheVisibleScreen() async throws {
        let rootScreen = HostFactory.screen(
            root: makeTestAppRoot(),
            bars: ScreenBars(largeTitle: true, showsToolbar: true)
        ) {
            Text("Root")
                .navigationTitle("Root")
        }
        let navigation = RouterNavigationController(rootViewController: rootScreen)
        let window = try showInWindow(navigation)
        defer { hide(window) }

        // `.bottomBar` items need the toolbar shown; large titles need the bar to prefer them.
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            rootScreen.viewIfLoaded?.window != nil
        })
        #expect(navigation.navigationBar.prefersLargeTitles)
        #expect(rootScreen.navigationItem.largeTitleDisplayMode == .always)
        #expect(!navigation.isToolbarHidden)

        let pushed = try #require(rootScreen.navigator.push {
            Text("Detail")
                .navigationTitle("Detail")
        })
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            navigation.transitionCoordinator == nil && navigation.topViewController === pushed
        })
        #expect(pushed.navigationItem.largeTitleDisplayMode == .never)
        #expect(navigation.isToolbarHidden)

        pushed.navigator.finish()
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            navigation.transitionCoordinator == nil && navigation.viewControllers.count == 1
        })
        #expect(rootScreen.navigationItem.largeTitleDisplayMode == .always)
        #expect(!navigation.isToolbarHidden)
    }

    @Test("a pushed screen builds its content in its own graph, so observable state stays live while the presenter is covered")
    func pushedContentStaysLiveWhilePresenterIsCovered() async throws {
        let state = RouteState()
        let probe = LabelProbe()
        let rootScreen = HostFactory.screen(root: makeTestAppRoot()) { Text("Root") }
        let navigation = RouterNavigationController(rootViewController: rootScreen)
        let window = try showInWindow(navigation)
        defer { hide(window) }

        // The covered presenter's own graph no longer updates; the value is
        // read where the pushed screen renders.
        rootScreen.navigator.push {
            LabelRecorder(label: state.query, probe: probe)
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            navigation.transitionCoordinator == nil && probe.labels == [""]
        })
        #expect(rootScreen.viewIfLoaded?.window == nil)

        state.query = "live"
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            probe.labels == ["", "live"]
        })
    }

    @Test("routerModal presents for an item, clears it after any dismissal, and runs onDismiss each time")
    func routerModalFollowsItem() async throws {
        let state = RouteState()
        var dismissals = 0
        let presenter = HostFactory.screen(root: makeTestAppRoot()) {
            ModalScreen(state: state, onDismiss: { dismissals += 1 })
        }
        let window = try showInWindow(presenter)
        defer { hide(window) }

        state.item = RouteItem(id: "first")
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })

        // Swipe-down: UIKit dismisses without the binding.
        presenter.dismiss(animated: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            presenter.presentedViewController == nil && state.item == nil && dismissals == 1
        })

        state.item = RouteItem(id: "second")
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })
        state.item = nil
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            presenter.presentedViewController == nil && dismissals == 2
        })
    }

    /// Every presenter sits in a SwiftUI `NavigationStack` until the app shell
    /// moves to UIKit. A modal presented during that stack's update put its
    /// title and Cancel into the stack's bar and left its own bar empty.
    @Test("a routerModal declared in a SwiftUI NavigationStack keeps its title and bar items in its own bar")
    func routerModalFromNavigationStackKeepsItsBar() async throws {
        let state = RouteState()
        let presenter = HostFactory.screen(root: makeTestAppRoot()) {
            NavigationStack { StackPresenterScreen(state: state) }
        }
        let window = try showInWindow(presenter)
        defer { hide(window) }

        state.showsSheet = true
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })
        let navigation = try #require(presenter.presentedViewController as? RouterNavigationController)
        let modal = try #require(navigation.topViewController)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            modal.navigationItem.title == "Modal Title"
        })
        let item = modal.navigationItem
        let barItems = (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
            + (item.leadingItemGroups + item.trailingItemGroups).flatMap(\.barButtonItems)
        #expect(!barItems.isEmpty, "The modal's Cancel belongs in its own bar")
        #expect(stackItemTitles(in: presenter.view.window).allSatisfy { $0 != "Modal Title" })
    }

    /// UIKit reads the lock from the presented controller, which is the
    /// navigation container, not the hosted screen that asked for it.
    @Test("interactiveDismissDisabled locks a sheet in a navigation controller only while it is set")
    func interactiveDismissDisabledLocksNavigationSheet() async throws {
        let state = RouteState()
        let presenter = HostFactory.screen(root: makeTestAppRoot()) {
            LockingSheetScreen(state: state)
        }
        let window = try showInWindow(presenter)
        defer { hide(window) }

        state.showsSheet = true
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })
        let navigation = try #require(presenter.presentedViewController as? RouterNavigationController)
        #expect(!navigation.isModalInPresentation)

        state.locked = true
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            navigation.isModalInPresentation
        })
        state.locked = false
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            !navigation.isModalInPresentation
        })
    }

    /// The flag form derived its item binding in the presenter's body, and
    /// `Binding(get:set:)` reads its getter when created: every open and close
    /// re-rendered the presenter (a chat re-rendered its whole timeline).
    @Test("opening and closing a boolean routerModal leaves the presenter's body alone")
    func flagModalDoesNotRerenderPresenter() async throws {
        let opens = PassthroughSubject<Bool, Never>()
        let renders = RenderCount()
        let presenter = HostFactory.screen(root: makeTestAppRoot()) {
            FlagModalScreen(opens: opens, renders: renders)
        }
        let window = try showInWindow(presenter)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { renders.value > 0 })
        let rendersBeforeOpening = renders.value

        opens.send(true)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })
        opens.send(false)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            presenter.presentedViewController == nil
        })
        #expect(renders.value == rendersBeforeOpening)
    }

    @Test("a repeated disappearance runs onDismiss once and leaves a newer presentation alone")
    func repeatedDisappearanceRunsOnDismissOnce() async throws {
        let state = RouteState()
        var dismissals = 0
        let presenter = HostFactory.screen(root: makeTestAppRoot()) {
            ModalScreen(state: state, onDismiss: { dismissals += 1 })
        }
        let window = try showInWindow(presenter)
        defer { hide(window) }

        state.item = RouteItem(id: "first")
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })
        let first = try #require(presenter.presentedViewController)
        presenter.dismiss(animated: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            presenter.presentedViewController == nil && dismissals == 1
        })

        // UIKit reporting the same disappearance again.
        first.viewDidDisappear(false)
        #expect(dismissals == 1)

        state.item = RouteItem(id: "second")
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })
        first.viewDidDisappear(false)
        #expect(dismissals == 1)
        #expect(state.item?.id == "second")
        #expect(presenter.presentedViewController !== first)
        #expect(isSettled(presenter.presentedViewController))
    }

    @Test("routerSearchable gives the host a search bar bound to the screen's text both ways")
    func searchTextBridgesBothWays() async throws {
        let state = RouteState()
        let screen = HostFactory.screen(root: makeTestAppRoot()) { SearchingScreen(state: state) }
        let navigation = RouterNavigationController(rootViewController: screen)
        let window = try showInWindow(navigation)
        defer { hide(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            screen.navigationItem.searchController != nil
        })
        let searchController = try #require(screen.navigationItem.searchController)
        #expect(searchController.searchBar.placeholder == "Search rows")

        // Typing: UIKit reports the bar's text through the results updater.
        searchController.searchBar.text = "tok"
        searchController.searchResultsUpdater?.updateSearchResults(for: searchController)
        #expect(state.query == "tok")

        // Screen state to bar: a restored or cleared query.
        state.query = "osaka"
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            searchController.searchBar.text == "osaka"
        })
        #expect(screen.navigationItem.searchController === searchController)
    }

    @Test("presented modals follow the theme store's color scheme, including system mode")
    func modalFollowsThemeColorScheme() async throws {
        try await withCleanThemeDefaults {
            UserDefaults.standard.set(ThemeID.dark.rawValue, forKey: ThemeID.storageKey)
            let themeStore = ThemeStore(initialSystemColorScheme: .dark, systemColorSchemeProvider: { _ in .dark })
            let presenter = UIViewController()
            let window = try showInWindow(presenter)
            defer { hide(window) }

            let screen = Router.present(
                root: makeTestAppRoot(themeStore: themeStore),
                presentation: .sheet.inNavigation(),
                from: presenter
            ) {
                Text("Themed")
            }
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
                isSettled(presenter.presentedViewController)
            })
            let navigation = try #require(presenter.presentedViewController as? RouterNavigationController)

            func styles() -> [UIUserInterfaceStyle] {
                navigation.view.setNeedsLayout()
                navigation.view.layoutIfNeeded()
                return [navigation.overrideUserInterfaceStyle, screen.overrideUserInterfaceStyle]
            }

            #expect(await waitForMainActorCondition(timeout: .seconds(3)) { styles() == [.dark, .dark] })

            themeStore.selectedThemeID = .light
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) { styles() == [.light, .light] })

            themeStore.mode = .system
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
                styles() == [.unspecified, .unspecified]
            })
        }
    }

    /// A chat is a SwiftUI navigation destination, and UIKit code under it
    /// presents from controllers no hosted screen owns. Both must find the root.
    @Test("the app root reaches SwiftUI navigation destinations and UIKit anywhere in the window")
    func appRootReachesNavigationDestinationsAndTheWindow() async throws {
        let root = makeTestAppRoot()
        let capture = ControllerCapture()
        let host = UIHostingController(
            rootView: NavigationStack {
                Color.clear.navigationDestination(isPresented: .constant(true)) {
                    CapturedController(capture: capture)
                }
            }
            .appRootEnvironment(root)
            .publishesAppRootToWindow(root)
        )
        let window = try showInWindow(host)
        defer { hide(window) }

        // Trait changes reach the hierarchy on the next update pass.
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            guard let controller = capture.controller, controller.viewIfLoaded?.window != nil else { return false }
            return HostFactory.root(near: controller) == root
        })
        let controller = try #require(capture.controller)
        #expect(capture.environmentRoot == root, "The SwiftUI value must survive a navigation push")
        #expect(HostFactory.root(near: controller.view) == root)

        let presented = UIViewController()
        controller.present(presented, animated: false)
        #expect(HostFactory.root(near: presented) == root)
        presented.dismiss(animated: false)

        let probe = ServiceProbe()
        let content = HostFactory.content(ServiceReader(probe: probe), root: HostFactory.root(near: controller.view))
        controller.addChild(content)
        content.view.frame = controller.view.bounds
        controller.view.addSubview(content.view)
        content.didMove(toParent: controller)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { probe.themeStore != nil })
        #expect(probe.themeStore === root.themeStore)
    }

    /// A document viewer covers the window in regular width and is a page
    /// sheet in compact width. It kept the style it opened with when the
    /// size class changed under it.
    @Test("a routerModal whose requested style changes presents the same item again, keeping its binding")
    func routerModalRepresentsWhenItsStyleChanges() async throws {
        let state = RestyleState()
        var dismissals = 0
        let presenter = HostFactory.screen(root: makeTestAppRoot()) {
            RestylingScreen(state: state, onDismiss: { dismissals += 1 })
        }
        let window = try showInWindow(presenter)
        defer { hide(window) }

        state.isPresented = true
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })
        let sheet = try #require(presenter.presentedViewController)
        #expect(sheet.modalPresentationStyle == .pageSheet)

        state.coversWindow = true
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            guard let cover = presenter.presentedViewController else { return false }
            return cover !== sheet && cover.modalPresentationStyle == .overFullScreen && isSettled(cover)
        })
        #expect(state.isPresented, "Presenting again must not clear the binding")
        #expect(dismissals == 0, "Presenting again is not a dismissal")

        // Detents of the same style change in place.
        state.coversWindow = false
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            presenter.presentedViewController?.modalPresentationStyle == .pageSheet
                && isSettled(presenter.presentedViewController)
        })
        let pageSheet = try #require(presenter.presentedViewController)
        state.allowsMedium = true
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            pageSheet.sheetPresentationController?.detents.map(\.identifier) == [.medium, .large]
        })
        #expect(presenter.presentedViewController === pageSheet)

        state.isPresented = false
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            presenter.presentedViewController == nil && dismissals == 1
        })
    }

    @Test("a router popover anchors to the declaring SwiftUI view and stays a popover in compact width")
    func popoverAnchorsToDeclaringView() async throws {
        let state = RouteState()
        let presenter = HostFactory.screen(root: makeTestAppRoot()) { PopoverScreen(state: state) }
        let window = try showInWindow(presenter)
        defer { hide(window) }

        state.showsPopover = true
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })
        let presented = try #require(presenter.presentedViewController)
        #expect(presented.modalPresentationStyle == .popover)
        let source = try #require(presented.popoverPresentationController?.sourceView)
        #expect(abs(source.bounds.width - 120) < 1)
        #expect(abs(source.bounds.height - 44) < 1)
        // Adapted to a sheet, the content would span the compact window.
        #expect(presented.view.frame.width < window.bounds.width - 40)

        state.showsPopover = false
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            presenter.presentedViewController == nil
        })
    }

    /// A screen the router created inside SwiftUI's update pass was tied to
    /// the presenter's graph: a modal with its own `NavigationStack`, opened
    /// from a SwiftUI stack's destination, reset that stack to its root, and
    /// the modal went with it (a chat in the workspace stack popped).
    @Test(
        "a modal with its own NavigationStack keeps the SwiftUI stack destination it opened from",
        arguments: [false, true]
    )
    func modalWithOwnStackKeepsPresentersStack(overFullScreen: Bool) async throws {
        let state = StackState()
        let host = HostFactory.screen(root: makeTestAppRoot()) {
            StackShell(state: state, opens: overFullScreen ? .overFullScreen : .sheet)
        }
        let window = try showInWindow(host)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { stackDepth(in: host) == 2 })

        state.opensPanel = true
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { isSettled(host.presentedViewController) })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(800)) {
            stackDepth(in: host) == 2 && host.presentedViewController != nil
        })

        // The presenter re-renders under the open modal and refreshes it.
        state.revision += 1
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(800)) {
            stackDepth(in: host) == 2 && host.presentedViewController != nil
        })
    }

    @Test("a trailing column beside a SwiftUI stack destination shows its panel and keeps the destination")
    func trailingColumnKeepsEnclosingStack() async throws {
        let state = StackState()
        let host = HostFactory.screen(root: makeTestAppRoot()) { StackShell(state: state, opens: .column) }
        let window = try showInWindow(host)
        defer { hide(window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { stackDepth(in: host) == 2 })

        state.opensPanel = true
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { hasColumnPanel(in: host) })
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(800)) {
            stackDepth(in: host) == 2 && hasColumnPanel(in: host)
        })
    }
}

// MARK: - Fixtures

private struct RouteItem: Identifiable {
    let id: String
}

@MainActor @Observable
private final class RouteState {
    var showsPopover = false
    var showsSheet = false
    var locked = false
    var item: RouteItem?
    var query = ""
}

/// Counts body evaluations; not observed, so counting re-renders nothing.
@MainActor
private final class RenderCount {
    var value = 0
}

/// Owns its flag in `@State`, as chat does; the test sets it through `opens`
/// (`onReceive` adds no dependency of its own).
private struct FlagModalScreen: View {
    let opens: PassthroughSubject<Bool, Never>
    let renders: RenderCount
    @State private var isPresented = false

    var body: some View {
        let _ = renders.value += 1
        Text("Presenter")
            .routerModal(isPresented: $isPresented) {
                Text("Modal")
            }
            .onReceive(opens) { isPresented = $0 }
    }
}

@MainActor @Observable
private final class StackState {
    var path = [1]
    var opensPanel = false
    var revision = 0
}

/// A SwiftUI `NavigationStack` showing a pushed destination, which opens a
/// router modal with a stack of its own, or a trailing column.
private struct StackShell: View {
    enum Panel { case sheet, overFullScreen, column }

    @Bindable var state: StackState
    let opens: Panel

    var body: some View {
        NavigationStack(path: $state.path) {
            Text("Root")
                .navigationDestination(for: Int.self) { _ in destination }
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch opens {
        case .sheet, .overFullScreen:
            let revision = state.revision
            Text("Destination \(revision)")
                .routerModal(
                    isPresented: $state.opensPanel,
                    presentation: opens == .sheet ? .sheet : ModalPresentation(style: .overFullScreen)
                ) {
                    NavigationStack { Text("Panel \(revision)") }
                }
        case .column:
            Text("Destination")
                .routerTrailingColumn(
                    item: state.opensPanel ? RouteItem(id: "panel") : nil,
                    minWidth: 100,
                    idealWidth: 150
                ) { _ in
                    Text("Panel")
                }
        }
    }
}

@MainActor
private final class ServiceProbe {
    var themeStore: ThemeStore?
    var coordinator: ConnectionCoordinator?
}

/// Reads required app services, as real screens do.
private struct ServiceReader: View {
    let probe: ServiceProbe
    @Environment(ThemeStore.self) private var themeStore
    @Environment(ConnectionCoordinator.self) private var coordinator

    var body: some View {
        Text("Services")
            .onAppear {
                probe.themeStore = themeStore
                probe.coordinator = coordinator
            }
    }
}

@MainActor
private final class LabelProbe {
    var labels: [String] = []
}

/// Records each label it is rendered with.
private struct LabelRecorder: View {
    let label: String
    let probe: LabelProbe

    var body: some View {
        Text(label)
            .onAppear { probe.labels.append(label) }
            .onChange(of: label) { _, newLabel in probe.labels.append(newLabel) }
    }
}

private struct ModalScreen: View {
    @Bindable var state: RouteState
    let onDismiss: () -> Void

    var body: some View {
        Text("Presenter")
            .routerModal(item: $state.item, onDismiss: onDismiss) { item in
                Text("Modal \(item.id)")
            }
    }
}

private struct StackPresenterScreen: View {
    @Bindable var state: RouteState

    var body: some View {
        Text("Presenter")
            .navigationTitle("Presenter Title")
            .routerModal(isPresented: $state.showsSheet, presentation: .sheet.inNavigation()) {
                Text("Modal")
                    .navigationTitle("Modal Title")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {}
                        }
                    }
            }
    }
}

private struct LockingSheetScreen: View {
    @Bindable var state: RouteState

    var body: some View {
        Text("Presenter")
            .routerModal(isPresented: $state.showsSheet, presentation: .sheet.inNavigation()) {
                Text("Saving")
                    .interactiveDismissDisabled(state.locked)
            }
    }
}

/// Titles of every navigation item shown by the window's navigation bars,
/// outside presented controllers.
@MainActor
private func stackItemTitles(in window: UIWindow?) -> [String] {
    func bars(in view: UIView) -> [UINavigationBar] {
        view.subviews.flatMap { ($0 as? UINavigationBar).map { [$0] } ?? bars(in: $0) }
    }
    guard let root = window?.rootViewController?.view else { return [] }
    return bars(in: root).flatMap { $0.items ?? [] }.compactMap(\.title)
}

private struct SearchingScreen: View {
    @Bindable var state: RouteState

    var body: some View {
        List {
            Text("Row")
        }
        .routerSearchable(text: $state.query, prompt: "Search rows")
    }
}

@MainActor @Observable
private final class RestyleState {
    var isPresented = false
    var coversWindow = false
    var allowsMedium = false
}

private struct RestylingScreen: View {
    @Bindable var state: RestyleState
    let onDismiss: () -> Void

    var body: some View {
        Text("Presenter")
            .routerModal(isPresented: $state.isPresented, presentation: presentation, onDismiss: onDismiss) {
                Text("Viewer")
            }
    }

    private var presentation: ModalPresentation {
        if state.coversWindow { return ModalPresentation(style: .overFullScreen) }
        return ModalPresentation.pageSheet.detents(state.allowsMedium ? [.medium(), .large()] : [.large()])
    }
}

private struct PopoverScreen: View {
    @Bindable var state: RouteState

    var body: some View {
        VStack {
            Spacer()
            Text("Anchor")
                .frame(width: 120, height: 44)
                .routerModal(isPresented: $state.showsPopover, presentation: .popover.keepsPopoverInCompactWidth()) {
                    Text("Popover")
                }
            Spacer()
        }
    }
}

@MainActor
private final class ControllerCapture {
    var controller: UIViewController?
    var environmentRoot: AppRootEnvironment?
}

private struct CapturedController: UIViewControllerRepresentable {
    let capture: ControllerCapture

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        capture.controller = controller
        capture.environmentRoot = context.environment.appRootEnvironment
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

// MARK: - Helpers

/// The depth of the first navigation controller under `controller`.
@MainActor
private func stackDepth(in controller: UIViewController) -> Int {
    if let navigation = controller as? UINavigationController {
        return navigation.viewControllers.count
    }
    for child in controller.children {
        let depth = stackDepth(in: child)
        if depth >= 0 { return depth }
    }
    return -1
}

/// Whether a trailing column under `controller` shows a panel.
@MainActor
private func hasColumnPanel(in controller: UIViewController) -> Bool {
    if controller is TrailingColumnController {
        return !controller.children.isEmpty
    }
    return controller.children.contains(where: hasColumnPanel)
}

/// Animated pushes only finish in a window on the test host's scene.
@MainActor
private func showInWindow(_ controller: UIViewController) throws -> UIWindow {
    let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
        "router tests need the test host's window scene"
    )
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.layoutIfNeeded()
    return window
}

@MainActor
private func hide(_ window: UIWindow) {
    window.rootViewController?.dismiss(animated: false)
    window.isHidden = true
    window.rootViewController = nil
}

@MainActor
private func isSettled(_ presented: UIViewController?) -> Bool {
    guard let presented else { return false }
    return !presented.isBeingPresented && presented.viewIfLoaded?.window != nil
}

/// Theme stores persist mode and theme ids; restore what the test changed.
@MainActor
private func withCleanThemeDefaults(_ body: @MainActor () async throws -> Void) async rethrows {
    let originalThemeID = ThemeRuntimeState.currentThemeID()
    let keys = [
        ThemeID.storageKey,
        "\(AppIdentifiers.subsystem).theme.mode",
        "\(AppIdentifiers.subsystem).theme.light.id",
        "\(AppIdentifiers.subsystem).theme.dark.id",
    ]
    let originals = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
    for key in keys {
        UserDefaults.standard.removeObject(forKey: key)
    }
    defer {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
            if let value = originals[key], let value {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        ThemeRuntimeState.setThemeID(originalThemeID)
    }
    try await body()
}
