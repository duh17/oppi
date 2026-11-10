import Foundation
import Testing
@testable import Oppi

/// A route rebuild cancels the list refresh in flight and a caller starts a
/// replacement in the same main-actor turn. The cancelled refresh unwinds later and must
/// not take the replacement's single-flight slot: the next caller joins the
/// replacement instead of starting a second parallel fetch.
@Suite("ServerConnection list refresh handoff", .serialized)
@MainActor
struct ServerConnectionListRefreshHandoffTests {
    @Test func cancelledSessionListRefreshLeavesItsReplacementJoinable() async throws {
        let fetches = HeldFetches(holding: ["/sessions/recent": [1, 2]])
        let connection = await makeConnection(fetches: fetches)
        defer { TestURLProtocol.handler = nil }
        var events: [String] = []
        connection._onRefreshEventForTesting = { message, _, _ in events.append(message) }

        let cancelled = Task { @MainActor in await connection.refreshSessionList(force: true) }
        #expect(await waitForTestCondition(timeout: .seconds(2)) { fetches.hasStarted("/sessions/recent", number: 1) })

        // The rebuild cancels the first refresh; the replacement starts before it resumes.
        connection.setAPIClientForTesting(makeClient())
        let replacement = Task { @MainActor in await connection.refreshSessionList(force: true) }
        #expect(await waitForTestCondition(timeout: .seconds(2)) { fetches.hasStarted("/sessions/recent", number: 2) })
        await cancelled.value

        let joiner = Task { @MainActor in await connection.refreshSessionList(force: true) }
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            events.contains("session_list.coalesced")
                || events.filter { $0 == "session_list.start" }.count > 2
        })
        fetches.releaseAll()
        await replacement.value
        await joiner.value

        #expect(events.filter { $0 == "session_list.start" }.count == 2, "the joiner did not start a third fetch")
        #expect(events.contains("session_list.coalesced"))
        #expect(fetches.count("/sessions/recent") == 2)
    }

    @Test func cancelledWorkspaceCatalogRefreshLeavesItsReplacementJoinable() async throws {
        let fetches = HeldFetches(holding: ["/workspaces": [1, 2]])
        let connection = await makeConnection(fetches: fetches)
        defer { TestURLProtocol.handler = nil }
        var events: [String] = []
        connection._onRefreshEventForTesting = { message, _, _ in events.append(message) }

        let cancelled = Task { @MainActor in await connection.refreshWorkspaceCatalog(force: true) }
        #expect(await waitForTestCondition(timeout: .seconds(2)) { fetches.hasStarted("/workspaces", number: 1) })

        connection.setAPIClientForTesting(makeClient())
        let replacement = Task { @MainActor in await connection.refreshWorkspaceCatalog(force: true) }
        #expect(await waitForTestCondition(timeout: .seconds(2)) { fetches.hasStarted("/workspaces", number: 2) })
        await cancelled.value

        let joiner = Task { @MainActor in await connection.refreshWorkspaceCatalog(force: true) }
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            events.contains("workspace_catalog.coalesced")
                || events.filter { $0 == "workspace_catalog.start" }.count > 2
        })
        fetches.releaseAll()
        await replacement.value
        await joiner.value

        #expect(events.filter { $0 == "workspace_catalog.start" }.count == 2, "the joiner did not start a third fetch")
        #expect(events.contains("workspace_catalog.coalesced"))
        #expect(fetches.count("/workspaces") == 2)
    }

    private func makeClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: configuration)
        return APIClient(
            environment: OppiClientEnvironment(
                baseURL: URL(string: "http://handoff.example.test:7749")!,
                bearerToken: "sk_handoff"
            ),
            configuration: configuration
        )
    }

    private func makeConnection(fetches: HeldFetches) async -> ServerConnection {
        let connection = ServerConnection()
        #expect(await configureTestConnection(connection, credentials: ServerCredentials(
            host: "handoff.example.test",
            port: 7749,
            token: "sk_handoff",
            name: "Handoff",
            scheme: .https,
            serverFingerprint: "sha256:handoff"
        )))
        connection.setAPIClientForTesting(makeClient())
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        // The session list refreshes the catalog first unless one is already loaded.
        connection.workspaceStore.isLoaded = true
        TestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            try fetches.enter(path)
            switch path {
            case "/workspaces":
                return try mockJSONResponse(
                    json: #"{"serverNow":1700000000000,"workspaces":[],"summaries":[]}"#, for: request
                )
            case "/skills":
                return try mockJSONResponse(json: #"{"skills":[]}"#, for: request)
            case "/sessions/recent":
                return try mockJSONResponse(json: #"{"sessions":[]}"#, for: request)
            default:
                return try mockJSONResponse(json: "{}", for: request)
            }
        }
        return connection
    }
}

/// Counts each request's arrival and holds the numbered ones until `releaseAll()`, so a
/// test decides which fetch is still in flight. A held request is answered by throwing
/// `TestURLProtocol.Held`, never by blocking the thread the session's other requests need.
private final class HeldFetches: @unchecked Sendable {
    private let lock = NSLock()
    private let held: [String: Set<Int>]
    private var counts: [String: Int] = [:]
    private var resumes: [@Sendable () -> Void] = []
    private var released = false

    init(holding: [String: Set<Int>]) {
        held = holding
    }

    /// Throws `Held` for a request that is held. A request asked again after the release is
    /// not a new arrival.
    func enter(_ path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if released { return }
        let number = (counts[path] ?? 0) + 1
        counts[path] = number
        guard held[path]?.contains(number) == true else { return }
        throw TestURLProtocol.Held { [self] resume in
            lock.lock()
            let alreadyReleased = released
            if !alreadyReleased { resumes.append(resume) }
            lock.unlock()
            if alreadyReleased { resume() }
        }
    }

    func hasStarted(_ path: String, number: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (counts[path] ?? 0) >= number
    }

    func count(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path] ?? 0
    }

    func releaseAll() {
        lock.lock()
        released = true
        let pending = resumes
        resumes = []
        lock.unlock()
        for resume in pending { resume() }
    }
}
