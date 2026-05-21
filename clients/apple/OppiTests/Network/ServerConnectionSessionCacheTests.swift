import Foundation
import Testing
@testable import Oppi

@Suite("ServerConnection Session Cache", .serialized)
@MainActor
struct ServerConnectionSessionCacheTests {
    @Test func refreshSessionListDoesNotLoadAnotherServersCachedSessions() async throws {
        defer { TestURLProtocol.handler = nil }

        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "server-connection-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "cache-root")
        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        await cache.saveSessionList(
            [makeTestSession(id: "studio-session", workspaceId: "w-studio")],
            serverId: "sha256:studio"
        )

        let connection = ServerConnection()
        let serverId = "sha256:mini"
        let configured = connection.configure(credentials: ServerCredentials(
            host: "127.0.0.1",
            port: 7749,
            token: "sk_test",
            name: "Mac Mini",
            serverFingerprint: serverId
        ))
        #expect(configured)

        connection.sessionStore.switchServer(to: serverId)
        connection.workspaceStore.switchServer(to: serverId)
        connection.workspaceStore.workspaces = [makeTestWorkspace(id: "w-mini", name: "Mini")]
        connection.workspaceStore.isLoaded = true
        connection._cacheForTesting = cache
        connection.setAPIClientForTesting(makeMockAPIClient())

        TestURLProtocol.handler = { request in
            if request.url?.path == "/sessions/recent" {
                throw URLError(.notConnectedToInternet)
            }
            throw URLError(.unsupportedURL)
        }

        await connection.refreshSessionList(force: false)

        #expect(connection.sessionStore.sessions.isEmpty)
        #expect(connection.sessionStore.lastSyncFailed)
    }

    private func makeMockAPIClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://127.0.0.1:7749")!,
            token: "sk_test",
            configuration: config
        )
    }
}
