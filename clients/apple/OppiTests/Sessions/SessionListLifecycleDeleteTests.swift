import Foundation
import Testing
@testable import Oppi

/// Deleting a session from a list asks the server first. The device drops the
/// session only once the server no longer has it.
@Suite("Session list delete", .serialized)
@MainActor
struct SessionListLifecycleDeleteTests {
    private let serverId = "delete-server"
    private let workspaceId = "w1"

    private func makeConnection(sessions: [Session]) -> ServerConnection {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let client = APIClient(
            environment: OppiClientEnvironment(baseURL: URL(string: "http://localhost:7749")!, bearerToken: "sk_test"),
            configuration: config
        )
        let connection = ServerConnection()
        connection.configure(credentials: makeTestCredentials(fingerprint: serverId))
        connection.setAPIClientForTesting(client)
        for session in sessions { connection.sessionStore.upsert(session) }
        return connection
    }

    private func response(status: Int, json: String) -> (Data, HTTPURLResponse) {
        (
            Data(json.utf8),
            HTTPURLResponse(
                url: URL(string: "http://localhost:7749")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    private func delete(_ session: Session, on connection: ServerConnection) async -> [String] {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "session-delete-\(UUID().uuidString).json", directoryHint: .notDirectory)
        let drafts = ComposerDraftStore(fileURL: url, saveDelay: .seconds(60))
        await drafts.load()
        var errors: [String] = []
        await SessionListLifecycle.delete(
            session,
            scope: .workspace(workspaceId),
            serverId: serverId,
            connection: connection,
            drafts: drafts,
            onError: { errors.append($0) }
        )
        return errors
    }

    @Test func aRefusedDeleteKeepsTheSessionAndSaysSo() async {
        defer { TestURLProtocol.handler = nil }
        let session = makeTestSession(id: "s1", workspaceId: workspaceId)
        let connection = makeConnection(sessions: [session])
        TestURLProtocol.handler = { _ in self.response(status: 500, json: "{\"error\":\"disk full\"}") }

        let errors = await delete(session, on: connection)

        #expect(connection.sessionStore.sessions.map(\.id) == ["s1"])
        #expect(errors == ["Delete failed: disk full"])
    }

    @Test func aDeleteTheServerAcceptsDropsTheSession() async {
        defer { TestURLProtocol.handler = nil }
        let session = makeTestSession(id: "s1", workspaceId: workspaceId)
        let connection = makeConnection(sessions: [session])
        TestURLProtocol.handler = { _ in self.response(status: 200, json: "{}") }

        let errors = await delete(session, on: connection)

        #expect(connection.sessionStore.sessions.isEmpty)
        #expect(errors.isEmpty)
    }

    @Test func aSessionTheServerAlreadyLostIsDropped() async {
        defer { TestURLProtocol.handler = nil }
        let session = makeTestSession(id: "s1", workspaceId: workspaceId)
        let connection = makeConnection(sessions: [session])
        TestURLProtocol.handler = { _ in self.response(status: 404, json: "{\"error\":\"not found\"}") }

        let errors = await delete(session, on: connection)

        #expect(connection.sessionStore.sessions.isEmpty)
        #expect(errors.isEmpty)
    }
}
