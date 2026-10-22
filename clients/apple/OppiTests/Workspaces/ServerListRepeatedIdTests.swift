import Foundation
import Testing
import UIKit
@testable import Oppi

/// A diffable snapshot traps (NSInternalInconsistencyException) on a repeated
/// item identifier, so a server response that repeats an id must not reach the
/// list as two rows. The screens show the first of a repeated id once, like
/// the session list.
///
/// The workspace sidebar and the schedule list are driven through the same
/// entry points the app uses (workspace store and `GET /schedules`). The
/// agent list, schedule detail, and session extension context lists dedupe
/// the same way inline, over the same snapshot type.
@Suite("Server list repeated ids")
@MainActor
struct ServerListRepeatedIdTests {
    @Test("Workspace sidebar shows one row for a workspace id the server repeats")
    func workspaceSidebarShowsRepeatedIdOnce() throws {
        let serverId = "sha256:repeat-ws-\(UUID().uuidString)"
        let client = APIClient(
            baseURL: try #require(URL(string: "http://127.0.0.1:1")),
            token: "sk_test",
            configuration: .ephemeral
        )
        let root = try makeTestAppRoot(readyServerId: serverId, apiClient: client)
        let store = try #require(root.coordinator.connection(for: serverId)).workspaceStore
        store.setActiveServer(serverId)
        store.workspacesByServer[serverId] = [
            makeTestWorkspace(id: "w1", name: "Alpha"),
            makeTestWorkspace(id: "w2", name: "Beta"),
            // Sorts after the first "w1" so the list order stays Alpha, Beta.
            makeTestWorkspace(id: "w1", name: "Zulu"),
        ]

        let controller = WorkspaceSidebarViewController(root: root)
        let window = try makeWindow(controller)
        defer { tearDown(window) }
        controller.view.layoutIfNeeded()

        let list = try #require(collectionView(in: controller.view, identifier: "workspace.sidebar.scroll"))
        list.layoutIfNeeded()
        #expect(rowIdentifiers(of: list) == ["workspace.open.Alpha", "workspace.open.Beta"])
    }

    @Test("Schedule list shows one row for a schedule id the server repeats")
    func scheduleListShowsRepeatedIdOnce() async throws {
        let serverId = "sha256:repeat-sch-\(UUID().uuidString)"
        let root = try makeTestAppRoot(readyServerId: serverId, apiClient: RepeatedScheduleURLProtocol.makeClient())

        let controller = ScheduleListViewController(root: root)
        let window = try makeWindow(controller)
        defer { tearDown(window) }

        let list = try #require(collectionView(in: controller.view, identifier: "schedules.list"))
        try await waitUntil { rowIdentifiers(of: list).count == 2 }
        #expect(rowIdentifiers(of: list) == ["schedules.row.sch-1", "schedules.row.sch-2"])
        // The first "sch-1" is the one shown.
        let firstRow = try #require(sidebarCells(of: list).first?.element)
        #expect(firstRow.accessibilityLabel?.hasPrefix("Daily QA,") == true)
    }

    // MARK: - Helpers

    private func makeWindow(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 2000)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    private func tearDown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func collectionView(in view: UIView, identifier: String) -> UICollectionView? {
        if let list = view as? UICollectionView, list.accessibilityIdentifier == identifier { return list }
        for subview in view.subviews {
            if let found = collectionView(in: subview, identifier: identifier) { return found }
        }
        return nil
    }

    /// The list's laid-out cells, top to bottom.
    private func sidebarCells(of list: UICollectionView) -> [SidebarListCell] {
        list.layoutIfNeeded()
        return list.indexPathsForVisibleItems.sorted().compactMap { list.cellForItem(at: $0) as? SidebarListCell }
    }

    /// Accessibility identifiers of the rows that name an item (the
    /// disclosure and other fixed rows are left out).
    private func rowIdentifiers(of list: UICollectionView) -> [String] {
        sidebarCells(of: list).compactMap(\.element.accessibilityIdentifier).filter {
            $0.hasPrefix("workspace.open.") || $0.hasPrefix("schedules.row.")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Condition was not met")
        throw CancellationError()
    }
}

/// `GET /schedules` answers with "sch-1" twice.
private final class RepeatedScheduleURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "repeated-schedules.test"

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RepeatedScheduleURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    private static func schedule(id: String, name: String) -> String {
        """
        {"id":"\(id)","name":"\(name)","status":"active","trigger":{"type":"cron","expression":"0 9 * * *","timeZone":"UTC"},"action":{"type":"new_session","workspaceId":"ws-1","promptChars":6},"createdAt":1000,"updatedAt":2000}
        """
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let schedules = [
            Self.schedule(id: "sch-1", name: "Daily QA"),
            Self.schedule(id: "sch-2", name: "Weekly"),
            Self.schedule(id: "sch-1", name: "Duplicate"),
        ]
        let body = Data(#"{"schedules":[\#(schedules.joined(separator: ","))]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
