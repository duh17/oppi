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

    @Test func focusedStreamRecoveryOverlaysBadgeWithoutChangingAppEventGreenHealth() throws {
        let health = ServerHealth.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            transportStates: [.disconnected, .connected],
            hasCachedCatalog: true
        )
        let presentation = WorkspaceServerStatusPresentation.derive(health: health)
        #expect(health.transportState == .connected)
        #expect(ServerBadgeConnectionState(presentation) == .connected)

        let recovering = ServerBadgeConnectionState(
            presentation,
            isFocusedStreamRecovering: true
        )
        #expect(recovering == .recovering)
        #expect(recovering.title == "Recovering")

        let credentials = ServerCredentials(
            host: "paired.test",
            port: 7749,
            token: "dt_focused_stream_recovery",
            name: "Paired HTTPS",
            scheme: .https,
            serverFingerprint: "sha256:FOCUSEDSTREAMRECOVERY"
        )
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        let connection = ServerConnection()
        #expect(connection.configure(credentials: credentials))
        connection.setFocusedSessionStreamRecovering(true, sessionId: "focused-stream")

        #expect(ServerConnectionLanePresentation.title(
            server: server,
            connection: connection,
            state: .connected,
            isPreparing: false
        ) == FocusedSessionStreamRecoveryPresentation.message)
    }

    @Test func focusedStreamRecoveryDoesNotMaskOfflineSyncFailedOrDisconnectedLane() throws {
        let offline = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: false,
            hasCachedCatalog: true
        )
        #expect(ServerBadgeConnectionState(
            offline,
            isFocusedStreamRecovering: true
        ) == .disconnected)

        let live = WorkspaceServerStatusPresentation.derive(
            freshnessState: .live,
            freshnessLabel: "Updated now",
            isTransportConnected: true,
            hasCachedCatalog: true
        )
        #expect(ServerBadgeConnectionState(
            live,
            hasSyncFailure: true,
            isFocusedStreamRecovering: true
        ) == .syncFailed)

        let credentials = ServerCredentials(
            host: "paired.test",
            port: 7749,
            token: "dt_focused_stream_recovery",
            name: "Paired HTTPS",
            scheme: .https,
            serverFingerprint: "sha256:FOCUSEDSTREAMRECOVERYMASK"
        )
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        let connection = ServerConnection()
        #expect(connection.configure(credentials: credentials))
        connection.setFocusedSessionStreamRecovering(true, sessionId: "focused-stream")

        #expect(ServerConnectionLanePresentation.title(
            server: server,
            connection: connection,
            state: .disconnected,
            isPreparing: false
        ) != FocusedSessionStreamRecoveryPresentation.message)
        #expect(ServerConnectionLanePresentation.title(
            server: server,
            connection: connection,
            state: .syncFailed,
            isPreparing: false
        ) != FocusedSessionStreamRecoveryPresentation.message)
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
    @Test(arguments: [true, false]) func refreshWithPriorConnectionEvidenceStaysConnected(isPreparing: Bool) {
        let presentation = WorkspaceServerStatusPresentation(state: .syncing, label: "", isUnreachable: false)
        #expect(ServerBadgeConnectionState(presentation, isPreparing: isPreparing, hasConnectionEvidence: true) == .connected)
        #expect(ServerBadgeConnectionState(presentation, isPreparing: isPreparing, hasConnectionEvidence: false) == .connecting)
        #expect(ServerBadgeConnectionState(presentation, hasSyncFailure: true, hasConnectionEvidence: true) == .syncFailed)
    }

    @Test func connectedPresentationMapsToConnectedBadge() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: true,
            hasCachedCatalog: true
        )

        let state = ServerBadgeConnectionState(presentation)
        #expect(state == .connected)
        #expect(state.systemImage == "checkmark.circle.fill")
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

    @Test func transportNotReadyWithoutSyncFailureIsNotUpdateFailed() {
        let presentation = WorkspaceServerStatusPresentation.derive(
            freshnessState: .offline,
            freshnessLabel: "Updated never",
            isTransportConnected: false,
            hasCachedCatalog: true
        )

        let preparing = ServerBadgeConnectionState(
            presentation,
            hasSyncFailure: false,
            isPreparing: true
        )
        #expect(preparing == .connecting)
        #expect(preparing != .syncFailed)
        #expect(preparing.title == "Connecting")

        let offline = ServerBadgeConnectionState(
            presentation,
            hasSyncFailure: false,
            isPreparing: false
        )
        #expect(offline == .disconnected)
        #expect(offline != .syncFailed)
        #expect(offline.title == "Offline")
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

    @Test func preparingAndUnavailableStatusNamesPairedHostLane() throws {
        let cases = [
            ("studio.tailnet.ts.net", "Connecting over Tailscale", "Tailscale unavailable"),
            ("paired.test", "Connecting over HTTPS/WSS", "HTTPS/WSS server unavailable")
        ]
        for (host, preparingTitle, unavailableTitle) in cases {
            let server = try #require(PairedServer(from: laneCredentials(host: host), sortOrder: 0))
            // A not-yet-configured connection must read the saved host just like nil.
            let connections: [ServerConnection?] = [nil, ServerConnection()]
            for connection in connections {
                #expect(ServerConnectionLanePresentation.title(
                    server: server,
                    connection: connection,
                    state: .connecting,
                    isPreparing: true
                ) == preparingTitle)
                #expect(ServerConnectionLanePresentation.title(
                    server: server,
                    connection: connection,
                    state: .disconnected,
                    isPreparing: false
                ) == unavailableTitle)
            }
        }
    }

    @Test func connectedStatusUsesActiveLaneBeforePairedHostAndProxy() throws {
        let originalProxy = TailnetTransportRoute.proxy
        let originalGeneration = TailnetTransportRoute.generation
        defer { TailnetTransportRoute.publish(originalProxy, generation: originalGeneration) }

        // Synchronous MainActor scope keeps the temporary global route from
        // interleaving with other connection tests or the node controller.
        let proxy = TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "test")
        let cases = [
            ("studio.tailnet.ts.net", false, false, "Connected via Tailscale"),
            ("studio.tailnet.ts.net", true, false, "Connected via in-app Tailscale"),
            ("studio.tailnet.ts.net", false, true, "Connected via local network"),
            ("studio.tailnet.ts.net", true, true, "Connected via local network"),
            ("paired.test", false, false, "Connected via paired HTTPS"),
            ("paired.test", true, false, "Connected via paired HTTPS")
        ]
        for (host, hasProxy, usesLAN, expectedTitle) in cases {
            TailnetTransportRoute.publish(hasProxy ? proxy : nil, generation: hasProxy ? 1 : 0)
            let credentials = laneCredentials(host: host)
            let server = try #require(PairedServer(from: credentials, sortOrder: 0))
            let connection = ServerConnection()
            try #require(connection.configure(credentials: credentials))
            if usesLAN {
                connection._adoptVerifiedLANEndpointForTesting(LANDiscoveredEndpoint(
                    host: "192.168.1.42",
                    port: 7749,
                    serverFingerprintPrefix: "LANESERVER",
                    tlsCertFingerprintPrefix: "LANETLS"
                ))
                try #require(connection.transportPath == .lan)
            }
            #expect(ServerConnectionLanePresentation.title(
                server: server,
                connection: connection,
                state: .connected,
                isPreparing: false
            ) == expectedTitle)
        }
    }

    private func laneCredentials(host: String) -> ServerCredentials {
        ServerCredentials(
            host: host,
            port: 7749,
            token: "dt_connection_lane",
            name: "Studio",
            scheme: .https,
            serverFingerprint: "sha256:LANESERVER",
            tlsCertFingerprint: "sha256:LANETLS"
        )
    }
}

private func badgeServerInfo() -> ServerInfo {
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

typealias WorkspaceStoreMockURLProtocol = TestURLProtocol
