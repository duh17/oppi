import Foundation
import Testing
import UIKit
@testable import Oppi

/// A File Browser in a compact split pane keeps its folders in that pane:
/// a folder opens as a page of the pane's own stack, and the breadcrumb goes
/// back through those pages, or moves the pane itself up when the browser
/// opened deeper than the folder asked for. The window's routes never move.
@Suite("File Browser breadcrumb in a split pane", .serialized)
@MainActor
struct FileBrowserPaneBreadcrumbTests {
    @Test func foldersAndTheBreadcrumbStayInTheSplitPane() async throws {
        let pane = try await Self.makePane(opening: "src/a/")
        defer { pane.end() }
        let leaf = try #require(pane.leafStack)
        let opened = try #require(leaf.viewControllers.first as? FileBrowserViewController)

        // A folder opens as the pane's next page.
        try await Self.openFolder("b", in: opened)
        let pushed = await waitForMainActorCondition(timeout: .seconds(3)) { leaf.viewControllers.count == 2 }
        #expect(pushed, "the folder is a page of the pane's stack")
        #expect(pane.root.navigation.workspaceStackRouteElements.isEmpty, "the window's routes stay")
        let deeper = try #require(leaf.topViewController as? FileBrowserViewController)

        // Its breadcrumb's "a" goes back to the page below.
        try await Self.tapBreadcrumb("a", in: deeper)
        let popped = await waitForMainActorCondition(timeout: .seconds(3)) {
            leaf.viewControllers.count == 1 && leaf.topViewController === opened
        }
        #expect(popped, "the breadcrumb pops the pane's own page")

        // "Files" is above the folder the pane opened at: the pane moves up.
        try await Self.tapBreadcrumb("Files", in: opened)
        let moved = await waitForMainActorCondition(timeout: .seconds(3)) {
            pane.scenePanes.topEntry(of: pane.leafID).route == .files(workspace: "ws-1", path: nil)
        }
        #expect(moved, "the pane shows the workspace's root, saw \(pane.scenePanes.topEntry(of: pane.leafID).route)")
        // The pane's one page is the workspace's root, not the folder the pane
        // was opened at: its bar names the root crumb.
        let showsRoot = await waitForMainActorCondition(timeout: .seconds(3)) {
            leaf.viewControllers.count == 1 && leaf.topViewController?.navigationItem.title == "Files"
        }
        #expect(showsRoot, "the pane shows the workspace's root, saw \(leaf.viewControllers.map { $0.navigationItem.title ?? "-" })")
        #expect(pane.root.navigation.workspaceStackRouteElements.isEmpty, "the window's routes stay")
        _ = await pane.scope.settle()
    }

    /// A file tapped in the compact pane opens where the pane owner puts it,
    /// beside that pane, and never on the window's main stack.
    @Test func aFileOpensBesideTheSplitPaneNotInTheMainPane() async throws {
        let pane = try await Self.makePane(opening: "src/a/")
        defer { pane.end() }
        let browser = try #require(pane.leafStack?.viewControllers.first as? FileBrowserViewController)

        try await Self.openFolder("notes.md", in: browser)
        let opened = await waitForMainActorCondition(timeout: .seconds(3)) {
            pane.scenePanes.cellLayout.leaves.contains(where: { (leaf: PaneLeaf) -> Bool in
                guard leaf.id != pane.leafID,
                      case .linkedFile(let file)? = pane.scenePanes.stack(of: leaf.id)?.top,
                      case .workspaceFile(let path, _) = file.kind else { return false }
                return path == "src/a/notes.md"
            })
        }
        #expect(opened, "the file opens in a pane of its own, saw \(pane.scenePanes.stacks)")
        #expect(pane.root.navigation.workspaceStackRouteElements.isEmpty, "the window's routes stay")
        #expect(pane.scenePanes.topEntry(of: pane.leafID).route == .files(workspace: "ws-1", path: "src/a/"), "the browser's pane keeps its folder")
        _ = await pane.scope.settle()
    }

