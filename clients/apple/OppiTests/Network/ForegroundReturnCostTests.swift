import Testing
import Foundation
@testable import Oppi

/// What one return to the app costs the server: app-event sockets opened and list reads per
/// background cycle. A return used to open the global stream twice and read the workspace
/// catalog, skills, and session list twice (once at foreground, once in the stream's handshake).
@Suite("Foreground return cost", .serialized)
@MainActor
struct ForegroundReturnCostTests {
    @Test func returnInsideTheCloseGraceKeepsTheSocketAndReadsNothing() async throws {
        let rig = try await ReturnRig.make()
        let keepAlive = BackgroundKeepAlive(
            backgroundTasks: rig.tasks,
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )

        keepAlive.closeAfterGrace { rig.connection.prepareForBackground() }
        keepAlive.end()
        await rig.connection.reconnectIfNeeded()

        #expect(rig.sockets.opened == 0)
        #expect(rig.listReads == ListReads(workspaces: 0, skills: 0, sessions: 0))
        #expect(rig.connection.appEventStreamTransportState == .connected)
        await rig.end()
    }

    @Test func returnAfterTheGraceReopensOnceAndReadsSessionsOnly() async throws {
        let rig = try await ReturnRig.make()
        let keepAlive = BackgroundKeepAlive(backgroundTasks: rig.tasks, sleep: { _ in })

        keepAlive.closeAfterGrace { rig.connection.prepareForBackground() }
        await rig.tasks.waitForEnd()
        #expect(rig.connection.appEventStreamTransportState == .disconnected)

        keepAlive.end()
        await rig.connection.reconnectIfNeeded()
        #expect(await rig.waitForSessionListRead())

        #expect(rig.sockets.opened == 1)
        // Session rows ride on events the stream dropped; the catalog is inside its freshness window.
        #expect(rig.listReads == ListReads(workspaces: 0, skills: 0, sessions: 1))
        await rig.end()
    }

    @Test func returnAfterTheCatalogWentStaleReadsItOnce() async throws {
        let rig = try await ReturnRig.make()
        rig.connection.workspaceStore.markSyncSucceeded(
            at: Date().addingTimeInterval(-ServerConnection.listRefreshMinimumInterval - 1)
        )

        rig.connection.prepareForBackground()
        await rig.connection.reconnectIfNeeded()
        #expect(await rig.waitForSessionListRead())

        #expect(rig.sockets.opened == 1)
        #expect(rig.listReads == ListReads(workspaces: 1, skills: 1, sessions: 1))
        await rig.end()
    }

    /// The path report that follows a wake finds the focused socket closed, and used to restart
    /// the stream the foreground had just started.
    @Test func pathReportDuringTheOpeningDoesNotRestartTheStream() async throws {
        let rig = try await ReturnRig.make()
        rig.sockets.holdHandshake = true

        rig.connection.prepareForBackground()
        await rig.connection.reconnectIfNeeded()
        #expect(rig.sockets.opened == 1)

        rig.connection.handleNetworkPathChange()
        #expect(rig.sockets.opened == 1)

        rig.sockets.holdHandshake = false
        rig.sockets.deliverHandshake()
        #expect(await rig.waitForSessionListRead())
        #expect(rig.sockets.opened == 1)
        await rig.end()
    }
}

private struct ListReads: Equatable {
    let workspaces: Int
    let skills: Int
    let sessions: Int
}

/// One connection against an in-memory server: counted HTTP reads, and a socket that answers
/// every open with `app_events_connected`.
@MainActor
private final class ReturnRig {
    let connection = ServerConnection()
    let sockets = ReturnSockets()
    let tasks = FakeBackgroundTasks()
    private let reads = ReturnReadCounter()
    private var scope: TestURLProtocol.RouteScope?

    var listReads: ListReads {
        ListReads(
            workspaces: reads.count(path: "/workspaces"),
            skills: reads.count(path: "/skills"),
            sessions: reads.count(path: "/sessions/recent")
        )
    }

