import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("Workspace Navigation Server Scope", .serialized)
@MainActor
struct WorkspaceNavigationServerScopeTests {
    @Test func staleWorkspaceRefreshDoesNotPresentErrorAfterSwitchingWorkspaces() async throws {
        defer { TestURLProtocol.handler = nil }
        let errorLog = WorkspaceErrorLog()
        let requestLog = RequestLog()
        WorkspaceDetailView._onWorkspaceLoadErrorForTesting = { workspaceId, message in
            errorLog.append(workspaceId: workspaceId, message: message)
        }
        defer { WorkspaceDetailView._onWorkspaceLoadErrorForTesting = nil }

        TestURLProtocol.handler = { request in
            requestLog.append(request)
            if request.url?.path.hasPrefix("/workspaces/ws-old") == true {
                Thread.sleep(forTimeInterval: 0.25)
                return try Self.makeResponse(request: request, status: 404, body: #"{"error":"Workspace not found"}"#)
            }
            return try Self.response(for: request)
        }

        let connection = ServerConnection()
        connection.configure(credentials: makeTestCredentials(host: "single.test", fingerprint: "sha256:single"))
        connection.setAPIClientForTesting(try Self.makeAPIClient(host: "single.test"))
        let navigation = AppNavigation()
        let model = WorkspaceSelectionModel(
            workspace: makeTestWorkspace(id: "ws-old", name: "Old Workspace", gitStatusEnabled: true)
        )

        let host = makeDetailHost(
            model: model,
            connection: connection,
            navigation: navigation
        )
        defer { host.teardown() }

        let oldRefreshStarted = await waitForTestCondition(timeoutMs: 500) {
            requestLog.contains(host: "single.test", pathPrefix: "/workspaces/ws-old")
        }
        #expect(oldRefreshStarted, "Expected the old workspace refresh to start before switching workspaces")

        model.workspace = makeTestWorkspace(id: "ws-new", name: "New Workspace", gitStatusEnabled: true)
        host.pump()

        let staleErrorSurfaced = await waitForTestCondition(timeoutMs: 500) {
            errorLog.contains(workspaceId: "ws-old")
        }
        host.pump()

        #expect(
            !staleErrorSurfaced,
            "A stale refresh from the previous workspace must not surface an error after switching workspaces"
        )
    }

    @Test func workspaceDetailUsesTargetServerConnectionWhenActiveServerDiffers() async throws {
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.pairedServerIdsKey)
        UserDefaults.standard.removeObject(forKey: SharedConstants.pairedServerIdsKey)
        KeychainService.deleteAllServers()
        defer { TestURLProtocol.handler = nil }

        let requestLog = RequestLog()
        TestURLProtocol.handler = { request in
            requestLog.append(request)
            return try Self.response(for: request)
        }

        let serverStore = ServerStore()
        let coordinator = ConnectionCoordinator(serverStore: serverStore)
        let navigation = AppNavigation()

        let serverA = makeServer(id: "sha256:nav-a", name: "Server A", host: "server-a.test")
        let serverB = makeServer(id: "sha256:nav-b", name: "Server B", host: "server-b.test")
        serverStore.addOrUpdate(serverA)
        serverStore.addOrUpdate(serverB)

        coordinator.switchToServer(serverA)
        coordinator.switchToServer(serverB)

        guard let connectionA = coordinator.connection(for: serverA.id),
              let connectionB = coordinator.connection(for: serverB.id) else {
            Issue.record("Expected both server connections to exist")
            return
        }

        connectionA.setAPIClientForTesting(try Self.makeAPIClient(host: "server-a.test"))
        connectionB.setAPIClientForTesting(try Self.makeAPIClient(host: "server-b.test"))
        coordinator.switchToServer(serverA)

        let host = makeHost(
            coordinator: coordinator,
            serverStore: serverStore,
            navigation: navigation
        )
        defer { host.teardown() }

        _ = await waitForTestCondition(timeoutMs: 500) {
            requestLog.contains(host: "server-a.test", pathPrefix: "/workspaces")
                || requestLog.contains(host: "server-b.test", pathPrefix: "/workspaces")
        }
        requestLog.reset()

        navigation.openWorkspace(
            WorkspaceNavTarget(
                serverId: serverB.id,
                workspace: makeTestWorkspace(id: "ws-b", name: "Target Workspace", gitStatusEnabled: true)
            )
        )
        host.pump()

        let observedWorkspaceLoad = await waitForTestCondition(timeoutMs: 1_000) {
            requestLog.contains(host: "server-a.test", pathPrefix: "/workspaces/ws-b")
                || requestLog.contains(host: "server-b.test", pathPrefix: "/workspaces/ws-b/sessions")
        }

