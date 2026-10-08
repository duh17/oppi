#if DEBUG
import SwiftUI

/// Durable Sessions experiment surfaces over an in-memory server that
/// advertises durable sessions: the Settings toggle, the sidebar's Durable
/// item under Terminal, and the Durable scope of All Sessions with its quick
/// session bar, which opens the real Quick Session overlay. Requests go to an
/// in-process stub; no network or Keychain writes.
struct DurableSessionsScreenshotPreview: View {
    enum Surface {
        case settings
        case sidebar
        case list
        /// The list with the real Quick Session overlay already open, for
        /// safe-area and keyboard proof (`SCREENSHOT_SCREEN=quick-session-overlay`).
        case quickSession
    }

    let surface: Surface
    @State private var coordinator: ConnectionCoordinator
    @State private var navigation = AppNavigation()

    init(surface: Surface) {
        self.surface = surface
        Self.applyPreviewDefaults()
        _coordinator = State(initialValue: Self.makeCoordinator())
    }

    var body: some View {
        content
            .accessibilityIdentifier("screenshot.ready")
            // The same overlay ContentView hosts, so Start opens the real sheet.
            .overlay {
                if navigation.showQuickSession {
                    QuickSessionOverlay { navigation.showQuickSession = false }
                }
            }
            .task {
                guard surface == .quickSession else { return }
                ScreenshotPreviewOrientation.applyRequested()
                navigation.showQuickSession = true
            }
            .environment(coordinator)
            .environment(coordinator.serverStore)
            .withServerScopedEnvironment(coordinator.activeConnection)
            .environment(navigation)
            .environment(ThemeStore())
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch surface {
        case .settings:
            NavigationStack { SettingsView() }
        case .sidebar:
            WorkspaceSidebarView()
        case .list, .quickSession:
            NavigationStack { SessionInboxView(scope: .durable) }
        }
    }

    /// Volatile argument-domain values: the preview sees the experiments on and
    /// an SSH host configured, and nothing is written to the app's defaults.
    private static func applyPreviewDefaults() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[AppPreferences.Experiments.durableSessionsKey] = true
        arguments[AppPreferences.Experiments.sshTerminalKey] = true
        let profile = SSHTerminalProfile(host: "mac-studio.local", username: "chen")
        arguments[SSHTerminalProfileStore.storageKey] = try? JSONEncoder().encode(profile)
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    private static func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        guard let server = PairedServer(from: ServerCredentials(
            host: "mac-studio.local",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            scheme: .https,
            serverFingerprint: "sha256:durable-preview",
            tlsCertFingerprint: "sha256:durable-preview-leaf"
        )) else { return coordinator }
        coordinator.serverStore.replaceServersForPreview([server])
        guard coordinator.switchToServer(server),
              let connection = coordinator.connection(for: server.id) else { return coordinator }
        connection.setSplitStreamCapabilitiesForTesting(durableSessions: true)
        connection.setAPIClientForTesting(DurablePreviewAPI.makeClient())
        for workspace in workspaces {
            connection.workspaceStore.upsert(workspace, serverId: server.id)
        }
        connection.sessionStore.switchServer(to: server.id)
        connection.sessionStore.sessions = sessions
        return coordinator
    }

    private static let workspaces = [
        workspace(id: "oppi", name: "oppi", icon: "iphone.and.arrow.forward"),
        workspace(id: "kypu", name: "kypu", icon: "figure.run"),
    ]

    private static let sessions = [
        session(
            id: "durable-1", workspaceId: "oppi", name: "Spawn a scout for the flaky stop test",
            status: .busy, minutesAgo: 1, engine: .durable
        ),
        session(
            id: "durable-2", workspaceId: "kypu", name: "Backfill Garmin sleep scores",
            status: .ready, minutesAgo: 34, engine: .durable
        ),
        session(
            id: "durable-3", workspaceId: "oppi", name: "Fork from the queue edit and retry",
            status: .stopped, minutesAgo: 180, engine: .durable
        ),
        session(
            id: "classic-1", workspaceId: "oppi", name: "Classic session stays in All Sessions",
            status: .ready, minutesAgo: 5, engine: .classic
        ),
    ]

    /// Full-history load (`recentDays=0`): adds a month-old stopped durable
    /// session that the live store's recent window does not hold.
    fileprivate static let historyJSON: Data = {
        let monthAgo = Int(Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970 * 1000)
        return Data("""
        {"sessions":[{"id":"durable-old","workspaceId":"kypu","workspaceName":"kypu",
         "name":"Migrate run splits to the new schema","status":"stopped",
         "createdAt":\(monthAgo - 600_000),"lastActivity":\(monthAgo),"messageCount":14,
         "tokens":{"input":40000,"output":8000},"cost":1.2,"engine":"durable"}]}
        """.utf8)
    }()

    private static func workspace(id: String, name: String, icon: String) -> Workspace {
        Workspace(
            id: id,
            name: name,
            description: nil,
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
        minutesAgo: Double,
        engine: SessionEngine
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
            cost: 0.42,
            engine: engine
        )
    }
}

private enum DurablePreviewAPI {
    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DurablePreviewURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://durable-preview.oppi") ?? URL(fileURLWithPath: "/"),
            token: "preview-token",
            configuration: config
        )
    }
}

/// Answers the durable history load; every other request is a 404.
private final class DurablePreviewURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "durable-preview.oppi"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isHistory = url.path == "/sessions/recent"
        let body = isHistory ? DurableSessionsScreenshotPreview.historyJSON : Data(#"{"error":"Not found"}"#.utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: isHistory ? 200 : 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