    /// A side pane's breadcrumb targets its own pane and never falls through to
    /// the main pane's `showFileBrowserAncestor`, even when the side pane's
    /// route already matches the ancestor before the leaf stack redraws.
    @Test func aSidePaneBreadcrumbNeverChangesTheMainPaneWhenTheSideRouteAlreadyMatches() async throws {
        let pane = try await Self.makePane(opening: "src/a/")
        defer { pane.end() }
        let serverId = try #require(pane.root.coordinator.serverStore.servers.first?.id)
        let mainTarget = FileBrowserNavTarget(
            serverId: serverId,
            scope: .workspace(workspaceId: "ws-1", worktreeId: nil),
            path: "src/a/b/"
        )
        let rootTarget = FileBrowserNavTarget(
            serverId: serverId,
            scope: .workspace(workspaceId: "ws-1", worktreeId: nil),
            path: ""
        )
        pane.root.navigation.open(.page(.fileBrowser(mainTarget)))
        let opened = try #require(pane.leafStack?.viewControllers.first as? FileBrowserViewController)
        let filesCrumb = try await Self.breadcrumbButton("Files", in: opened)

        // The side leaf's route moves to the root before its stack redraws, so
        // `showInSplitPane` sees the top already matches and does nothing.
        pane.scenePanes.show(.fileBrowser(rootTarget), in: pane.leafID)
        filesCrumb.sendActions(for: .primaryActionTriggered)

        #expect(pane.root.navigation.workspaceStackRouteElements == [.fileBrowser(mainTarget)],
                "the side pane's breadcrumb must leave the main pane's route alone")
        _ = await pane.scope.settle()
    }

    // MARK: Fixture

    @MainActor
    struct Pane {
        let root: AppRootEnvironment
        let host: PaneHostController
        let scenePanes: ScenePanes
        let leafID: PaneID
        let window: UIWindow
        let scope: TestURLProtocol.RouteScope

        var leafStack: UINavigationController? {
            host.children.first { $0.view.accessibilityIdentifier == "pane.leaf.\(leafID.raw)" } as? UINavigationController
        }

        func end() {
            hideTestWindow(window)
            window.rootViewController = nil
            scope.end()
        }
    }

    /// An iPad mini landscape window split side by side, its right pane a
    /// compact File Browser of workspace `ws-1` at `path`.
    private static func makePane(opening path: String) async throws -> Pane {
        let scope = TestURLProtocol.routeScope(Self.listing(for:))
        let serverId = "sha256:pane-files-\(UUID().uuidString)"
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: makeTestURLProtocolClient())
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.workspaceStore.upsert(makeTestWorkspace(id: "ws-1", name: "garden-site"), serverId: serverId)

        // The window's panes, and the window's pane area, as the shell wires them.
        let scenePanes = root.navigation.panes
        let host = PaneHostController(primary: UINavigationController(rootViewController: UIViewController()), panes: scenePanes)
        root.navigation.paneArea = host
        // A window in the test host's scene, so a push animates to its end.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1133, height: 744)
        window.traitOverrides.horizontalSizeClass = .regular
        window.traitOverrides.appRootEnvironment = root
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        UIView.performWithoutAnimation { host.split(axis: .row) }
        let leafID = try #require(scenePanes.splitLeaves.first?.id)
        scenePanes.show(PaneStackEntry(serverId: serverId, route: .files(workspace: "ws-1", path: path)), in: leafID)
        let pane = Pane(root: root, host: host, scenePanes: scenePanes, leafID: leafID, window: window, scope: scope)
        let mounted = await waitForMainActorCondition(timeout: .seconds(3)) {
            window.layoutIfNeeded()
            return pane.leafStack?.viewControllers.first is FileBrowserViewController
        }
        try #require(mounted, "the pane mounts the File Browser")
        let compact = try #require(pane.leafStack).traitCollection.horizontalSizeClass == .compact
        try #require(compact, "the pane lays out compact, where folders open as pages")
        return pane
    }

    private static func openFolder(_ name: String, in browser: FileBrowserViewController) async throws {
        var found: (UICollectionView, IndexPath)?
        _ = await waitForMainActorCondition(timeout: .seconds(3)) {
            browser.view.window?.layoutIfNeeded()
            found = list(in: browser.view).flatMap { list in indexPath(ofRowNamed: name, in: list).map { (list, $0) } }
            return found != nil
        }
        let (list, indexPath) = try #require(found, "folder row \(name) never showed")
        list.delegate?.collectionView?(list, didSelectItemAt: indexPath)
    }

    private static func tapBreadcrumb(_ label: String, in browser: FileBrowserViewController) async throws {
        try await breadcrumbButton(label, in: browser).sendActions(for: .primaryActionTriggered)
    }

    private static func breadcrumbButton(_ label: String, in browser: FileBrowserViewController) async throws -> UIButton {
        var button: UIButton?
        _ = await waitForMainActorCondition(timeout: .seconds(3)) {
            browser.view.window?.layoutIfNeeded()
            button = descendants(of: browser.view).compactMap { $0 as? FileBrowserBreadcrumbCell }.first
                .flatMap { cell in
                    descendants(of: cell).compactMap { $0 as? UIButton }
                        .first { $0.configuration?.attributedTitle.map { String($0.characters) } == label }
                }
            return button != nil
        }
        let seen = descendants(of: browser.view).compactMap { ($0 as? UIButton)?.configuration?.attributedTitle.map { String($0.characters) } }
        let crumbs = descendants(of: browser.view).filter { $0 is FileBrowserBreadcrumbCell }.count
        return try #require(
            button,
            "breadcrumb \(label) never showed; title \(browser.navigationItem.title ?? "nil"), window \(browser.view.window != nil), crumbs \(crumbs), buttons \(seen)"
        )
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private static func list(in view: UIView) -> UICollectionView? {
        descendants(of: view).lazy.compactMap { $0 as? UICollectionView }.first { $0.delegate is FileBrowserViewController }
    }

    private static func indexPath(ofRowNamed name: String, in list: UICollectionView) -> IndexPath? {
        for section in 0..<list.numberOfSections {
            for item in 0..<list.numberOfItems(inSection: section) {
                let indexPath = IndexPath(item: item, section: section)
                let cell = list.cellForItem(at: indexPath) as? UICollectionViewListCell
                if (cell?.contentConfiguration as? UIListContentConfiguration)?.text == name { return indexPath }
            }
        }
        return nil
    }

    /// `src/a/` holds `b/`; every folder lists one file so it is not empty.
    /// Anything else the browser asks for is not there.
    nonisolated private static func listing(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let prefix = "/workspaces/ws-1/contents/"
        let path = url.path(percentEncoded: false)
        let body: String
        let status: Int
        if path.hasPrefix(prefix) || path == String(prefix.dropLast()) {
            let folder = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
            var entries = [#"{"name":"notes.md","type":"file","size":3,"modifiedAt":0,"path":"\#(folder)notes.md"}"#]
            if folder == "src/a/" {
                entries.append(#"{"name":"b","type":"directory","size":0,"modifiedAt":0,"path":"src/a/b/"}"#)
            }
            body = #"{"path":"\#(folder)","entries":[\#(entries.joined(separator: ","))],"truncated":false}"#
            status = 200
        } else {
            body = #"{"error":"Not found"}"#
            status = 404
        }
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(body.utf8), response)
    }
}