        #expect(observedWorkspaceLoad, "Expected WorkspaceDetailView to issue its workspace refresh")
        #expect(
            !requestLog.contains(host: "server-a.test", pathPrefix: "/workspaces/ws-b"),
            "WorkspaceDetailView must not ask the previously active server for the target workspace"
        )
        #expect(
            requestLog.contains(host: "server-b.test", pathPrefix: "/workspaces/ws-b/sessions"),
            "WorkspaceDetailView should refresh through the target server connection"
        )
    }

    private static func bootstrapServerInfo() -> ServerInfo {
        ServerInfo(
            name: "Test",
            version: "1.0.0",
            uptime: 1,
            os: "darwin",
            arch: "arm64",
            hostname: "test.local",
            nodeVersion: "22",
            piVersion: "1",
            configVersion: 1,
            identity: nil,
            uploadProtocol: nil,
            images: nil,
            capabilities: .init(
                sessionStream: .init(version: 1),
                dictationStream: nil,
                appEventStream: nil,
                extensionNativeUI: nil,
                controlSessions: nil
            ),
            stats: .init(
                workspaceCount: 0,
                activeSessionCount: 0,
                totalSessionCount: 0,
                skillCount: 0,
                modelCount: 0
            )
        )
    }

    private static func makeAPIClient(host: String) throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: (testUnwrap(URL(string: "http://\(host):7749"))),
            token: "sk_test",
            configuration: config
        )
    }

    private static func response(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = (testUnwrap(request.url))
        let host = url.host ?? ""
        let path = url.path

        if host == "server-a.test", path.hasPrefix("/workspaces/ws-b") {
            return try makeResponse(request: request, status: 404, body: #"{"error":"Workspace not found"}"#)
        }

        switch path {
        case "/workspaces":
            let workspace = host == "server-b.test"
                ? workspaceJSON(id: "ws-b", name: "Target Workspace")
                : workspaceJSON(id: "ws-a", name: "Source Workspace")
            return try makeResponse(
                request: request,
                body: #"{"serverNow":1700000000000,"workspaces":[\#(workspace)],"summaries":[]}"#
            )
        case "/skills":
            return try makeResponse(request: request, body: #"{"skills":[]}"#)
        case "/sessions/recent":
            return try makeResponse(request: request, body: #"{"sessions":[]}"#)
        default:
            if path.hasSuffix("/sessions") {
                let workspaceId = workspaceId(in: path)
                return try makeResponse(
                    request: request,
                    body: #"{"workspaceId":"\#(workspaceId)","serverNow":1700000000000,"active":[],"stopped":[]}"#
                )
            }
            if path.hasSuffix("/session-buckets") {
                let workspaceId = workspaceId(in: path)
                return try makeResponse(
                    request: request,
                    body: #"{"workspaceId":"\#(workspaceId)","status":"stopped","beforeMs":0,"serverNow":1700000000000,"buckets":[]}"#
                )
            }
            if path.hasSuffix("/attention") {
                let workspaceId = workspaceId(in: path)
                return try makeResponse(
                    request: request,
                    body: #"{"workspaceId":"\#(workspaceId)","serverNow":1700000000000,"attention":{"permissions":[],"asks":[]}}"#
                )
            }
            if path.hasSuffix("/git/status") {
                return try makeResponse(request: request, body: gitStatusJSON)
            }
            if path.hasSuffix("/paths") {
                return try makeResponse(request: request, body: #"{"workspaceId":"ws-b","paths":[]}"#)
            }
            if path == "/models" {
                return try makeResponse(request: request, body: #"{"models":[]}"#)
            }
            if path == "/extensions" {
                return try makeResponse(request: request, body: #"{"extensions":[]}"#)
            }
            if path == "/host/path/status" {
                return try makeResponse(
                    request: request,
                    body: #"{"status":{"path":"/srv/edit-b","resolvedPath":"/srv/edit-b","exists":true,"isDirectory":true,"isFile":false,"issue":null,"message":null}}"#
                )
            }
            return try makeResponse(request: request, body: #"{}"#)
        }
    }

    private static func workspaceJSON(id: String, name: String) -> String {
        #"{"id":"\#(id)","name":"\#(name)","skills":[],"systemPromptMode":"append","gitStatusEnabled":true,"createdAt":1700000000000,"updatedAt":1700000000000}"#
    }

    private static func workspaceId(in path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "workspaces" {
            return parts[1]
        }
        return "unknown"
    }

    private static var gitStatusJSON: String {
        #"{"isGitRepo":false,"branch":null,"headSha":null,"ahead":null,"behind":null,"dirtyCount":0,"untrackedCount":0,"stagedCount":0,"files":[],"totalFiles":0,"addedLines":0,"removedLines":0,"stashCount":0,"lastCommitMessage":null,"lastCommitDate":null,"recentCommits":[]}"#
    }

    private static func makeResponse(
        request: URLRequest,
        status: Int = 200,
        body: String
    ) throws -> (Data, HTTPURLResponse) {
        let data = Data(body.utf8)
        let response = (try #require(HTTPURLResponse(
            url: (testUnwrap(request.url)),
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )))
        return (data, response)
    }

    /// The workspace screen hosted the way the shell hosts it.
    private func makeDetailHost(
        model: WorkspaceSelectionModel,
        connection: ServerConnection,
        navigation: AppNavigation
    ) -> WorkspaceNavigationHostHarness {
        let screen = HostFactory.screen(root: makeTestAppRoot()) {
            WorkspaceDetailSwapHost(model: model)
                .withServerScopedEnvironment(connection)
                .environment(navigation)
        }
        return WorkspaceNavigationHostHarness(
            controller: RouterNavigationController(rootViewController: screen)
        )
    }

    /// The real workspace shell over this coordinator and navigation.
    private func makeHost(
        coordinator: ConnectionCoordinator,
        serverStore: ServerStore,
        navigation: AppNavigation
    ) -> WorkspaceNavigationHostHarness {
        let root = AppRootEnvironment(
            coordinator: coordinator,
            navigation: navigation,
            themeStore: ThemeStore(),
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: []),
            composerDraftStore: ComposerDraftStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appending(path: "workspace-shell-drafts-\(UUID().uuidString).json", directoryHint: .notDirectory),
                saveDelay: .seconds(60)
            ),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        )
        return WorkspaceNavigationHostHarness(controller: WorkspaceShellController(root: root))
    }

    private func makeServer(id: String, name: String, host: String) -> PairedServer {
        let credentials = ServerCredentials(
            host: host,
            port: 7749,
            token: "dt_test",
            name: name,
            scheme: .https,
            serverFingerprint: id
        )
        guard let server = PairedServer(from: credentials, sortOrder: 0) else {
            preconditionFailure("Failed to create PairedServer")
        }
        return server
    }
}

@MainActor
private struct WorkspaceNavigationHostHarness {
    let controller: UIViewController
    let window: UIWindow

    init(controller: UIViewController) {
        controller.loadViewIfNeeded()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        self.controller = controller
        self.window = window
    }

    func pump() {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    func containsText(_ needle: String) -> Bool {
        if let presented = controller.presentedViewController,
           Self.viewHierarchyContainsText(needle, in: presented.view) {
            return true
        }
        return Self.viewHierarchyContainsText(needle, in: controller.view)
    }

    private static func viewHierarchyContainsText(_ needle: String, in view: UIView?) -> Bool {
        guard let view else { return false }
        if let label = view as? UILabel,
           label.text?.localizedCaseInsensitiveContains(needle) == true {
            return true
        }
        if let button = view as? UIButton,
           button.title(for: .normal)?.localizedCaseInsensitiveContains(needle) == true {
            return true
        }
        return view.subviews.contains { viewHierarchyContainsText(needle, in: $0) }
    }

    func teardown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor @Observable
private final class WorkspaceSelectionModel {
    var workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
    }
}

private struct WorkspaceDetailSwapHost: View {
    @Bindable var model: WorkspaceSelectionModel

    var body: some View {
        WorkspaceDetailView(workspace: model.workspace)
    }
}

private final class WorkspaceErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(workspaceId: String, message: String)] = []

    func append(workspaceId: String, message: String) {
        lock.withLock {
            entries.append((workspaceId: workspaceId, message: message))
        }
    }

    func contains(workspaceId: String) -> Bool {
        lock.withLock {
            entries.contains { $0.workspaceId == workspaceId }
        }
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(host: String, path: String)] = []

    func append(_ request: URLRequest) {
        guard let url = request.url else { return }
        lock.withLock {
            entries.append((host: url.host ?? "", path: url.path))
        }
    }

    func reset() {
        lock.withLock {
            entries.removeAll()
        }
    }

    func contains(host: String, pathPrefix: String) -> Bool {
        lock.withLock {
            entries.contains { entry in
                entry.host == host && entry.path.hasPrefix(pathPrefix)
            }
        }
    }
}
