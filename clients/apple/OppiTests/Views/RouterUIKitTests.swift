import Testing
import UIKit
@testable import Oppi

/// The UIKit router: a push carries the app root, the shell's stack follows
/// `AppNavigation`, bar policy follows the screen in front, a slot presents and
/// replaces its modal and closes with its screen, and a presentation follows the
/// theme. Every screen is UIKit, `.controller` roots included.
@MainActor
@Suite("UIKit router")
struct RouterUIKitTests {
    /// A pushed reader that hides the navigation bar for its own chrome once it
    /// is the top screen, as the file viewers do from their updates: it says so
    /// through `NavigationBarHiding` and asks the stack to apply it.
    private final class BarHidingReaderViewController: UIViewController, NavigationBarHiding {
        var hidesNavigationBar: Bool { true }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            navigationController?.updateNavigationBar(for: self, animated: false)
        }
    }

    /// The SSH host list and the Tailnet page read the root by trait while they
    /// build, before any window publishes one, so the push has to carry it.
    @Test("Router.push gives a screen the host's app root, and keeps the root it has")
    func pushCopiesTheHostRootOntoAScreenWithoutOne() {
        let hostRoot = makeTestAppRoot()
        let ownRoot = makeTestAppRoot()
        #expect(hostRoot != ownRoot)
        let host = UIViewController()
        host.traitOverrides.appRootEnvironment = hostRoot
        // Not in a window: nothing publishes a root above the host.
        let navigation = UINavigationController(rootViewController: host)

        let bare = UIViewController()
        Router.push(bare, from: host)
        #expect(bare.traitOverrides.appRootEnvironment == hostRoot)

        let owning = UIViewController()
        owning.traitOverrides.appRootEnvironment = ownRoot
        Router.push(owning, from: host)
        #expect(owning.traitOverrides.appRootEnvironment == ownRoot)
        withExtendedLifetime(navigation) {}
    }

    @Test("finish() at the root of a presented navigation controller dismisses it and runs onDismiss once")
    func finishAtPresentedNavigationRootDismisses() async throws {
        let presenter = UIViewController()
        let window = try showInWindow(presenter)
        defer { hide(window) }
        var dismissals = 0

        // SwiftUI `dismiss()` did nothing here; the sheet stayed up.
        let screen = UIViewController()
        Router.present(
            screen,
            presentation: .sheet.inNavigation(),
            from: presenter,
            theme: makeTestAppRoot().themeStore,
            onDismiss: { dismissals += 1 }
        )
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(presenter.presentedViewController)
        })
        let navigation = try #require(presenter.presentedViewController as? RouterNavigationController)
        #expect(navigation.viewControllers.first === screen)

        Router.finish(screen)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            presenter.presentedViewController == nil && dismissals == 1
        })
        #expect(dismissals == 1)
    }

    @Test("the shell's stack follows AppNavigation, and Back keeps AppNavigation in step")
    func shellStackFollowsNavigationAndReportsPops() async throws {
        let root = makeTestAppRoot()
        let navigation = root.navigation
        let window = try showInWindow(WorkspaceShellController(root: root))
        defer { hide(window) }
        var stack: ShellNavigationController?
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            stack = shellStack(in: window.rootViewController)
            return stack?.viewControllers.count == 1
        })
        let shellStack = try #require(stack)

        navigation.openWorkspaceUtility(.skills)
        navigation.openWorkspaceUtility(.extensions)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            shellStack.transitionCoordinator == nil && shellStack.viewControllers.count == 3
        })

        // A page a screen pushes itself sits above its route, outside AppNavigation.
        let extensions = try #require(shellStack.topViewController as? ServerExtensionsViewController)
        Router.push(UIViewController(), from: extensions)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            shellStack.transitionCoordinator == nil && shellStack.viewControllers.count == 4
        })
        shellStack.popViewController(animated: false)
        #expect(navigation.workspaceStackRouteElements == [.utility(.skills), .utility(.extensions)])

        // Back from a route pops it from AppNavigation too.
        shellStack.popViewController(animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            navigation.workspaceStackRouteElements == [.utility(.skills)]
        })

        // Replacing the stack in AppNavigation replaces the UIKit stack.
        navigation.showAllWorkspaceSessions()
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            shellStack.transitionCoordinator == nil && shellStack.viewControllers.count == 1
        })
        #expect(navigation.workspaceStackRouteElements.isEmpty)
    }

    @Test("popping a reader that hid the shell's bar brings the bar and Back back")
    func shellStackShowsBarAgainAfterReaderPops() async throws {
        let root = makeTestAppRoot()
        let window = try showInWindow(WorkspaceShellController(root: root))
        defer { hide(window) }
        var stack: ShellNavigationController?
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            stack = shellStack(in: window.rootViewController)
            return stack?.viewControllers.count == 1
        })
        let shellStack = try #require(stack)

        root.navigation.openWorkspaceUtility(.skills)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            shellStack.transitionCoordinator == nil && shellStack.viewControllers.count == 2
        })
        let skills = try #require(shellStack.topViewController as? ServerSkillsViewController)

        // A reader hides the bar for its own chrome, as a Skill file did.
        Router.push(BarHidingReaderViewController(), from: skills)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            shellStack.transitionCoordinator == nil && shellStack.isNavigationBarHidden
        })

        shellStack.popViewController(animated: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            shellStack.transitionCoordinator == nil && shellStack.topViewController === skills
        })
        #expect(!shellStack.isNavigationBarHidden)
    }

    /// The shell drops its whole layout on an iPad rotation (stack↔split) and
    /// when a scoped server lock engages. A chat's modal presents from the
    /// window's root, so it outlived the chat: further typing in the expanded
    /// composer went nowhere, Cancel did nothing, and a locked server's sheet
    /// stayed above the lock cover. The chat can have two up at once: its
    /// model picker over its expanded composer.
    @Test("a screen's open modals close when the shell tears the screen down, without calling back into it")
    func ownerTeardownDismissesItsModals() async throws {
        let shell = UIViewController()
        let window = try showInWindow(shell)
        defer { hide(window) }
        var clears = 0
        var dismissals = 0
        weak var weakOwner: ModalOwnerScreen?
        do {
            let owner = ModalOwnerScreen()
            weakOwner = owner
            shell.addChild(owner)
            shell.view.addSubview(owner.view)
            owner.didMove(toParent: shell)

            let root = makeTestAppRoot()
            func open(_ slot: RouterModalPresenter, _ presentation: ModalPresentation) {
                slot.update(
                    id: AnyHashable("open"),
                    presentation: presentation.inNavigation(),
                    root: root,
                    onDismiss: { dismissals += 1 },
                    clear: { clears += 1 },
                    screen: { .controller { UIViewController() } }
                )
            }
            open(owner.lower, ModalPresentation(style: .overFullScreen))
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
                isSettled(shell.presentedViewController)
            })
            open(owner.upper, .sheet)
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
                isSettled(shell.presentedViewController?.presentedViewController)
            })

            // `WorkspaceShellController.replaceLayout`: the layout leaves and
            // nothing keeps its screens.
            owner.willMove(toParent: nil)
            owner.view.removeFromSuperview()
            owner.removeFromParent()
        }
        // UIKit may hold the removed screen until its autorelease pool drains.
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { weakOwner == nil })

        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            shell.presentedViewController == nil
        })
        #expect(clears == 0)
        #expect(dismissals == 0)
    }

    @Test("presented modals follow the theme store's color scheme, including system mode")
    func modalFollowsThemeColorScheme() async throws {
        try await withCleanThemeDefaults {
            UserDefaults.standard.set(ThemeID.dark.rawValue, forKey: ThemeID.storageKey)
            let themeStore = ThemeStore(initialSystemColorScheme: .dark, systemColorSchemeProvider: { _ in .dark })
            let presenter = UIViewController()
            let window = try showInWindow(presenter)
            defer { hide(window) }

            Router.present(
                UIViewController(),
                presentation: .sheet.inNavigation(),
                from: presenter,
                theme: themeStore
            )
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
                isSettled(presenter.presentedViewController)
            })
            let navigation = try #require(presenter.presentedViewController as? RouterNavigationController)

            func style() -> UIUserInterfaceStyle {
                navigation.view.setNeedsLayout()
                navigation.view.layoutIfNeeded()
                return navigation.overrideUserInterfaceStyle
            }

            #expect(await waitForMainActorCondition(timeout: .seconds(3)) { style() == .dark })

            themeStore.selectedThemeID = .light
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) { style() == .light })

            themeStore.mode = .system
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) { style() == .unspecified })
        }
    }

    /// `ModalPresentation` is the one style a screen picks, and a live slot
    /// (the icon picker's) changes it while it is open: a sheet that grows into
    /// a window-covering viewer, or detents that change under the sheet.
    @Test("a slot presents the same item again when its style changes, and moves detents in place")
    func slotRepresentsOnStyleChangeAndMovesDetentsInPlace() async throws {
        let owner = ModalSlotScreen()
        let window = try showInWindow(RouterNavigationController(rootViewController: owner))
        defer { hide(window) }

        owner.show("open", .pageSheet.inNavigation())
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(owner.presentedViewController)
        })
        let sheet = try #require(owner.presentedViewController)
        #expect(sheet.modalPresentationStyle == .pageSheet)

        // Same style, other chrome: the sheet on screen takes it.
        owner.show("open", .pageSheet.detents([.medium(), .large()], grabber: true).inNavigation())
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            sheet.sheetPresentationController?.detents.map(\.identifier) == [.medium, .large]
                && sheet.sheetPresentationController?.prefersGrabberVisible == true
        })
        #expect(owner.presentedViewController === sheet, "a chrome change must not present again")

        // A style UIKit cannot restyle in place: the same item, presented again.
        owner.show("open", ModalPresentation(style: .overFullScreen).inNavigation())
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            guard let cover = owner.presentedViewController else { return false }
            return cover !== sheet && cover.modalPresentationStyle == .overFullScreen && isSettled(cover)
        })
        #expect(owner.dismissals == 0, "presenting again is not a dismissal")
        #expect(owner.clears == 0, "presenting again must not clear the slot")
        #expect(owner.presentedID as? String == "open")
    }

    @Test("a repeated disappearance runs onDismiss once and leaves a newer presentation alone")
    func repeatedDisappearanceRunsOnDismissOnce() async throws {
        let owner = ModalSlotScreen()
        let window = try showInWindow(RouterNavigationController(rootViewController: owner))
        defer { hide(window) }

        owner.show("first", .sheet.inNavigation())
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(owner.presentedViewController)
        })
        let first = try #require(owner.presentedViewController)
        owner.dismiss(animated: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            owner.presentedViewController == nil && owner.dismissals == 1
        })

        // UIKit reporting the same disappearance again.
        first.viewDidDisappear(false)
        #expect(owner.dismissals == 1)

        owner.show("second", .sheet.inNavigation())
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(owner.presentedViewController)
        })
        let second = try #require(owner.presentedViewController)
        first.viewDidDisappear(false)
        #expect(owner.dismissals == 1, "a stale disappearance must not run the newer item's onDismiss")
        #expect(owner.presentedViewController === second)
        #expect(owner.presentedID as? String == "second", "a stale callback must not clear the slot")
    }

    /// Swipe-down dismisses without touching the slot's state, so the slot has to
    /// clear itself or the next pass presents the modal straight back.
    @Test("a swipe-down clears the slot, and the slot does not present it again")
    func swipeDownClearsTheSlot() async throws {
        let owner = ModalSlotScreen()
        let window = try showInWindow(RouterNavigationController(rootViewController: owner))
        defer { hide(window) }

        owner.show("notice", .sheet.detents([.medium()]).inNavigation())
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(owner.presentedViewController)
        })

        owner.dismiss(animated: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            owner.presentedID == nil && owner.clears == 1 && owner.dismissals == 1
        })

        // `sync()` presents on the next run-loop turn, so the slot has to sit through
        // that turn before "it did not come back" means anything.
        owner.slot.sync()
        try await Task.sleep(for: .milliseconds(300))
        #expect(owner.presentedViewController == nil, "a cleared slot must not present again")
    }

    /// A picker presented from a Duo or a compact iPad: UIKit adapts a popover to
    /// a sheet unless the presentation says not to.
    @Test("a slot's popover stays a popover in compact width")
    func popoverStaysAPopoverInCompactWidth() async throws {
        let owner = ModalSlotScreen()
        let window = try showInWindow(RouterNavigationController(rootViewController: owner))
        defer { hide(window) }
        #expect(window.traitCollection.horizontalSizeClass == .compact)

        owner.show("popover", .popover.keepsPopoverInCompactWidth().inNavigation())
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            isSettled(owner.presentedViewController)
        })
        let popover = try #require(owner.presentedViewController)
        #expect(popover.modalPresentationStyle == .popover)
        // A popover keeps its own geometry; an adapted sheet spans the window's
        // width. The size is what changes when the adaptation is no longer refused.
        #expect(
            popover.presentationController?.presentationStyle == .popover,
            "adapted to a sheet in compact width"
        )
        #expect(
            popover.view.frame.width < window.bounds.width - 40,
            "the popover took the whole width (\(popover.view.frame.width) of \(window.bounds.width))"
        )
    }

    /// The keyboard spans the window. A field in the trailing column lifted
    /// the chat's composer beside it over the timeline; the screen's own
    /// field still moves it, and closing the column gives the keyboard back.
    @Test("a trailing column's field leaves the screen beside it in place")
    func trailingColumnFieldLeavesTheScreenInPlace() async throws {
        try await expectColumnFieldLeavesScreenInPlace(inNavigationController: true)
    }

    /// Without a navigation controller the column lands inside the screen's
    /// own view, so "inside the screen" cannot tell the panel's field apart.
    @Test("a trailing column's field leaves a screen outside a navigation controller in place")
    func trailingColumnFieldLeavesAStandaloneScreenInPlace() async throws {
        try await expectColumnFieldLeavesScreenInPlace(inNavigationController: false)
    }

    /// A sheet over the chat is neither the column nor the screen's own view;
    /// its field must not switch off the chat's keyboard avoidance.
    @Test("a field in a sheet over the screen keeps the screen following the keyboard")
    func sheetFieldKeepsTheScreenFollowingTheKeyboard() async throws {
        let panelField = UITextField()
        let screen = ColumnScreen(panelField: panelField)
        let window = try showInWindow(RouterNavigationController(rootViewController: screen))
        defer { hide(window) }
        screen.showPanel(root: makeTestAppRoot())
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { panelField.window === window })
        let sheet = UIViewController()
        let sheetField = UITextField()
        sheet.view.addSubview(sheetField)
        screen.present(sheet, animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
            sheetField.window === window
        })

        beginEditing(sheetField)
        #expect(screen.followsKeyboard)
    }

    private func expectColumnFieldLeavesScreenInPlace(inNavigationController: Bool) async throws {
        let panelField = UITextField()
        let screen = ColumnScreen(panelField: panelField)
        let window = try showInWindow(
            inNavigationController ? RouterNavigationController(rootViewController: screen) : screen
        )
        defer { hide(window) }
        let screenField = UITextField()
        screen.view.addSubview(screenField)
        screen.showPanel(root: makeTestAppRoot())
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { panelField.window === window })

        beginEditing(panelField)
        #expect(!screen.followsKeyboard)
        beginEditing(screenField)
        #expect(screen.followsKeyboard)
        beginEditing(panelField)
        #expect(!screen.followsKeyboard)

        screen.hidePanel()
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { panelField.window == nil })
        #expect(screen.followsKeyboard)
    }
}

