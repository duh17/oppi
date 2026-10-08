#if DEBUG
import SwiftUI

/// Server, workspace, and session locks over an in-memory server: lock badges
/// on session, workspace, and server rows, locked rows that hide their
/// details, the shared session menu and swipes, and the Lock toggles.
/// Requests go to an in-process stub that answers 404.
///
/// `SCOPED_LOCK_SURFACE`: `inbox` (default), `sidebar`, `app-settings`,
/// `sessions-settings`, `server-settings`, `workspace-settings`, and
/// `session-cover` (a locked session's destination before unlock).
struct ScopedLocksScreenshotPreview: View {
    @State private var coordinator: ConnectionCoordinator
    @State private var navigation = AppNavigation()
    private let surface = ProcessInfo.processInfo.environment["SCOPED_LOCK_SURFACE"] ?? "inbox"

    init() {
        _coordinator = State(initialValue: Self.makeCoordinator())
        _ = Self.fixtureLocks
    }

    var body: some View {
        @Bindable var navigation = navigation
        content
            .accessibilityIdentifier("screenshot.ready")
            .environment(coordinator)
            .environment(coordinator.serverStore)
            .withServerScopedEnvironment(coordinator.activeConnection)
            .environment(navigation)
            .environment(ThemeStore())
    }

    @ViewBuilder
    private var content: some View {
        @Bindable var navigation = navigation
        switch surface {
        case "sidebar":
            WorkspaceSidebarView()
        case "app-settings":
            NavigationStack { SettingsView() }
        case "sessions-settings":
            NavigationStack { SettingsSessionsPage() }
        case "server-settings":
            NavigationStack { ServerSettingsRootView(server: Self.mainServer) }
        case "workspace-settings":
            NavigationStack { WorkspaceSettingsRootView(workspace: Self.workspaces[1]) }
        case "session-cover":
            NavigationStack {
                WorkspaceSessionScopedDestinationView(target: WorkspaceSessionNavTarget(
                    serverId: Self.mainServer.id,
                    sessionId: "scoped-2",
                    workspaceId: "chaosdonkey"
                ))
            }
        default:
            NavigationStack(path: $navigation.workspacePath) { SessionInboxView() }
        }
    }

    // MARK: Fixture

    private static let mainServer = server(id: "sha256:scoped-lock-main", name: "mac-studio", host: "mac-studio.local")
    private static let otherServer = server(id: "sha256:scoped-lock-other", name: "build-mini", host: "build-mini.local")
    private static let lockedServer = server(id: "sha256:scoped-lock-locked", name: "ci-runner", host: "ci-runner.local")

    /// oppi is locked, kypu is locked but unlocked for now, chaosdonkey has no lock.
    private static let workspaces = [
        workspace(id: "oppi", name: "oppi", icon: "iphone.and.arrow.forward"),
        workspace(id: "kypu", name: "kypu", icon: "figure.run"),
        workspace(id: "chaosdonkey", name: "chaosdonkey", icon: "pencil.and.scribble"),
    ]

    private static let sessions = [
        session(id: "scoped-1", workspaceId: "oppi", name: "Rotate the staging API keys", status: .busy, minutesAgo: 1),
        session(id: "scoped-2", workspaceId: "chaosdonkey", name: "Draft the App Lock post", status: .ready, minutesAgo: 6),
        session(id: "scoped-3", workspaceId: "kypu", name: "Backfill Garmin sleep scores", status: .ready, minutesAgo: 12),
        session(id: "scoped-4", workspaceId: "chaosdonkey", name: "Fix the flaky stop test", status: .busy, minutesAgo: 3),
        session(id: "scoped-5", workspaceId: "chaosdonkey", name: "Tidy the Hugo theme", status: .stopped, minutesAgo: 90),
    ]

    /// Fixture flags, applied once per launch (SwiftUI re-creates this view;
    /// reapplying would undo a lock the user just added). Earlier runs' flags
    /// for these servers are dropped first.
    private static let fixtureLocks: Void = applyLocks()

    private static func applyLocks() {
        let locks = ScopedLockService.shared
        locks.forgetServer(mainServer.id)
        locks.forgetServer(otherServer.id)
        locks.forgetServer(lockedServer.id)
        // An unlocked server would cover every lock under it, so the server
        // with the sessions has no lock of its own.
        locks.lock(.server(serverId: otherServer.id), unlockedForNow: true)
        locks.lock(.server(serverId: lockedServer.id))
        locks.lock(.workspace(serverId: mainServer.id, workspaceId: "oppi"))
        locks.lock(.workspace(serverId: mainServer.id, workspaceId: "kypu"), unlockedForNow: true)
        locks.lock(.session(serverId: mainServer.id, sessionId: "scoped-2"))
        locks.lock(.session(serverId: mainServer.id, sessionId: "scoped-3"), unlockedForNow: true)
    }

    private static func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview([mainServer, otherServer, lockedServer])
        guard coordinator.switchToServer(mainServer),
              let connection = coordinator.connection(for: mainServer.id) else { return coordinator }
        connection.setAPIClientForTesting(ScopedLocksPreviewAPI.makeClient())
        for workspace in workspaces {
            connection.workspaceStore.upsert(workspace, serverId: mainServer.id)
        }
        connection.sessionStore.switchServer(to: mainServer.id)
        connection.sessionStore.sessions = sessions
        ScopedLockService.shared.sessionLookup = { _, sessionId in sessions.first { $0.id == sessionId } }
        return coordinator
    }

    private static func server(id: String, name: String, host: String) -> PairedServer {
        guard let server = PairedServer(from: ServerCredentials(
            host: host,
            port: 7749,
            token: "sk_preview",
            name: name,
            scheme: .https,
            serverFingerprint: id,
            tlsCertFingerprint: "\(id)-leaf"
        )) else { preconditionFailure("preview server fixture") }
        return server
    }

    private static func workspace(id: String, name: String, icon: String) -> Workspace {
        Workspace(
            id: id,
            name: name,
            description: "Preview workspace",
            icon: .symbol(icon),
            systemPrompt: nil,
            hostMount: "~/workspace/\(id)",
            gitStatusEnabled: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func session(
        id: String,
        workspaceId: String,
        name: String,
        status: SessionStatus,
        minutesAgo: Double
    ) -> Session {
        let lastActivity = Date().addingTimeInterval(-minutesAgo * 60)
        return Session(
            id: id,
            workspaceId: workspaceId,
            workspaceName: workspaceId,
            name: name,
            status: status,
            createdAt: lastActivity.addingTimeInterval(-600),
            lastActivity: lastActivity,
            model: "anthropic/claude-opus-5-5",
            messageCount: 6,
            tokens: TokenUsage(input: 12_000, output: 2_400),
            cost: 0.42
        )
    }
}

private enum ScopedLocksPreviewAPI {
    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScopedLocksPreviewURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://scoped-locks-preview.oppi") ?? URL(fileURLWithPath: "/"),
            token: "preview-token",
            configuration: config
        )
    }
}

/// Every request is a 404; the preview shows cached fixture data.
private final class ScopedLocksPreviewURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "scoped-locks-preview.oppi"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 404,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
