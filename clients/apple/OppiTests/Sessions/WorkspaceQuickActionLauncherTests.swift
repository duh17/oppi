import Foundation
import Testing
import UIKit
@testable import Oppi

/// Answers every request with a created session, so the launcher's own
/// create-then-show path runs without a server.
private final class CreatedSessionURLProtocol: URLProtocol, @unchecked Sendable {
    static let sessionId = "launched-1"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Data("""
        {"session":{"id":"\(Self.sessionId)","status":"ready","createdAt":1,"lastActivity":1,
        "messageCount":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"cost":0}}
        """.utf8)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite("Workspace quick action launcher")
struct WorkspaceQuickActionLauncherTests {
    private final class Spy {
        var progress: [String?] = []
        var pushed: [ChatViewController] = []
    }

    private func makeLauncher(
        spy: Spy,
        presenter: UIViewController,
        push: ((ChatViewController) -> Void)? = nil
    ) throws -> WorkspaceQuickActionLauncher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CreatedSessionURLProtocol.self]
        let baseURL = try #require(URL(string: "http://localhost:8080"))
        return WorkspaceQuickActionLauncher(
            connection: ServerConnection(),
            apiClient: APIClient(baseURL: baseURL, token: "test-token", configuration: config),
            navigation: AppNavigation(),
            workspaceId: "w1",
            presenter: presenter,
            isLaunching: { false },
            setProgress: { spy.progress.append($0) },
            push: push
        )
    }

    /// A surface that passes no `push`, such as the file viewer, gets the new
    /// session's chat on its own navigation stack.
    @Test func launchPushesTheChatOntoThePresentersNavigationByDefault() async throws {
        let spy = Spy()
        let presenter = UIViewController()
        let navigation = UINavigationController(rootViewController: presenter)
        let launcher = try makeLauncher(spy: spy, presenter: presenter)

        let launched = await launcher.startEmptySession { .attaching(sessionId: $0.id, filePath: "a.swift") }

        #expect(launched)
        let chat = try #require(navigation.topViewController as? ChatViewController)
        #expect(chat.sessionId == CreatedSessionURLProtocol.sessionId)
        #expect(navigation.viewControllers.count == 2)
        // Progress is shown for the launch, then cleared.
        // (`first`/`last` would be a doubly optional compare, so index.)
        #expect(spy.progress.count == 2)
        #expect(spy.progress[0] != nil)
        #expect(spy.progress[1] == nil)
    }

    /// A surface with its own navigator, the chat's context bar, receives the
    /// chat and the presenter's stack stays as it was.
    @Test func aSurfacePushOverrideReceivesTheChatInsteadOfThePresenter() async throws {
        let spy = Spy()
        let presenter = UIViewController()
        let navigation = UINavigationController(rootViewController: presenter)
        let launcher = try makeLauncher(spy: spy, presenter: presenter) { spy.pushed.append($0) }

        let launched = await launcher.startEmptySession { .attaching(sessionId: $0.id, filePath: "a.swift") }

        #expect(launched)
        #expect(spy.pushed.map(\.sessionId) == [CreatedSessionURLProtocol.sessionId])
        #expect(navigation.viewControllers == [presenter])
    }
}