/// A shell stack's routes: a route update that arrives during a transition the
/// stack owns is left to that transition's `didShow`, and one that arrives during
/// a transition it does not own is applied when that transition ends.
@MainActor
@Suite("Shell stack routes")
struct ShellStackRoutesTests {
    /// This path runs on every push and pop, so the stack's own transition must
    /// keep applying nothing until `didShow`: an early apply would race the pop
    /// already in flight.
    @Test("a route update during the stack's own push waits for didShow and lands once")
    func ownPushDefersToDidShow() async throws {
        let stack = ShellNavigationController(root: makeTestAppRoot(), rootPlacement: .compactRoot)
        stack.setRoutes([.inbox])
        let inbox = try #require(stack.viewControllers.first)

        let window = try makeShellWindow(root: stack)
        defer { window.isHidden = true }
        stack.view.layoutIfNeeded()

        // An addition of the stack's own: the routes set its screens animated,
        // so a transition of this stack's is in flight.
        stack.setRoutes([.inbox, .sidebar])
        #expect(
            await waitForMainActorCondition(timeout: .seconds(3)) { stack.transitionCoordinator != nil },
            "the stack's own transition never started"
        )
        #expect(stack.viewControllers.count == 2)

        // The routes change back while that transition runs.
        stack.setRoutes([.inbox])
        #expect(stack.viewControllers.count == 2, "an own transition must not apply routes early")

