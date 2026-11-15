import Foundation
import os
import Testing
import UIKit
@testable import Oppi

/// No app event announces a new workspace, so a pane naming one created
/// after the last catalog read reads the catalog again before it calls the
/// workspace missing, once per workspace.
@MainActor
@Suite("Pane entry naming an unknown workspace", .serialized)
struct PaneUnknownWorkspaceTests {
    @Test func aWorkspaceNewerThanTheCatalogOpensAndAGoneOneIsReadForOnce() async throws {
        let created = OSAllocatedUnfairLock(initialState: false)
        let catalogReads = OSAllocatedUnfairLock(initialState: 0)
        let scope = TestURLProtocol.routeScope { request in
            let url = try #require(request.url)
            let body: String
            switch url.path {
            case "/workspaces":
                catalogReads.withLock { $0 += 1 }
                var workspaces = [Self.workspaceJSON(id: "ws-1", name: "garden-site")]
                if created.withLock({ $0 }) { workspaces.append(Self.workspaceJSON(id: "ws-new", name: "field-notes")) }
                body = #"{"serverNow":1700000000000,"workspaces":[\#(workspaces.joined(separator: ","))],"summaries":[]}"#
            case "/skills":
                body = #"{"skills":[]}"#
            default:
                body = #"{"error":"Not found"}"#
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: body.hasPrefix(#"{"error""#) ? 404 : 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            return (Data(body.utf8), response)
        }
        defer { scope.end() }
        let serverId = "sha256:pane-unknown-workspace-\(UUID().uuidString)"
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: makeTestURLProtocolClient())
        let connection = try #require(root.coordinator.connection(for: serverId))
        await connection.refreshWorkspaceCatalog(force: true)
        try #require(connection.workspaceStore.lastSuccessfulSyncAt != nil)
        try #require(!connection.workspaceStore.workspaces.contains { $0.id == "ws-new" })

        // Another device creates the workspace after this one's last read.
        created.withLock { $0 = true }
        let readsBefore = catalogReads.withLock { $0 }
        var opened: WorkspaceStackRouteElement?
        let newer = try Self.show(PaneStackEntry(serverId: serverId, route: .files(workspace: "ws-new", path: nil)), root: root)
        defer { hideTestWindow(newer.window) }
        newer.screen.onOpen = { opened = $0 }
        newer.screen.updatePropertiesIfNeeded()
        #expect(newer.screen.shownState == .connecting, "not missing while the catalog is read again")
        let opens = await waitForMainActorCondition(timeout: .seconds(3)) {
            newer.screen.updatePropertiesIfNeeded()
            return opened != nil
        }
        #expect(opens, "the new workspace's Files open, saw \(String(describing: newer.screen.shownState))")
        if case .fileBrowser(let target)? = opened {
            #expect(target.workspaceId == "ws-new")
        } else {
            Issue.record("expected the File Browser, opened \(String(describing: opened))")
        }
        #expect(catalogReads.withLock { $0 } == readsBefore + 1)

        // A workspace that is really gone is read for once, then stays missing.
        let gone = PaneStackEntry(serverId: serverId, route: .sessions(workspace: "ws-gone"))
        let first = try Self.show(gone, root: root)
        defer { hideTestWindow(first.window) }
        let missing = await waitForMainActorCondition(timeout: .seconds(3)) {
            first.screen.updatePropertiesIfNeeded()
            return first.screen.shownState == .missing(.workspace)
        }
        #expect(missing, "saw \(String(describing: first.screen.shownState))")
        let second = try Self.show(gone, root: root)
        defer { hideTestWindow(second.window) }
        second.screen.updatePropertiesIfNeeded()
        #expect(second.screen.shownState == .missing(.workspace), "no second read for the same workspace")
        _ = await scope.settle()
        #expect(catalogReads.withLock { $0 } == readsBefore + 2, "one read for each unknown workspace")
    }

    private static func show(
        _ entry: PaneStackEntry, root: AppRootEnvironment
    ) throws -> (screen: PaneLeafStateViewController, window: UIWindow) {
        let screen = PaneLeafStateViewController(entry: entry, root: root)
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        return (screen, window)
    }

    nonisolated private static func workspaceJSON(id: String, name: String) -> String {
        #"{"id":"\#(id)","name":"\#(name)","skills":[],"systemPromptMode":"append","gitStatusEnabled":true,"createdAt":1700000000000,"updatedAt":1700000000000}"#
    }
}
