import Testing
import UIKit
@testable import Oppi

/// The Schedules list: what it shows of its own state, and that a failed change
/// to one schedule never stands in for the list.
@Suite("Schedules list")
@MainActor
struct ScheduleListPageTests {
    private let serverId = "schedules-list-server"

    private func schedule(_ id: String, status: AgentScheduleStatus = .active) -> AgentScheduleSummary {
        AgentScheduleSummary(
            id: id,
            name: "Nightly digest",
            status: status,
            trigger: .every(intervalMs: 3_600_000, timeZone: "America/Los_Angeles"),
            action: AgentScheduleActionSummary(
                type: .newSession, workspaceId: "ws", sessionId: nil, agentId: nil, promptChars: 12
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            archivedAt: nil
        )
    }

    private func makeRoot() throws -> AppRootEnvironment {
        try makeTestAppRoot(
            readyServerId: serverId,
            apiClient: makeTestURLProtocolClient(host: "ready-server.test")
        )
    }

    @Test("a failed pause keeps the list on screen and is not the list's own failure")
    func failedActionKeepsTheList() async throws {
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard request.url?.path.hasSuffix("/schedules") == true else {
                guard request.url?.path.contains("/pause") == true else { return nil }
                // The pause is refused: a 500 of its own, not the list's route.
                return (Data(#"{"error":"nope"}"#.utf8), Self.status(500, for: request))
            }
            return (try JSONEncoder().encode(SchedulesBody(schedules: [schedule("nightly")])), Self.status(200, for: request))
        })
        defer { routes.end() }
        let root = try makeRoot()
        let screen = ScheduleListViewController(root: root)
        let window = try show(screen)
        defer { window.isHidden = true; window.rootViewController = nil }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.shownScheduleIDs == ["nightly"]
        }, "the list loads its schedules")

        // The pause is refused: the list keeps the schedule it shows and says
        // what failed where an action says it, never as the list's own failure.
        screen.mutate(schedule("nightly"), .pause)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.actionError != nil
        }, "a failed pause says why")
        #expect(screen.shownScheduleIDs == ["nightly"], "the failed pause keeps the list")
        #expect(screen.loadError == nil, "an action's failure is not the list's")
    }

    @Test("a load that fails with schedules on screen keeps them and adds the failure row")
    func failedReloadKeepsTheRows() async throws {
        let answers = ScheduleAnswers(listed: [schedule("nightly")])
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard request.url?.path.hasSuffix("/schedules") == true else { return nil }
            return try answers.answer(for: request)
        })
        defer { routes.end() }
        let root = try makeRoot()
        let screen = ScheduleListViewController(root: root)
        let window = try show(screen)
        defer { window.isHidden = true; window.rootViewController = nil }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.shownScheduleIDs == ["nightly"]
        })

        answers.isReachable = false
        screen.refresh()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { screen.loadError != nil })
        #expect(screen.shownScheduleIDs == ["nightly"], "the refresh that failed keeps what it had")
    }

    // MARK: - Helpers

    private func show(_ page: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        return window
    }

    private static func status(_ code: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) ?? HTTPURLResponse()
    }
}

/// The schedules route's body, which the app reads as `AgentScheduleListResponse`.
private struct SchedulesBody: Encodable {
    let schedules: [AgentScheduleSummary]
}

/// The schedules route, reachable until the test says otherwise.
private final class ScheduleAnswers: @unchecked Sendable {
    private let listed: [AgentScheduleSummary]
    private let lock = NSLock()
    private var reachable = true

    init(listed: [AgentScheduleSummary]) {
        self.listed = listed
    }

    var isReachable: Bool {
        get { lock.withLock { reachable } }
        set { lock.withLock { reachable = newValue } }
    }

    func answer(for request: URLRequest) throws -> (Data, HTTPURLResponse)? {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let reachable = isReachable
        let status = reachable ? 200 : 500
        let body = reachable
            ? try JSONEncoder().encode(SchedulesBody(schedules: listed))
            : Data(#"{"error":"down"}"#.utf8)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        ) ?? HTTPURLResponse()
        return (body, response)
    }
}
