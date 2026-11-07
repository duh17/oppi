import Foundation
import Testing
import UIKit
@testable import Oppi

/// Hosted in the chat's trailing column at regular width
/// (`WorkspaceContextBarView.Options.hostedInPanel`), a commit or a file
/// review pushes inside the panel's own navigation, with a back button to
/// the Git panel, instead of presenting a sheet over it. Compact width (the
/// default `Options`) keeps the sheet, covered by
/// `WorkspaceContextBarReviewCommentRoutingTests`.
@MainActor
@Suite("Git panel destinations push inside the trailing column")
struct GitPanelSidePanelRoutingTests {
    @Test func commitTapPushesIntoThePanelsOwnNavigation() async throws {
        let fixture = GitPanelPushFixture()
        defer { fixture.tearDown() }

        let commitRow = try #require(
            await waitForButton(labelContaining: "Seed commit", in: fixture),
            "the Git panel never listed the seeded commit"
        )
        commitRow.sendActions(for: .primaryActionTriggered)

        let pushed = await waitForMainActorCondition(timeout: .seconds(5)) {
            fixture.navigationController.topViewController is CommitDetailViewController
        }
        #expect(pushed, "the commit never pushed into the panel's own navigation")
        #expect(fixture.screen.presentedViewController == nil, "no sheet should present over the panel")
        #expect(
            fixture.navigationController.viewControllers.first === fixture.screen,
            "the panel must stay underneath, so Back returns to it"
        )

        // Back pops to the Git panel, the same as any other pushed screen's
        // native back button.
        fixture.navigationController.popViewController(animated: false)
        #expect(fixture.navigationController.topViewController === fixture.screen, "Back must return to the Git panel")
    }

    @Test func fileReviewTapPushesIntoThePanelsOwnNavigation() async throws {
        let fixture = GitPanelPushFixture()
        defer { fixture.tearDown() }

        let fileRow = try #require(
            await waitForButton(labelContaining: "App.swift", in: fixture),
            "the Git panel never listed the changed file"
        )
        fileRow.sendActions(for: .primaryActionTriggered)

        let pushed = await waitForMainActorCondition(timeout: .seconds(5)) {
            fixture.navigationController.topViewController is WorkspaceReviewFileDetailViewController
        }
        #expect(pushed, "the file review never pushed into the panel's own navigation")
        #expect(fixture.screen.presentedViewController == nil, "no sheet should present over the panel")

        fixture.navigationController.popViewController(animated: false)
        #expect(fixture.navigationController.topViewController === fixture.screen, "Back must return to the Git panel")
    }

    /// Settles the fixture's stubbed network first (the graph load always
    /// starts in `init`, whether or not this test's own row needs it), so a
    /// fast test never tears down its route scope while that fetch is still
    /// in flight and orphans its response; then polls for the row, which the
    /// settled update should already show.
    private func waitForButton(
        labelContaining text: String,
        in fixture: GitPanelPushFixture,
        timeout: Duration = .seconds(10)
    ) async -> UIButton? {
        _ = await fixture.routes.settle(timeout: timeout)
        var found: UIButton?
        _ = await waitForMainActorCondition(timeout: timeout) {
            fixture.bar.updatePropertiesIfNeeded()
            fixture.screen.view.layoutIfNeeded()
            found = fixture.button(labelContaining: text)
            return found != nil
        }
        return found
    }
}

/// A Git panel hosted in a trailing column's panel navigation
/// (`Options.hostedInPanel`), with its own stubbed server for the graph, a
/// commit's detail, and quick actions.
@MainActor
private final class GitPanelPushFixture {
    let screen = UIViewController()
    let navigationController: UINavigationController
    let bar: WorkspaceContextBarView
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 900))
    let routes: TestURLProtocol.RouteScope

    init() {
        routes = TestURLProtocol.routeScope { request in
            guard let path = request.url?.path else {
                throw TestURLProtocol.UnplannedRoute(route: "request with no path")
            }
            switch path {
            case "/workspaces/w1/git/graph":
                return try mockJSONResponse(encoding: CommitGraphResponse(
                    commits: [CommitGraphCommit(
                        sha: "abc1234567890",
                        shortSha: "abc1234",
                        parents: [],
                        message: "Seed commit",
                        date: "2026-08-03T00:00:00Z",
                        refs: []
                    )],
                    hasMore: false,
                    worktrees: []
                ), for: request)
            case "/workspaces/w1/git/commits/abc1234":
                return try mockJSONResponse(encoding: GitCommitDetail(
                    sha: "abc1234",
                    message: "Seed commit",
                    date: "2026-08-03T00:00:00Z",
                    author: "Test",
                    files: [],
                    addedLines: 0,
                    removedLines: 0
                ), for: request)
            case "/workspaces/w1/quick-actions":
                return try mockJSONResponse(encoding: WorkspaceQuickActionsResponse(actions: []), for: request)
            case "/workspaces/w1/git/diff":
                return try mockJSONResponse(encoding: WorkspaceReviewDiffResponse(
                    workspaceId: "w1",
                    path: "src/App.swift",
                    baselineText: "old\n",
                    currentText: "new\n",
                    addedLines: 2,
                    removedLines: 1,
                    hunks: [],
                    revisionCount: nil,
                    cacheKey: nil
                ), for: request)
            default:
                throw TestURLProtocol.UnplannedRoute(route: path)
            }
        }

        let connection = ServerConnection()
        connection.sessionStore.switchServer(to: "srv1")
        bar = WorkspaceContextBarView(
            context: .init(gitStatus: Self.makeGitStatus(), workspaceId: "w1"),
            options: .init(hostedInPanel: true),
            connection: connection,
            apiClient: makeTestURLProtocolClient(),
            navigation: AppNavigation()
        )
        bar.presenter = screen
        screen.traitOverrides.appRootEnvironment = makeTestAppRoot()
        bar.translatesAutoresizingMaskIntoConstraints = false
        screen.view.addSubview(bar)
        // As `GitPanelViewController` pins it: the required upper bound plus
        // a high-priority fill, so the table (and its commit rows) gets the
        // screen's real height instead of collapsing to its header's
        // minimum. (A closure literal here would trip Swift's definite-
        // initialization check inside this `init`.)
        let guide = screen.view.safeAreaLayoutGuide
        let bottomFill = bar.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        bottomFill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: guide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            bar.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor),
            bottomFill,
        ])
        // Pushed in a real navigation controller, as the trailing column's
        // panel root always is (`TrailingColumnController.installRequestedPanel`).
        navigationController = UINavigationController(rootViewController: screen)
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        bar.updatePropertiesIfNeeded()
        screen.view.layoutIfNeeded()
    }

    func button(labelContaining text: String) -> UIButton? {
        timelineAllViews(in: bar)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel?.contains(text) == true }
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        routes.end()
    }

    private static func makeGitStatus() -> GitStatus {
        GitStatus(
            isGitRepo: true,
            branch: "main",
            headSha: "abc1234",
            ahead: 0,
            behind: 0,
            dirtyCount: 1,
            untrackedCount: 0,
            stagedCount: 0,
            files: [GitFileStatus(status: " M", path: "src/App.swift", addedLines: 2, removedLines: 1)],
            totalFiles: 1,
            addedLines: 2,
            removedLines: 1,
            stashCount: 0,
            lastCommitMessage: "Seed commit",
            lastCommitDate: nil,
            recentCommits: [GitCommitSummary(sha: "abc1234", message: "Seed commit", date: "2026-08-03")]
        )
    }
}
