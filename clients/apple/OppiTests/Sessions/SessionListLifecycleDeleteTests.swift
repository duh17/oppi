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
        TestURLProtocol.install(in: config)
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

    /// What the device keeps for a session: its draft and its cached timeline.
    private struct Seeded {
        let session: Session
        let draftKey: ComposerDraftKey
        let drafts: ComposerDraftStore
    }

    private func seed(_ connection: ServerConnection, sessionId: String) async -> Seeded {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "session-delete-\(UUID().uuidString).json", directoryHint: .notDirectory)
        let drafts = ComposerDraftStore(fileURL: url, saveDelay: .seconds(60))
        await drafts.load()
        let session = makeTestSession(id: sessionId, workspaceId: workspaceId)
        connection.sessionStore.upsert(session)
        let key = ComposerDraftKey(
            serverID: serverId,
            workspaceID: SessionRouteScope.workspace(workspaceId).composerDraftScopeID,
            sessionID: sessionId
        )!
        drafts.setDraft(ComposerDraftPayload(text: "unsent words", repoPointers: []), for: key)
        await TimelineCache.shared.saveTrace(sessionId, serverId: serverId, events: [
            TraceEvent(
                id: "cached-1", type: .assistant, timestamp: "2026-02-11T00:00:00Z", text: "cached", tool: nil,
                args: nil, output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil
            ),
        ])
        return Seeded(session: session, draftKey: key, drafts: drafts)
    }

    private func delete(_ seeded: Seeded, on connection: ServerConnection) async -> (deleted: Bool, errors: [String]) {
        var errors: [String] = []
        let deleted = await SessionListLifecycle.delete(
            seeded.session,
            scope: .workspace(workspaceId),
            serverId: serverId,
            connection: connection,
            drafts: seeded.drafts,
            onError: { errors.append($0) }
        )
        return (deleted, errors)
    }

    private func keepsEverything(_ seeded: Seeded, _ connection: ServerConnection) async -> Bool {
        let cached = await TimelineCache.shared.loadTrace(seeded.session.id, serverId: serverId)
        return connection.sessionStore.sessions.map(\.id) == [seeded.session.id]
            && seeded.drafts.record(for: seeded.draftKey)?.payload.text == "unsent words"
            && cached != nil
    }

    private func keepsNothing(_ seeded: Seeded, _ connection: ServerConnection) async -> Bool {
        let cached = await TimelineCache.shared.loadTrace(seeded.session.id, serverId: serverId)
        return connection.sessionStore.sessions.isEmpty
            && seeded.drafts.record(for: seeded.draftKey) == nil
            && cached == nil
    }

    @Test func aRefusedDeleteKeepsTheSessionItsDraftAndItsCachedTimeline() async {
        defer { TestURLProtocol.handler = nil }
        let connection = makeConnection(sessions: [])
        let seeded = await seed(connection, sessionId: "refused-\(UUID().uuidString)")
        defer { Task { await TimelineCache.shared.removeTrace(seeded.session.id, serverId: serverId) } }
        TestURLProtocol.handler = { _ in self.response(status: 500, json: "{\"error\":\"disk full\"}") }

        let result = await delete(seeded, on: connection)

        #expect(!result.deleted)
        #expect(result.errors == ["Delete failed: disk full"])
        #expect(await keepsEverything(seeded, connection))
    }

    @Test func aDeleteTheServerAcceptsDropsTheSessionItsDraftAndItsCachedTimeline() async {
        defer { TestURLProtocol.handler = nil }
        let connection = makeConnection(sessions: [])
        let seeded = await seed(connection, sessionId: "deleted-\(UUID().uuidString)")
        TestURLProtocol.handler = { _ in self.response(status: 200, json: "{}") }

        let result = await delete(seeded, on: connection)

        #expect(result.deleted)
        #expect(result.errors.isEmpty)
        #expect(await keepsNothing(seeded, connection))
    }

    @Test func aSessionTheServerAlreadyLostIsDroppedWithItsDraftAndItsCachedTimeline() async {
        defer { TestURLProtocol.handler = nil }
        let connection = makeConnection(sessions: [])
        let seeded = await seed(connection, sessionId: "gone-\(UUID().uuidString)")
        TestURLProtocol.handler = { _ in self.response(status: 404, json: "{\"error\":\"not found\"}") }

        let result = await delete(seeded, on: connection)

        #expect(result.deleted)
        #expect(result.errors.isEmpty)
        #expect(await keepsNothing(seeded, connection))
    }
}
