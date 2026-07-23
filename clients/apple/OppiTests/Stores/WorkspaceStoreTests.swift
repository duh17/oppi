import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping

@Suite("WorkspaceStore Offline", .serialized)
@MainActor
struct WorkspaceStoreOfflineTests {
    @Test func loadUsesCachedDataWhenOffline() async throws {
        defer { WorkspaceStoreMockURLProtocol.handler = nil }

        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "workspace-store-tests-\(UUID().uuidString)")
        let root = base.appending(path: "cache-root")
        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let cachedWorkspaces = [makeTestWorkspace(id: "w-cached", name: "Cached Workspace")]
        let cachedSkills = [makeSkill(name: "cached-skill")]
        await cache.saveWorkspaces(cachedWorkspaces)
        await cache.saveSkills(cachedSkills)

        WorkspaceStoreMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let store = WorkspaceStore()
        store._cacheForTesting = cache

        let api = makeAPIClient()
        await store.load(api: api)

        #expect(store.workspaces == cachedWorkspaces)
        #expect(store.skills == cachedSkills)
        #expect(store.isLoaded)
    }

    @Test func loadFailureKeepsExistingStateWhenAlreadyLoaded() async {
        defer { WorkspaceStoreMockURLProtocol.handler = nil }

        WorkspaceStoreMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let store = WorkspaceStore()
        let existingWorkspaces = [makeTestWorkspace(id: "w-existing", name: "Existing Workspace")]
        let existingSkills = [makeSkill(name: "existing-skill")]

        store.workspaces = existingWorkspaces
        store.skills = existingSkills
        store.isLoaded = true

        let api = makeAPIClient()
        await store.load(api: api)

        #expect(store.workspaces == existingWorkspaces)
        #expect(store.skills == existingSkills)
        #expect(store.isLoaded)
    }

    @Test func partialCatalogFailureLeavesCachedContentButMarksStoreOffline() async throws {
        defer { WorkspaceStoreMockURLProtocol.handler = nil }

        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "workspace-store-tests-\(UUID().uuidString)")
        let root = base.appending(path: "cache-root")
        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let cachedWorkspaces = [makeTestWorkspace(id: "w-cached", name: "Cached Workspace")]
        let cachedSkills = [makeSkill(name: "cached-skill")]
        await cache.saveWorkspaces(cachedWorkspaces)
        await cache.saveSkills(cachedSkills)

        WorkspaceStoreMockURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            let encoder = JSONEncoder()

            if request.url?.path == "/workspaces" {
                let data = try encoder.encode(["workspaces": [makeTestWorkspace(id: "w-fresh", name: "Fresh Workspace")]])
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }

            if url.hasSuffix("/skills") {
                throw URLError(.badServerResponse)
            }

            throw URLError(.unsupportedURL)
        }

        let store = WorkspaceStore()
        store._cacheForTesting = cache

        let api = makeAPIClient()
        await store.load(api: api)

        #expect(store.workspaces == cachedWorkspaces)
        #expect(store.skills == cachedSkills)
        #expect(store.isLoaded)
        #expect(store.lastSyncFailed)
        #expect(store.freshnessState() == .offline)
    }

    @Test func loadUsesWorkspaceCatalogSummaries() async throws {
        defer { WorkspaceStoreMockURLProtocol.handler = nil }

        WorkspaceStoreMockURLProtocol.handler = { request in
            let url = request.url!.absoluteString

            if request.url?.path == "/workspaces" {
                let data = """
                {
                  "serverNow": 1700000000000,
                  "workspaces": [{"id":"w1","name":"Dev","skills":[],"createdAt":0,"updatedAt":0}],
                  "summaries": [{"workspaceId":"w1","activeCount":2,"stoppedCount":3,"hasAttention":true,"hasErrorRoot":false,"latestActivity":1500}]
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }

            if url.hasSuffix("/skills") {
                let data = #"{"skills":[]}"#.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }

            throw URLError(.unsupportedURL)
        }

        let store = WorkspaceStore()
        let api = makeAPIClient()
        await store.load(api: api)

        #expect(store.workspaces.map(\.id) == ["w1"])
        #expect(store.workspaceSummaries["w1"]?.activeCount == 2)
        #expect(store.workspaceSummaries["w1"]?.stoppedCount == 3)
        #expect(store.workspaceSummaries["w1"]?.hasAttention == true)
    }

    private func makeAPIClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkspaceStoreMockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
            configuration: config
        )
    }

    private func makeSkill(name: String) -> SkillInfo {
        SkillInfo(
            name: name,
            description: "desc",
            path: "/tmp/\(name)",
            builtIn: true
        )
    }
}

@Suite("Server Health")
@MainActor
struct ServerHealthTests {
    @Test func connectedAppEventStreamKeepsServerReachableWhenFocusedStreamIsDisconnected() {
        let health = ServerHealth.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            transportStates: [.disconnected, .connected],
            hasCachedCatalog: true
        )
        let presentation = WorkspaceServerStatusPresentation.derive(health: health)

        #expect(health.transportState == .connected)
        #expect(presentation.state == .stale)
        #expect(presentation.label == "Connected")
        #expect(!presentation.isUnreachable)
        #expect(ServerBadgeConnectionState(presentation) == .connected)
    }

    @Test func connectingTransportShowsConnectingInsteadOfOffline() {
        let health = ServerHealth.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            transportStates: [.connecting],
            hasCachedCatalog: false
        )
        let presentation = WorkspaceServerStatusPresentation.derive(health: health)

        #expect(health.transportState == .connecting)
        #expect(presentation.state == .syncing)
        #expect(presentation.label == "Connecting")
        #expect(!presentation.isUnreachable)
        #expect(ServerBadgeConnectionState(presentation) == .connecting)
    }

    @Test func successfulFreshnessKeepsServerReachableWithoutAnOpenStream() {
        let health = ServerHealth.derive(
            freshnessState: .live,
            freshnessLabel: "Updated now",
            transportStates: [.disconnected],
            hasCachedCatalog: true
        )
        let presentation = WorkspaceServerStatusPresentation.derive(health: health)

        #expect(health.transportState == .disconnected)
        #expect(presentation.state == .live)
        #expect(presentation.label == "Updated now")
        #expect(!presentation.isUnreachable)
        #expect(ServerBadgeConnectionState(presentation) == .connected)
    }
}

@Suite("Workspace Server Status Presentation")
@MainActor
struct WorkspaceServerStatusPresentationTests {
    @Test func offlineStaysOfflineWhenTransportIsDisconnected() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: false,
            hasCachedCatalog: true
        )

        #expect(presentation.state == .offline)
        #expect(presentation.label == "Updated never")
        #expect(presentation.isUnreachable)
    }

    @Test func connectedTransportWithCachedCatalogShowsConnectedStaleState() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: true,
            hasCachedCatalog: true
        )

        #expect(presentation.state == .stale)
        #expect(presentation.label == "Connected")
        #expect(!presentation.isUnreachable)
    }

    @Test func connectedTransportWithoutCachedCatalogShowsConnectingState() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: true,
            hasCachedCatalog: false
        )

        #expect(presentation.state == .syncing)
        #expect(presentation.label == "Connecting")
        #expect(!presentation.isUnreachable)
    }
}

@Suite("Server Badge Connection State")
@MainActor
struct ServerBadgeConnectionStateTests {
    @Test func connectedPresentationMapsToConnectedBadge() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: true,
            hasCachedCatalog: true
        )

        #expect(ServerBadgeConnectionState(presentation) == .connected)
    }

    @Test func syncingPresentationMapsToConnectingBadge() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: true,
            hasCachedCatalog: false
        )

        #expect(ServerBadgeConnectionState(presentation) == .connecting)
    }

    @Test func activeTransportPreparationMapsToRecoveringBadge() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: false,
            hasCachedCatalog: true
        )

        let state = ServerBadgeConnectionState(
            presentation,
            hasSyncFailure: true,
            isPreparing: true
        )

        #expect(state == .recovering)
        #expect(state.title == "Recovering")
    }

    @Test func firstTransportPreparationMapsToConnectingBadge() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: false,
            hasCachedCatalog: false
        )

        #expect(ServerBadgeConnectionState(
            presentation,
            hasSyncFailure: false,
            isPreparing: true
        ) == .connecting)
    }

    @Test func offlinePresentationMapsToDisconnectedBadge() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: false,
            hasCachedCatalog: false
        )

        #expect(ServerBadgeConnectionState(presentation) == .disconnected)
    }

    @Test func eitherCatalogOrSessionFailureMapsToUpdateFailedBadge() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .live,
            freshnessLabel: "Updated now",
            isTransportConnected: true,
            hasCachedCatalog: true
        )

        #expect(ServerBadgeConnectionState(presentation, hasSyncFailure: true) == .syncFailed)
        #expect(ServerBadgeConnectionState(presentation, hasSyncFailure: false) == .connected)
    }

    @Test func connectedIrohStatusConsolidatesHealthAndLane() async throws {
        let (server, connection) = try await makeIrohBadgeFixture()

        #expect(ServerConnectionLanePresentation.title(
            server: server,
            connection: connection,
            state: .connected,
            isPreparing: false
        ) == "Connected via Iroh")
    }

    @Test func updateFailurePreservesFailureAndActiveLane() async throws {
        let (server, connection) = try await makeIrohBadgeFixture()

        #expect(ServerConnectionLanePresentation.title(
            server: server,
            connection: connection,
            state: .syncFailed,
            isPreparing: false
        ) == "Update failed via Iroh")
    }

    @Test func pairedHTTPStatusUsesAuthoritativeTransportScheme() throws {
        let credentials = ServerCredentials(
            host: "paired.test",
            port: 7749,
            token: "dt_paired_http_badge",
            name: "Paired HTTP",
            scheme: nil,
            serverFingerprint: "sha256:PAIREDHTTPBADGE",
            transports: ServerTransports(
                preference: .httpOnly,
                iroh: nil,
                http: HTTPServerTransport(
                    host: "paired.test",
                    port: 7749,
                    scheme: .http,
                    tlsCertFingerprint: nil
                )
            )
        )
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        let connection = ServerConnection()
        #expect(connection.configure(credentials: credentials))

        #expect(ServerConnectionLanePresentation.title(
            server: server,
            connection: connection,
            state: .connected,
            isPreparing: false
        ) == "Connected via paired HTTP")
    }

    @Test func preparingIrohPreferredServerStaysRouteNeutral() throws {
        let credentials = ServerCredentials(
            host: "studio.tailnet.ts.net",
            port: 7749,
            token: "dt_badge_lane",
            name: "Studio",
            scheme: .https,
            serverFingerprint: "sha256:BADGELANESERVER",
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "iroh-node",
                    alpns: [IrohTunnelProtocol.alpn],
                    addressMode: .nodeId,
                    ticket: nil
                ),
                http: HTTPServerTransport(
                    host: "studio.tailnet.ts.net",
                    port: 7749,
                    scheme: .https,
                    tlsCertFingerprint: nil
                )
            )
        )
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))

        #expect(ServerConnectionLanePresentation.title(
            server: server,
            connection: nil,
            state: .connecting,
            isPreparing: true
        ) == "Connecting")
    }

    private func makeIrohBadgeFixture() async throws -> (PairedServer, ServerConnection) {
        let credentials = ServerCredentials(
            host: "studio.tailnet.ts.net",
            port: 7749,
            token: "dt_badge_fixture",
            name: "Studio",
            scheme: .https,
            serverFingerprint: "sha256:BADGEFIXTURESERVER",
            transports: ServerTransports(
                preference: .irohPreferred,
                iroh: IrohServerTransport(
                    version: 2,
                    nodeId: "iroh-node",
                    alpns: [IrohTunnelProtocol.alpn],
                    addressMode: .nodeId,
                    ticket: nil
                ),
                http: HTTPServerTransport(
                    host: "studio.tailnet.ts.net",
                    port: 7749,
                    scheme: .https,
                    tlsCertFingerprint: nil
                )
            )
        )
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        let connection = ServerConnection()
        let configured = await connection.configureForUse(
            credentials: credentials,
            irohProxyFactory: { _, _ in
                (nil, try #require(URL(string: "http://127.0.0.1:41995")))
            }
        )
        #expect(configured)
        return (server, connection)
    }
}

typealias WorkspaceStoreMockURLProtocol = TestURLProtocol
