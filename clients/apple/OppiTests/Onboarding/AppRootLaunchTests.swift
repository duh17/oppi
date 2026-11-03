import Foundation
import Testing
import UIKit
@testable import Oppi

/// The window root's launch content: which screen `AppRootViewController`
/// installs for the launch phase, and what it comes back to after a
/// window-covering modal closes.
@MainActor
@Suite("App root launch", .serialized)
struct AppRootLaunchTests {
    /// The control for the test below: the same launch with no What's New over
    /// it. A red control means the empty stack is the test host's, not the app's.
    @Test("the shell the launch resolved to mounts its session list with no cover")
    func launchWithoutWhatsNewMountsTheInbox() async throws {
        let (root, app, window, expectsSplit) = try showRoot()
        defer { hide(window) }

        app.root.navigation.revealPairedServerShell()
        #expect(
            await waitForMainActorCondition(timeout: .seconds(5)) { root.children.contains { $0 is WorkspaceShellController } },
            "no shell under the root: \(childKinds(of: root))"
        )
        let shell = try #require(root.children.first { $0 is WorkspaceShellController })
        expectLayout(of: shell, expectsSplit: expectsSplit)
        #expect(
            await waitForMainActorCondition(timeout: .seconds(5)) { descendants(of: shell).contains { $0 is SessionInboxViewController } },
            "the shell mounted no session list: \(descendantKinds(of: shell))"
        )
    }

    /// The bootstrap asks for What's New before it reveals the shell, so the
    /// cover is up while the launch resolves.
    @Test("the shell the launch resolved to shows once What's New is dismissed")
    func whatsNewDismissalRevealsTheShell() async throws {
        let (root, app, window, expectsSplit) = try showRoot()
        defer { hide(window) }
        #expect(
            root.children.contains { $0 is LaunchBackdropViewController },
            "the launch phase did not start on the backdrop: \(childKinds(of: root))"
        )

        app.root.navigation.showWhatsNew = true
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { isSettled(root.presentedViewController) })
        let whatsNew = try #require(root.presentedViewController as? WhatsNewViewController)

        // The launch resolves behind the cover.
        app.root.navigation.revealPairedServerShell()

        // What's New's Done button.
        Router.finish(whatsNew)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { root.presentedViewController == nil })
        #expect(
            await waitForMainActorCondition(timeout: .seconds(5)) { root.children.contains { $0 is WorkspaceShellController } },
            "the root came back showing \(childKinds(of: root))"
        )
        let shell = try #require(root.children.first { $0 is WorkspaceShellController })
        expectLayout(of: shell, expectsSplit: expectsSplit)
        #expect(
            await waitForMainActorCondition(timeout: .seconds(5)) { descendants(of: shell).contains { $0 is SessionInboxViewController } },
            "the shell mounted no session list: \(descendantKinds(of: shell))"
        )
    }

    // MARK: Fixtures

    /// Which layout the window's size and traits ask for, so the profile in use
    /// decides: the iPad profile covers the split's detail stack, which sets its
    /// routes the same way the drawer's stack does.
    private func expectLayout(of shell: UIViewController, expectsSplit: Bool) {
        let mounted = descendants(of: shell).contains { expectsSplit ? $0 is WorkspaceSplitController : $0 is WorkspaceDrawerController }
        #expect(mounted, "the shell mounted no \(expectsSplit ? "split" : "drawer") layout: \(descendantKinds(of: shell))")
    }

    /// A paired launch that has not resolved yet, in a window, as
    /// `OppiApp.startApp()` leaves it before `revealPairedServerShell()`.
    private func showRoot() throws -> (root: AppRootViewController, app: OppiApp, window: UIWindow, expectsSplit: Bool) {
        let app = OppiApp()
        let server = try #require(PairedServer(from: ServerCredentials(
            host: "launch.root.test",
            port: 7749,
            token: "sk_test",
            name: "Launch",
            scheme: .https,
            serverFingerprint: "sha256:root-launch",
            tlsCertFingerprint: "sha256:root-launch-leaf"
        )))
        app.root.coordinator.serverStore.replaceServersForPreview([server])
        app.root.coordinator.activatePairedServerShell(server)

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the launch tests need the test host's window scene"
        )
        let window = UIWindow(windowScene: scene)
        // Regular width and height resolves the split layout, which sets its
        // detail stack's routes the same way the drawer does; the iPad profile
        // covers that path with this same test.
        let traits = window.traitCollection
        let regular = traits.horizontalSizeClass == .regular && traits.verticalSizeClass == .regular
        window.frame = CGRect(origin: .zero, size: regular ? CGSize(width: 1024, height: 768) : CGSize(width: 390, height: 844))
        let root = AppRootViewController(app: app)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
        let expectsSplit = WorkspaceNavigationPresentation.resolve(
            horizontalSizeClass: traits.horizontalSizeClass,
            verticalSizeClass: traits.verticalSizeClass,
            size: window.frame.size
        ) == .split
        return (root, app, window, expectsSplit)
    }

    /// The classes of the children the root installed.
    private func childKinds(of root: UIViewController) -> String {
        root.children.isEmpty ? "nothing" : root.children.map { String(describing: type(of: $0)) }.joined(separator: ", ")
    }

    private func descendantKinds(of root: UIViewController) -> String {
        descendants(of: root).map { String(describing: type(of: $0)) }.joined(separator: ", ")
    }

    /// `parent` and every view controller under it, including the screens of
    /// the navigation stacks it mounts.
    private func descendants(of parent: UIViewController) -> [UIViewController] {
        let stacks = (parent as? UINavigationController)?.viewControllers ?? []
        return stacks + parent.children + parent.children.flatMap(descendants)
    }

    private func hide(_ window: UIWindow) {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }

    private func isSettled(_ presented: UIViewController?) -> Bool {
        guard let presented else { return false }
        return !presented.isBeingPresented && presented.viewIfLoaded?.window != nil
    }
}
