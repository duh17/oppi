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
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
        defer { routes.end() }
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
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
        defer { routes.end() }
        let root = try makeTestTwoServerRoot(firstId: serverId, otherId: "skills-list-other")
        let coordinator = root.coordinator
        let servers = coordinator.serverStore.servers
        let first = try #require(servers.first)
        let other = try #require(servers.dropFirst().first)
        let firstConnection = try #require(coordinator.connection(for: first.id))
        let otherConnection = try #require(coordinator.connection(for: other.id))

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
        // The refresh the list starts loads both catalogs, and ends with this test.
        #expect(await routes.settle(), "a request outlived the test that answered it")
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

    @Test("A Skill the server could not classify says so in Validation, not as a failed load")
    func unknownStateSkillIsAValidationFact() throws {
        let root = try makeRoot()
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.serverResourceStore.replaceSkills([skill(state: .unknown)], serverId: serverId)

        // No window, so the page never loads: only the catalog row's own state
        // decides what the page says.
        let screen = ServerSkillDetailViewController(
            target: ServerResourceDetailNavTarget(serverId: serverId, kind: .skill, resourceId: "release"),
            root: root,
            connection: connection
        )
        screen.loadViewIfNeeded()
        screen.updateProperties()
        #expect(!screen.shownItems.isEmpty, "the catalog row fills the page without a load")

        // Nothing failed to load, so there is no failed row to retry: what Pi made
        // of the Skill is a fact about it, in Validation.
        #expect(screen.sections().first { $0.id == .loading }?.state == nil,
                "an unknown Skill is not a failed request")
        let validation = try #require(screen.sections().first { $0.id == .validation })
        let reason = validation.items.compactMap { item -> String? in
            if case .loadError(let reason) = item { return reason }
            return nil
        }.first
        #expect(reason == String(localized: "Pi could not read this Skill."))
    }

    @Test("Retry on an unavailable Skills catalog says why, sends one new request, and loads the list")
    func retryReloadsAnUnavailableCatalog() async throws {
        // A fresh server id: the shared cache holds no catalog for it.
        let retryServerId = UUID().uuidString
        let catalog = MissingRouteThenAvailable(
            availableJSON: try String(
                decoding: JSONEncoder().encode(ServerSkillsCatalog(skills: [skill()])), as: UTF8.self
            )
        )
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard request.url?.path.hasSuffix("/server/resources/skills") == true else { return nil }
            return try catalog.answer(for: request)
        })
        defer { routes.end() }
        let root = try makeTestAppRoot(
            readyServerId: retryServerId,
            apiClient: makeTestURLProtocolClient(host: "ready-server.test")
        )
        let screen = ServerSkillsViewController(root: root)
        let window = try show(UINavigationController(rootViewController: screen))
        defer { hide(window) }

        // The failed row, not the loading row that shares its identifier.
        func failedRow() -> ListStateRow? {
            guard case .failed = screen.sections().first(where: { $0.id == .status })?.state?.state else { return nil }
            return screen.sections().first(where: { $0.id == .status })?.state
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(10)) { failedRow() != nil })
        let row = try #require(failedRow())
        guard case .failed(let title, let reason, let retryAction) = row.state else {
            Issue.record("the row is not a failure: \(row.state.rowText)")
            return
        }
        #expect(title == "Couldn't Load Skills")
        #expect(reason == String(localized: "The selected server has no cached Skills catalog."))
        #expect(retryAction != nil, "the row offers the page's Retry")
        #expect(row.identifier == "skills.state")
        #expect(Self.button(withIdentifier: "skills.row.release", in: screen.view) == nil)

        // The server comes back, but nothing reloads by itself.
        let settled = catalog.requests
        catalog.makeAvailable()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            failedRow() != nil && catalog.requests == settled
        })

        let button = try #require(Self.button(withIdentifier: "skills.state", in: screen.view))
        button.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: "skills.row.release", in: screen.view) != nil
        })
        #expect(catalog.requests == settled + 1)
        await TimelineCache.shared.removeServer(retryServerId)
    }

    /// An opened folder stays open when the Skill's detail is read again — the
    /// files are the same — and closing it takes its own nested folder's files
    /// with it.
    @Test("an opened folder stays open when the detail reloads with the same files")
    func openFolderSurvivesADetailReload() async throws {
        let detail = ServerSkillDetail(
            summary: skill(),
            skillMarkdown: "# release",
            files: ["SKILL.md", "references/review.md", "references/nested/checklist.md"]
        )
        let reads = SkillReadCounter()
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard request.url?.path.hasSuffix("/server/resources/skills/release") == true else { return nil }
            reads.record()
            return try mockJSONResponse(
                json: String(decoding: JSONEncoder().encode(detail), as: UTF8.self),
                for: request
            )
        })
        defer { routes.end() }
        let root = try makeRoot()
        let connection = try #require(root.coordinator.connection(for: serverId))
        // The Skill's page read the detail just before it opened the tree.
        connection.serverResourceStore.rememberSkillDetail(detail, serverId: serverId)

        let screen = ServerSkillBrowserViewController(
            target: ServerSkillBrowserNavTarget(serverId: serverId, resourceId: "release"),
            root: root,
            connection: connection
        )
        let window = try show(UINavigationController(rootViewController: screen))
        defer { hide(window) }

        /// The row the list shows now, by its identifier: the cells it holds,
        /// never one it has removed from its snapshot.
        func row(_ identifier: String) -> UIButton? {
            screen.view.layoutIfNeeded()
            for cell in screen.collectionView.visibleCells {
                if let button = Self.button(withIdentifier: identifier, in: cell) { return button }
            }
            return nil
        }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { row("skills.dir.references") != nil },
                "the tree did not show the store's detail")
        // The page appeared before anything is asked of it: its own load starts on
        // the way in, and one asked for later replaces it.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { screen.isShowing },
                "the page never appeared")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !screen.isLoading },
                "the page's first load never settled")
        #expect(reads.reads == 0, "the store had the detail: opening the tree asked for nothing")

        // Open a folder, then the folder inside it.
        try #require(row("skills.dir.references")).sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            row("skills.file.references/review.md") != nil
        }, "opening a folder did not list its files")
        #expect(row("skills.dir.references")?.accessibilityValue == "Expanded")
        try #require(row("skills.dir.references/nested")).sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            row("skills.file.references/nested/checklist.md") != nil
        }, "opening the nested folder did not list its file")

        // The detail is read again, with the same files: what was open stays open.
        // The two inserts settle first, each its own animated snapshot pass.
        try await Task.sleep(for: .milliseconds(300))
        screen.setNeedsLoad()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { reads.reads == 1 }, """
            the reload did not ask the server: reads \(reads.reads), loading \(screen.isLoading), \
            failure \(String(describing: screen.loadFailure)), rows \(screen.shownItems.map(\.nodeId))
            """)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            row("skills.dir.references")?.accessibilityValue == "Expanded"
                && row("skills.dir.references/nested")?.accessibilityValue == "Expanded"
                && row("skills.file.references/nested/checklist.md") != nil
        }, "a reload of the same files closed the folders: rows \(screen.shownItems.map(\.nodeId))")

        // Closing the outer folder takes the nested folder's files with it.
        try await Task.sleep(for: .milliseconds(300))
        try #require(row("skills.dir.references")).sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            row("skills.dir.references")?.accessibilityValue == "Collapsed"
                && row("skills.dir.references/nested") == nil
                && row("skills.file.references/nested/checklist.md") == nil
                && screen.shownItems.map(\.nodeId) == ["directory:references", "file:SKILL.md"]
        }, """
           closing a folder left its nested files listed: references \
           \(String(describing: row("skills.dir.references")?.accessibilityValue)), rows \(screen.shownItems.map(\.nodeId))
           """)
    }

    private func makeRoot() throws -> AppRootEnvironment {
        try makeTestAppRoot(
            readyServerId: serverId,
            apiClient: makeTestURLProtocolClient(host: "ready-server.test")
        )
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

/// How many skill-detail reads a test's route answered.
private final class SkillReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var reads: Int { lock.withLock { count } }

    func record() { lock.withLock { count += 1 } }
}