    static func make() async throws -> ReturnRig {
        let rig = ReturnRig()
        let connection = rig.connection
        let reads = rig.reads
        rig.scope = TestURLProtocol.routeScope { request in
            reads.record(path: request.url?.path ?? "")
            let body: String
            switch request.url?.path {
            case "/workspaces": body = "{\"serverNow\":1700000000000,\"workspaces\":[],\"summaries\":[]}"
            case "/skills": body = "{\"skills\":[]}"
            case "/sessions/recent": body = "{\"sessions\":[]}"
            default: body = "{}"
            }
            let response = try #require(HTTPURLResponse(
                url: request.url ?? URL(string: "https://return.example.test")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            return (Data(body.utf8), response)
        }
        let configuration = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: configuration)
        #expect(await configureTestConnection(connection, credentials: ServerCredentials(
            host: "return.example.test",
            port: 7749,
            token: "sk_return",
            name: "Return",
            scheme: .https,
            serverFingerprint: "sha256:return"
        )))
        connection.setAPIClientForTesting(APIClient(
            environment: OppiClientEnvironment(
                baseURL: try #require(URL(string: "https://return.example.test:7749")),
                bearerToken: "sk_return"
            ),
            configuration: configuration
        ))
        connection.setSplitStreamCapabilitiesForTesting(appEventStream: true)
        connection._listPairingApprovalsForTesting = { [] }
        connection._connectStreamForTesting = { AsyncStream { $0.finish() } }
        connection._appEventWebSocketFactoryForTesting = { request in rig.sockets.make(request) }

        // A connection that has been in the foreground a while: lists loaded, stream up.
        connection.workspaceStore.isLoaded = true
        connection.workspaceStore.markSyncSucceeded(at: Date())
        connection.sessionStore.markSyncSucceeded(at: Date())
        connection.startAppEventStreamIfAvailable()
        #expect(await waitForMainActorCondition { connection.appEventStreamTransportState == .connected })
        // The first handshake's own reads belong to setup, not to a return.
        #expect(await rig.waitForSessionListRead())
        // An empty session list always reads again; a connection in use has rows.
        connection.sessionStore.upsert(makeTestSession(id: "s1", workspaceId: "w1"))
        connection.sessionStore.markSyncSucceeded(at: Date())
        rig.sockets.resetCount()
        reads.reset()
        return rig
    }

    /// Ends the test's connection and its handler once the requests a return starts in the
    /// background (the capability reload) have been answered.
    func end() async {
        _ = await scope?.settle()
        connection._appEventWebSocketFactoryForTesting = nil
        connection._connectStreamForTesting = nil
        connection.disconnectAppEventStream()
        connection.disconnectStream()
        scope?.end()
    }

    /// The handshake's repair read the session list and finished.
    func waitForSessionListRead() async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(10)) {
            reads.count(path: "/sessions/recent") >= 1 && !connection.sessionStore.isSyncing
        }
    }
}

@MainActor
private final class ReturnSockets {
    private(set) var opened = 0
    /// While set, an open waits for `deliverHandshake()` instead of answering at once.
    var holdHandshake = false
    /// The transport holds its socket weakly, so the sockets live here.
    private var sockets: [ReturnSocket] = []
    private var held: [ReturnSocket] = []

    func resetCount() { opened = 0 }

    func make(_ request: URLRequest) -> PersistentWebSocketTransport {
        opened += 1
        let socket = ReturnSocket()
        sockets.append(socket)
        if holdHandshake {
            held.append(socket)
        } else {
            socket.deliverHandshake()
        }
        return socket.transport
    }

    func deliverHandshake() {
        held.forEach { $0.deliverHandshake() }
        held.removeAll()
    }
}

@MainActor
private final class ReturnSocket {
    private var queued: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var pending: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    lazy var transport = PersistentWebSocketTransport(
        identity: self,
        resume: {},
        receive: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.receive()
        },
        sendPing: { $0(nil) },
        cancel: { [weak self] _, _ in self?.resolve(.failure(CancellationError())) },
        response: { nil },
        closeCode: { .invalid }
    )

    func deliverHandshake() {
        resolve(.success(.string("{\"type\":\"app_events_connected\",\"serverTime\":42,\"snapshotRequired\":true}")))
    }

    private func receive() async throws -> URLSessionWebSocketTask.Message {
        if !queued.isEmpty { return try queued.removeFirst().get() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    private func resolve(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        if let pending {
            self.pending = nil
            pending.resume(with: result)
        } else {
            queued.append(result)
        }
    }
}

private final class ReturnReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: Int] = [:]

    func record(path: String) {
        lock.lock()
        defer { lock.unlock() }
        paths[path, default: 0] += 1
    }

    func count(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return paths[path, default: 0]
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        paths.removeAll()
    }
}
