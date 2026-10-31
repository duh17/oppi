import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("MCP servers list screen")
struct McpServersViewControllerTests {
    private let firstId = "mcp-list-first"
    private let otherId = "mcp-list-other"

    /// The host menu and the iPad sidebar make another server active before its
    /// list has arrived. Until it does, the first server's rows are gone and the
    /// other server's are not there yet; they never show under the wrong host.
    @Test("a switched server never shows the previous server's rows")
    func rowsFollowTheirOwnHost() async throws {
        let server = McpListStubProtocol.Host()
        let firstClient = server.client(host: "first.mcp-list.test", serverNames: ["alpha"], holdsAnswers: false)
        let otherClient = server.client(host: "other.mcp-list.test", serverNames: ["beta"], holdsAnswers: true)

        let root = try makeTestAppRoot(readyServers: [
            TestReadyServer(id: firstId, name: "First", host: "first.mcp-list.test", client: firstClient),
            TestReadyServer(id: otherId, name: "Other", host: "other.mcp-list.test", client: otherClient),
        ])
        let coordinator = root.coordinator
        let servers = coordinator.serverStore.servers
        let first = try #require(servers.first)
        let other = try #require(servers.dropFirst().first)

        let screen = McpServersViewController(scopeId: McpScopeSnapshot.globalId, root: root)
        let window = try show(UINavigationController(rootViewController: screen))
        defer { hide(window) }
        let alpha = "mcp.server.global.alpha"
        let beta = "mcp.server.global.beta"

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: alpha, in: screen.view) != nil
        }, "the first server's list shows")

        #expect(coordinator.restoreActiveServer(other.id))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: alpha, in: screen.view) == nil
        }, "the first server's rows leave as soon as another server is active")
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(600)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: alpha, in: screen.view) == nil
                && Self.button(withIdentifier: beta, in: screen.view) == nil
        }, "nothing shows while the other server's list is on its way")

        server.releaseHeldAnswers()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            screen.view.layoutIfNeeded()
            return Self.button(withIdentifier: beta, in: screen.view) != nil
        }, "the other server's own list shows when it arrives")
        #expect(Self.button(withIdentifier: alpha, in: screen.view) == nil)
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

    /// The button of a row the list shows now. A removed row's cell can stay in
    /// the view tree, pooled, so only the collection view's visible cells count.
    private static func button(withIdentifier identifier: String, in view: UIView) -> UIButton? {
        guard let list = collectionView(in: view) else { return nil }
        for cell in list.visibleCells {
            if let found = button(withIdentifier: identifier, inside: cell) { return found }
        }
        return nil
    }

    private static func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for subview in view.subviews {
            if let found = collectionView(in: subview) { return found }
        }
        return nil
    }

    private static func button(withIdentifier identifier: String, inside view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        for subview in view.subviews {
            if let found = button(withIdentifier: identifier, inside: subview) { return found }
        }
        return nil
    }
}

/// Answers `GET /mcp/scopes/global/servers` per host with that host's server
/// names, holding a host's answers back until the test releases them.
private final class McpListStubProtocol: URLProtocol {
    /// The routes one test registers; hosts are unique per test, so tests that
    /// run together never share an entry.
    final class Host: @unchecked Sendable {
        func client(host: String, serverNames: [String], holdsAnswers: Bool) -> APIClient {
            McpListStubProtocol.state.withLock { $0.routes[host] = Route(names: serverNames, holds: holdsAnswers) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [McpListStubProtocol.self]
            return APIClient(
                baseURL: URL(string: "https://\(host):7749") ?? URL(fileURLWithPath: "/"),
                token: "sk_test",
                configuration: configuration
            )
        }

        func releaseHeldAnswers() {
            McpListStubProtocol.state.withLock { state in
                for key in state.routes.keys { state.routes[key]?.holds = false }
            }
        }
    }

    struct Route { var names: [String]; var holds: Bool }
    struct State { var routes: [String: Route] = [:] }
    static let state = LockedState(State())

    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return state.withLock { $0.routes[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        answerWhenReleased()
    }

    override func stopLoading() {
        stopped = true
    }

    private func answerWhenReleased() {
        guard !stopped else { return }
        let host = request.url?.host ?? ""
        let route = Self.state.withLock { $0.routes[host] }
        guard let route else { return }
        if route.holds {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
                self?.answerWhenReleased()
            }
            return
        }
        let servers = route.names.map { name in
            McpServerSummary(
                name: name, transport: "http", config: McpServerConfig(url: "https://\(name).example/mcp"),
                enabled: true, exposure: .codemode, state: "connected", tools: [], toolExposure: nil,
                error: nil, supportsOAuth: false
            )
        }
        let body = McpServersResponse(
            scope: McpScopeSnapshot(
                id: McpScopeSnapshot.globalId, title: "Global", kind: "global", projectTrust: nil,
                servers: servers, inherited: nil, errors: []
            ),
            activeSignIn: nil
        )
        let data = (try? JSONEncoder().encode(body)) ?? Data()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class LockedState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