        #expect(
            await waitForMainActorCondition(timeout: .seconds(5)) {
                stack.transitionCoordinator == nil && stack.viewControllers.count == 1
            },
            "the deferred routes never landed: \(stack.viewControllers.count) screens"
        )
        #expect(stack.viewControllers.first === inbox, "the inbox was replaced instead of kept")
    }

    /// `didShow` reports only a screen that was displayed, so a cancelled back
    /// swipe never sends it. This is the shape of that risk: after the stack's
    /// own transition, a transition it does not own must still apply its routes.
    /// A cancelled swipe cannot be driven deterministically — UIKit's is an
    /// internal edge-pan gesture — so the flag is also cleared by the
    /// transition's own completion, which fires whether it completes or cancels.
    @Test("an own transition does not stop a later transition from applying routes")
    func ownTransitionDoesNotStrandALaterTransition() async throws {
        let stack = ShellNavigationController(root: makeTestAppRoot(), rootPlacement: .compactRoot)
        stack.setRoutes([.inbox])

        let window = try makeShellWindow(root: stack)
        defer { window.isHidden = true }
        stack.view.layoutIfNeeded()

        // An own transition, run to completion first.
        stack.setRoutes([.inbox, .sidebar])
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            stack.transitionCoordinator == nil && stack.viewControllers.count == 2
        })
        stack.setRoutes([.inbox])
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            stack.transitionCoordinator == nil && stack.viewControllers.count == 1
        })

        // A modal closing over the stack: its dismissal is not this stack's
        // transition and never reports a `didShow` here.
        stack.present(UIViewController(), animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { stack.presentedViewController != nil })
        stack.dismiss(animated: true)
        #expect(
            await waitForMainActorCondition(timeout: .seconds(3)) { stack.transitionCoordinator != nil },
            "the dismissal transition never started"
        )
        stack.setRoutes([.inbox, .sidebar])

        #expect(
            await waitForMainActorCondition(timeout: .seconds(5)) { stack.viewControllers.count == 2 },
            "the routes set during a foreign transition were stranded: \(stack.viewControllers.count) screens"
        )
    }

    private func makeShellWindow(root: UIViewController) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the shell stack tests need the test host's window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }
}

