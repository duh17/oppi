import Testing
import UIKit
@testable import Oppi

/// A terminal inside a split pane, in a real window: it goes quiet while its
/// pane is hidden, and a terminal another pane already draws is focused there
/// rather than drawn a second time.
@MainActor
@Suite("Terminal panes", .serialized, .timeLimit(.minutes(1)))
struct TerminalPaneTests {
    private final class QuietConnection: SSHTerminalConnection {
        func close() {}
        func send(_ bytes: Data) async throws {}
        func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
        func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
            throw SSHConnectionError.notConnected
        }
        func run(_ command: String, input: Data) async throws -> SSHExecResult {
            throw SSHConnectionError.commandRequestRejected
        }
        func checkAlive() async throws {}
        func cancel() async {}
    }

    /// The mini in landscape with a split beside the routed pane: the split's id
    /// and its stack.
    private func splitHost() throws -> (host: PaneTestHost, split: PaneID, stack: UINavigationController) {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        let stack = try #require(host.panes.children.compactMap { $0 as? UINavigationController }.first {
            host.panes.cell(holding: $0.topViewController ?? $0) == split
        })
        // The grid paints only while the scene is active (`MountedTerminalTestController`).
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        return (host, split, stack)
    }

    /// The terminal's takes of `block` so far (`session.own_block`, take).
    private func takes(of block: String, in rig: RexSessionTerminalTests.Rig) -> Int {
        rig.fake.requests("session.own_block").filter {
            $0.payload.contains(block) && $0.payload.contains(#""mode":"take""#)
        }.count
    }

    /// Another pane's zoom parks the terminal's pane: its Rex session stops
    /// keeping neighbours live and leaves a pane the Mac app took to the Mac,
    /// and takes it back once the pane shows again.
    @Test func aHiddenPaneLeavesItsRexPaneToTheMacUntilItShowsAgain() async throws {
        let rig = try await RexSessionTerminalTests().open(["a", "b", "c"])
        let (host, split, stack) = try splitHost()
        defer {
            host.hide()
        }
        let terminal = SSHTerminalViewController(channel: rig.channel, reconnect: {}, editHost: {})
        host.act { stack.pushViewController(terminal, animated: false) }
        host.panes.updateVisibility()
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.isWarming },
                     "the shown pane keeps its neighbours live")
        let a = RexSessionTerminalTests.block("a")

        host.act { host.panes.zoom(host.scenePanes.mainLeafID) }
        #expect(host.panes.cellPresentation?.frames[split] == nil, "the zoom hides the terminal's pane")
        #expect(!rig.model.isWarming, "a hidden pane keeps no neighbours live")
        #expect(!rig.channel.isViewed, "nor takes the host's clipboard writes")
        let before = takes(of: a, in: rig)
        rig.fake.takeAsAnotherClient(a, columns: 120, rows: 40)
        _ = await waitForMainActorCondition(timeout: .milliseconds(400)) { false }
        #expect(takes(of: a, in: rig) == before, "the pane stays the Mac's while hidden")
        #expect(rig.fake.size(of: a) == RexFakeSession.Size(columns: 120, rows: 40))

        host.act { host.panes.zoom(nil) }
        #expect(rig.model.isWarming, "shown again, it keeps its neighbours live")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { takes(of: a, in: rig) > before },
                "and takes its pane back")
        await rig.stop()
    }

    /// Back from a folder terminal skips its connecting page. In the pane the
    /// chat's Terminal opened, it closes that pane and ends the terminal, so
    /// Terminal again dials a fresh one; pushed over the chat (a compact
    /// window), it returns to the chat and keeps the terminal to return to.
    @Test(arguments: [true, false])
    func backFromAFolderTerminal(inPane: Bool) async throws {
        let profile = SSHTerminalProfile(host: "mac-studio.invalid", username: "alex").normalized()
        let target = SSHTerminalFolderTarget(serverHost: profile.host, folder: "/Users/alex/oppi")
        let channel = try SSHTerminalChannel()
        channel.opened(QuietConnection())
        // Live already, so the folder screen shows it without dialing.
        SSHTerminalRegistry.shared.adopt(channel, profile: profile, folder: target.folder, queue: SSHTerminalEventQueue())
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer {
            host.hide()
            SSHTerminalRegistry.shared.close(channel, reason: "done")
        }
        host.scenePanes.preferences = try #require(UserDefaults(suiteName: "TerminalPaneTests-\(UUID().uuidString)"))
        let chat = try #require(host.screen.navigationController)
        let folder = SSHTerminalFolderViewController(profile: profile, target: target)
        if inPane {
            let content = PaneOpenContent(terminal: TerminalNavTarget { folder }, serverId: "s")
            var opened = false
            host.act {
                opened = host.openBeside(content, kind: .terminal, from: .row(host.scenePanes.mainLeafID))
            }
            try #require(opened, "the terminal opened in a pane beside the chat")
        } else {
            host.act { chat.pushViewController(folder, animated: false) }
        }
        try #require(await waitForMainActorCondition(timeout: .seconds(2)) {
            (folder.navigationController?.topViewController as? SSHTerminalViewController)?.channel === channel
        }, "the folder screen showed its terminal")
        let terminal = try #require(folder.navigationController?.topViewController)

        host.act { _ = terminal.accessibilityPerformEscape() }

        if inPane {
            #expect(host.scenePanes.splitLeaves.isEmpty, "Back closed the terminal's pane")
            #expect(!SSHTerminalRegistry.shared.holds(channel), "and ended its terminal")
            #expect(!channel.connected)
        } else {
            #expect(await waitForMainActorCondition(timeout: .seconds(2)) { chat.viewControllers == [host.screen] },
                    "Back returned to the chat past the connecting page: \(chat.viewControllers)")
            #expect(SSHTerminalRegistry.shared.holds(channel), "the terminal stays to return to")
            #expect(channel.connected)
        }
    }

    /// The chat bar's Terminal and a Rex link open through the screen-side
    /// wrapper (`PaneHostController.openBeside`), which builds the destination
    /// from what the opener made. That screen must survive: in a pane beside on
    /// a wide window, and in the main pane on a compact one, never a leaf state
    /// that only knows the entry's recipe.
    @Test(arguments: [false, true])
    func aTerminalItsScreenOpenedKeepsItsScreen(compact: Bool) async throws {
        let host = PaneTestHost(width: compact ? 402 : 1133, height: compact ? 874 : 744, inNavigation: true)
        defer { host.hide() }
        if compact {
            host.act {
                host.window.traitOverrides.horizontalSizeClass = .compact
                host.panes.updatePropertiesIfNeeded()
            }
        }
        let profile = SSHTerminalProfile(host: "mac-studio.invalid", username: "alex").normalized()
        let target = SSHTerminalFolderTarget(serverHost: profile.host, folder: "/Users/alex/routed")
        let screen = SSHTerminalFolderViewController(profile: profile, target: target)
        let terminal = TerminalNavTarget { screen }
        let content = PaneOpenContent(terminal: terminal, serverId: "s")
        let opener = host.screen

        host.act { PaneHostController.openBeside(content, kind: .terminal, from: opener) }

        let shown = host.scenePanes.stack(of: host.scenePanes.cellLayout.focus)?.top
            ?? host.root.navigation.mainPaneRoute.top
        #expect(shown == .terminal(terminal), "the opener's screen is the route, saw \(String(describing: shown))")
        if !compact {
            #expect(screen.view.window != nil, "the pane beside shows the opener's screen")
        }
        if compact {
            #expect(host.scenePanes.splitLeaves.isEmpty, "a compact window keeps one pane")
            #expect(host.root.navigation.mainPaneRoute.top == .terminal(terminal), "in the main pane")
        }
    }

    /// The window's shell on the iPad mini, in landscape until `rotate` turns it.
    @MainActor
    private final class ShellWindow {
        let root = makeTestAppRoot()
        let window: UIWindow
        let shell: WorkspaceShellController
        var navigation: SceneNavigation { root.navigation }

        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1133, height: 744)
            window.traitOverrides.horizontalSizeClass = .regular
            window.traitOverrides.verticalSizeClass = .regular
            shell = WorkspaceShellController(root: root)
            window.rootViewController = shell
            window.makeKeyAndVisible()
        }

        func hide() {
            window.isHidden = true
            window.rootViewController = nil
        }

        var stack: ShellNavigationController? { TerminalPaneTests.mainStack(in: shell) }
        var split: UISplitViewController? { TerminalPaneTests.first(UISplitViewController.self, in: shell) }

        func settles(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
            await waitForMainActorCondition(timeout: .seconds(3)) {
                self.shell.updatePropertiesIfNeeded()
                self.window.layoutIfNeeded()
                return self.stack?.transitionCoordinator == nil && condition()
            }
        }

        /// Turns the window to portrait (the stack shell) and back to landscape.
        func rotateAndBack() async -> Bool {
            window.frame = CGRect(x: 0, y: 0, width: 744, height: 1133)
            guard await settles({ self.navigation.workspaceNavigationPresentation == .stack }) else { return false }
            window.frame = CGRect(x: 0, y: 0, width: 1133, height: 744)
            return await settles { self.navigation.workspaceNavigationPresentation == .split }
        }
    }

    /// A terminal opened from the Terminal list in the main pane is a route of
    /// its stack: in landscape the sidebar hides for it as for a chat, a turn
    /// to portrait and back keeps the same live screen, and Back returns to
    /// the list past the connecting page with the shell kept to return to. A
    /// notification's chat replaces it as it replaces any page, and the shell
    /// lives on.
    @Test func aTerminalInTheMainPaneIsARouteOfItsStack() async throws {
        let profile = SSHTerminalProfile(host: "mac-studio.invalid", username: "alex").normalized()
        let target = SSHTerminalFolderTarget(serverHost: profile.host, folder: "/Users/alex/routed")
        let channel = try SSHTerminalChannel()
        channel.opened(QuietConnection())
        SSHTerminalRegistry.shared.adopt(channel, profile: profile, folder: target.folder, queue: SSHTerminalEventQueue())
        let shell = try ShellWindow()
        let navigation = shell.navigation
        defer {
            shell.hide()
            SSHTerminalRegistry.shared.close(channel, reason: "done")
        }

        navigation.open(.place(.utility(.sshTerminal)))
        #expect(await shell.settles { shell.stack?.topViewController is SSHTerminalHostListViewController })
        let list = try #require(shell.stack?.topViewController)
        #expect(shell.split?.displayMode == .oneBesideSecondary, "the sidebar shows beside the list")

        let folder = SSHTerminalFolderViewController(profile: profile, target: target)
        TerminalNavTarget { folder }.show(from: list)
        var terminal: SSHTerminalViewController?
        #expect(await shell.settles {
            terminal = shell.stack?.topViewController as? SSHTerminalViewController
            return terminal?.channel === channel
        }, "the folder screen showed its terminal")
        let shown = try #require(terminal)
        #expect(navigation.mainPaneRoute.stack.count == 2,
                "the connecting page and the terminal are routes: \(navigation.mainPaneRoute.stack)")
        #expect(await shell.settles { shell.split?.displayMode == .secondaryOnly }, "the terminal takes the full width")

        #expect(await shell.rotateAndBack())
        #expect(await shell.settles { shell.stack?.topViewController === shown && shell.split?.displayMode == .secondaryOnly },
                "the same terminal after a turn to portrait and back")
        #expect(channel.connected)

        _ = shown.accessibilityPerformEscape()
        #expect(await shell.settles { shell.stack?.topViewController === list },
                "Back returned to the list past the connecting page")
        #expect(navigation.mainPaneRoute.stack.isEmpty)
        #expect(await shell.settles { shell.split?.displayMode == .oneBesideSecondary }, "the sidebar is back beside the list")
        #expect(SSHTerminalRegistry.shared.holds(channel), "the terminal stays to return to")

        TerminalNavTarget { SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {}) }.show(from: list)
        #expect(await shell.settles { shell.stack?.topViewController is SSHTerminalViewController })
        let chat = WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "notified")
        navigation.open(.chat(chat), from: .external)
        #expect(navigation.mainPaneRoute.stack == [.session(chat)], "a notification's chat replaces the terminal")
        #expect(await shell.settles { !(shell.stack?.viewControllers.contains { $0 is SSHTerminalViewController } ?? true) })
        #expect(SSHTerminalRegistry.shared.holds(channel) && channel.connected, "the shell lives on")
    }

    /// A terminal opened from a page its list pushed (a host's form) sits over
    /// that page. A turn to portrait and back keeps the page under the
    /// terminal, and Back returns to it with its connect chrome still
    /// presenting: a host-key trust prompt opens over the page.
    @Test func aTurnKeepsThePageATerminalWasOpenedFromAndItsTrustPrompt() async throws {
        let registry = SSHTerminalRegistry(
            backgroundTasks: FakeBackgroundTasks(), sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        let profile = SSHTerminalProfile(host: "mac-studio.invalid", username: "alex", authentication: .deviceKey)
        let channel = try SSHTerminalChannel()
        channel.opened(QuietConnection())
        registry.adopt(channel, profile: profile, queue: SSHTerminalEventQueue())
        let shell = try ShellWindow()
        defer {
            shell.hide()
            registry.closeAll(reason: "done")
        }
        shell.navigation.open(.place(.utility(.sshTerminal)))
        #expect(await shell.settles { shell.stack?.topViewController is SSHTerminalHostListViewController })
        let list = try #require(shell.stack?.topViewController)
        let form = UIViewController()
        Router.push(form, from: list)
        #expect(await shell.settles { shell.stack?.topViewController === form })

        let session = SSHTerminalConnectSession(registry: registry)
        let chrome = SSHTerminalConnectChrome(
            host: form, session: session, profile: { profile }, setProfile: { _ in },
            editHost: {}, submitPassword: { _ in }, onSaved: { _ in }
        )
        session.show(try #require(registry.terminal(for: profile.id)))
        chrome.sync()
        #expect(await shell.settles { (shell.stack?.topViewController as? SSHTerminalViewController)?.channel === channel },
                "the form's connect opened the terminal")
        let terminal = try #require(shell.stack?.topViewController)
        #expect(await shell.settles { shell.split?.displayMode == .secondaryOnly }, "the terminal takes the full width")

        #expect(await shell.rotateAndBack())
        #expect(await shell.settles {
            guard let screens = shell.stack?.viewControllers, let at = screens.firstIndex(of: form) else { return false }
            return screens.last === terminal && at == screens.count - 2
        }, "the form stays under the terminal: \(shell.stack?.viewControllers ?? [])")

        _ = terminal.accessibilityPerformEscape()
        #expect(await shell.settles { shell.stack?.topViewController === form }, "Back returned to the form")
        session.showsTerminal = false
        chrome.sync()
        let key = SSHHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZbA0Hd5UkWHXHAQsrp7ZCdVjLOZsb9eJwvcdU6UT5q")
        session.hostFailure = .unknownHostKey(key)
        chrome.sync()
        #expect(await shell.settles {
            ((form.presentedViewController as? UINavigationController)?.viewControllers.first ?? form.presentedViewController)
                is SSHTerminalTrustViewController
        }, "the trust prompt opens over the form")
        session.hostFailure = nil
        chrome.sync()
    }

    /// The main pane's routed stack: the one inside the pane host, not the sidebar's.
    static func mainStack(in shell: UIViewController) -> ShellNavigationController? {
        first(PaneHostController.self, in: shell).flatMap { first(ShellNavigationController.self, in: $0) }
    }

    static func first<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let match = controller as? T { return match }
        return controller.children.lazy.compactMap { first(type, in: $0) }.first
    }

    /// A terminal one pane draws, opened from another pane's list, focuses the
    /// pane that draws it: one screen per shell. One no pane draws opens in
    /// the list's own pane.
    @Test func openingATerminalAnotherPaneDrawsFocusesThatPane() async throws {
        let registry = SSHTerminalRegistry(
            backgroundTasks: FakeBackgroundTasks(), sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        let profile = SSHTerminalProfile(host: "mac-studio", username: "alex")
        let channel = try SSHTerminalChannel()
        channel.opened(QuietConnection())
        registry.adopt(channel, profile: profile, queue: SSHTerminalEventQueue())
        let (host, split, stack) = try splitHost()
        defer {
            host.hide()
            registry.closeAll(reason: "done")
        }
        // The routed pane draws the terminal.
        let routedStack = try #require(host.screen.navigationController)
        host.act { routedStack.pushViewController(SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {}), animated: false) }
        let list = try #require(stack.topViewController)
        host.act { host.panes.focus(cell: split) }

        let session = SSHTerminalConnectSession(registry: registry)
        let chrome = SSHTerminalConnectChrome(
            host: list, session: session, profile: { profile }, setProfile: { _ in },
            editHost: {}, submitPassword: { _ in }, onSaved: { _ in }
        )
        session.show(try #require(registry.terminal(for: profile.id)))
        chrome.sync()
        _ = await waitForMainActorCondition(timeout: .milliseconds(200)) { false }
        host.window.layoutIfNeeded()
        #expect(host.panes.focusedLeaf == .primary, "the pane that draws the terminal takes focus")
        #expect(stack.topViewController === list, "no second terminal in the list's pane")
        #expect(!session.showsTerminal)

        // Once no pane draws it, the list's pane opens it.
        host.act { routedStack.popViewController(animated: false) }
        host.act { host.panes.focus(cell: split) }
        chrome.sync()
        session.show(try #require(registry.terminal(for: profile.id)))
        chrome.sync()
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            (stack.topViewController as? SSHTerminalViewController)?.channel === channel
        }, "the terminal opens in the list's pane")
    }
}
