import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Skills screens")
struct ServerSkillsViewControllerTests {
    private let serverId = "skills-list-server"

    private func skill(state: ServerSkillState = .enabled) -> ServerSkillSummary {
        ServerSkillSummary(
            id: "release", name: "release", description: "Review release readiness.",
            provenance: .init(kind: .piAgent, label: "~/.pi/agent/skills"), path: nil,
            state: state, loadError: nil, warnings: [], editable: false
        )
    }

    @Test("a row is one button that opens its detail through AppNavigation")
    func rowOpensDetailRoute() async throws {
        let root = try makeRoot()
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.serverResourceStore.replaceSkills([skill()], serverId: serverId)

        let screen = ServerSkillsViewController(root: root)
        let window = try show(UINavigationController(rootViewController: screen))
        defer { hide(window) }

        var row: UIButton?
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            row = Self.button(withIdentifier: "skills.row.release", in: screen.view)
            return row != nil
        })
        let button = try #require(row)
        #expect(button.accessibilityLabel == "release, ~/.pi/agent/skills, Enabled")
        #expect(button.accessibilityTraits.contains(.button))

        button.sendActions(for: .touchUpInside)
        #expect(root.navigation.workspaceStackRouteElements == [
            .serverResourceDetail(ServerResourceDetailNavTarget(serverId: serverId, kind: .skill, resourceId: "release")),
        ])
    }

    @Test("the screen follows the active server and loads its catalog only while it is showing")
    func reloadsWhenActiveServerChanges() async throws {
        let root = try makeRoot()
        let coordinator = root.coordinator
        let first = try #require(coordinator.serverStore.servers.first)
        let other = try #require(PairedServer(
            from: ServerCredentials(
                host: "other-server.test", port: 7749, token: "sk_test", name: "Other", scheme: .https,
                serverFingerprint: "skills-list-other"
            ),
            sortOrder: 1
        ))
        coordinator.serverStore.replaceServersForPreview([first, other])
        let firstConnection = try #require(coordinator.connection(for: first.id))
        let otherConnection = coordinator.ensureConnection(for: other)
        otherConnection.setAPIClientForTesting(try makeClient())

        // A store starts on its own server; a marker shows that the screen's load
        // is what moves it to the active server.
        firstConnection.serverResourceStore.switchServer(to: "marker")

        let screen = ServerSkillsViewController(root: root)
        let navigation = UINavigationController(rootViewController: screen)
        let window = try show(navigation)
        defer { hide(window) }

        // With several servers the row is the switcher menu; it shows the active one.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: "serverCatalog.server.menu", in: screen.view)?
                .accessibilityLabel == "Current server: Ready"
        })
        // Showing the screen loads the active server's catalog.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            firstConnection.serverResourceStore.activeServerId == first.id
        })

        // Another server becomes active (the pill, a link): its catalog loads.
        otherConnection.serverResourceStore.switchServer(to: "marker")
        #expect(coordinator.restoreActiveServer(other.id))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            otherConnection.serverResourceStore.activeServerId == other.id
        })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: "serverCatalog.server.menu", in: screen.view)?
                .accessibilityLabel == "Current server: Other"
        })

        // A page above the list: a switch meanwhile loads nothing until it returns.
        Router.push(UIViewController(), from: screen)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            navigation.transitionCoordinator == nil && navigation.topViewController !== screen
        })
        firstConnection.serverResourceStore.switchServer(to: "marker")
        #expect(coordinator.restoreActiveServer(first.id))
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(500)) {
            firstConnection.serverResourceStore.activeServerId == "marker"
        }, "a covered list must not load")

        navigation.popViewController(animated: false)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            firstConnection.serverResourceStore.activeServerId == first.id
        }, "the list loads the active server when it shows again")
    }

    @Test("the Enabled switch snaps back and saves nothing while the server is offline")
    func offlineSwitchSnapsBack() async throws {
        let root = try makeRoot()
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.serverResourceStore.replaceSkills([skill()], serverId: serverId)
        connection.setAPIClientForTesting(nil)

        let screen = ServerSkillDetailViewController(
            target: ServerResourceDetailNavTarget(serverId: serverId, kind: .skill, resourceId: "release"),
            root: root,
            connection: connection
        )
        let window = try show(UINavigationController(rootViewController: screen))
        defer { hide(window) }

        var found: UISwitch?
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            found = Self.switchControl(withIdentifier: "skills.detail.enabled", in: screen.view)
            return found != nil
        })
        let toggle = try #require(found)
        #expect(toggle.isOn)
        #expect(toggle.isEnabled, "a loaded catalog allows the change")

        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)
        #expect(toggle.isOn, "with no client the switch returns to the server's value")
        let store = connection.serverResourceStore
        #expect(!store.isMutationPending(.skill("release"), serverId: serverId))
        #expect(store.mutationError(for: .skill("release"), serverId: serverId) == nil)
        #expect(store.skills(forServer: serverId).first?.state == .enabled)
    }

    private func makeClient() throws -> APIClient {
        APIClient(
            baseURL: try #require(URL(string: "https://ready-server.test:7749")),
            token: "sk_test"
        )
    }

    private func makeRoot() throws -> AppRootEnvironment {
        try makeTestAppRoot(readyServerId: serverId, apiClient: makeClient())
    }

    private func show(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    private func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func button(withIdentifier identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        for subview in view.subviews {
            if let found = button(withIdentifier: identifier, in: subview) { return found }
        }
        return nil
    }

    private static func switchControl(withIdentifier identifier: String, in view: UIView) -> UISwitch? {
        if let control = view as? UISwitch, control.accessibilityIdentifier == identifier { return control }
        for subview in view.subviews {
            if let found = switchControl(withIdentifier: identifier, in: subview) { return found }
        }
        return nil
    }
}