/// What UIKit posts as `field` becomes first responder.
@MainActor
private func beginEditing(_ field: UITextField) {
    NotificationCenter.default.post(name: UITextField.textDidBeginEditingNotification, object: field)
}

// MARK: - Fixtures

/// A UIKit screen with a trailing column whose panel holds `panelField`,
/// mounted the way the chat mounts its column.
private final class ColumnScreen: UIViewController, TrailingColumnKeyboardScreen {
    var followsKeyboard = true
    private let panelField: UITextField
    private lazy var column = TrailingColumnController(screen: self)

    init(panelField: UITextField) {
        self.panelField = panelField
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(column)
        column.view.frame = .zero
        view.addSubview(column.view)
        column.didMove(toParent: self)
    }

    func showPanel(root: AppRootEnvironment) {
        let panelField = panelField
        column.show(
            TrailingColumnController.Panel(id: "panel", minWidth: 100, idealWidth: 150, makeScreen: {
                let panel = UIViewController()
                panel.view.addSubview(panelField)
                return panel
            }),
            root: root
        )
    }

    func hidePanel() {
        column.show(nil, root: nil)
    }
}

/// A UIKit screen with modal slots, as the chat and its composer have.
/// `upper` is released first: it closes while `lower` asks to close too.
@MainActor
private final class ModalOwnerScreen: UIViewController {
    let upper = RouterModalPresenter()
    let lower = RouterModalPresenter()

