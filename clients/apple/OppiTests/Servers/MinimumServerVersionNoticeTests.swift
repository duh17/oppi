import Testing
import UIKit
@testable import Oppi

/// The session list's notice for a server below the app's floor: the app needs
/// `oppi-server` 0.55.0, so a 0.54 server is told to update.
@MainActor
@Suite("Minimum server version notice", .serialized)
struct MinimumServerVersionNoticeTests {
    private static let noticeId = "workspace.minimumServerVersion.notice"

    /// The session list over a server that reports `serverVersion`, laid out in a window.
    private func withSessionList(
        serverVersion: String,
        _ body: (SessionInboxViewController) async throws -> Void
    ) async throws {
        // The list's own reads answer as an unreachable server; the notice reads only the version.
        let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in throw URLError(.cannotConnectToHost) })
        defer { routes.end() }
        let serverId = "sha256:version-\(UUID().uuidString)"
        let root = try await makeTestAppRoot(
            readyServerId: serverId,
            apiClient: makeTestURLProtocolClient(host: "ready-server.test")
        )
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.noteServerVersionAfterUpdate(serverVersion)
        let list = SessionInboxViewController(root: root)
        let window = makeSceneWindow()
        defer { hideTestWindow(window) }
        window.rootViewController = UINavigationController(rootViewController: list)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await body(list)
    }

    @Test("A 0.54 server gets the older-server notice")
    func serverBelowTheFloorShowsTheNotice() async throws {
        try await withSessionList(serverVersion: "0.54.0") { list in
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) {
                Self.view(id: Self.noticeId, in: list.view) != nil
            })
        }
    }

    @Test("A 0.55 server gets no notice")
    func serverAtTheFloorShowsNoNotice() async throws {
        try await withSessionList(serverVersion: "0.55.0") { list in
            #expect(await waitForMainActorConditionToStayTrue(for: .seconds(1)) {
                Self.view(id: Self.noticeId, in: list.view) == nil
            })
        }
    }

    private static func view(id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        for subview in view.subviews {
            if let found = Self.view(id: id, in: subview) { return found }
        }
        return nil
    }
}