    override func viewDidLoad() {
        super.viewDidLoad()
        upper.anchor = self
        lower.anchor = self
    }
}

/// One router modal slot whose state a test sets, the way a screen sets its
/// own in `updateProperties()`.
@MainActor
private final class ModalSlotScreen: UIViewController {
    let slot = RouterModalPresenter()
    private let root = makeTestAppRoot()
    private(set) var dismissals = 0
    private(set) var clears = 0
    private(set) var presentedID: AnyHashable?

    override func viewDidLoad() {
        super.viewDidLoad()
        slot.anchor = self
    }

    /// The slot's new state: an `id` presents `presentation` around a fresh
    /// screen, nil dismisses.
    func show(
        _ id: AnyHashable?,
        _ presentation: ModalPresentation = .sheet,
        screen makeScreen: @escaping () -> UIViewController = { UIViewController() }
    ) {
        presentedID = id
        slot.update(
            id: id,
            presentation: presentation,
            root: root,
            onDismiss: { [weak self] in self?.dismissals += 1 },
            clear: { [weak self] in
                self?.clears += 1
                self?.presentedID = nil
            },
            screen: { .controller(makeScreen) }
        )
    }
}

// MARK: - Helpers

/// The workspace shell's UIKit stack under `controller`.
@MainActor
private func shellStack(in controller: UIViewController?) -> ShellNavigationController? {
    guard let controller else { return nil }
    if let stack = controller as? ShellNavigationController {
        return stack
    }
    return controller.children.lazy.compactMap(shellStack(in:)).first
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
