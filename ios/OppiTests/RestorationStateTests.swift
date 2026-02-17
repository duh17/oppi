import Testing
import Foundation
@testable import Oppi

@Suite("RestorationState")
struct RestorationStateTests {

    // MARK: - Codable round-trip

    @Test func encodeDecodeRoundTrip() throws {
        let state = RestorationState(
            version: RestorationState.schemaVersion,
            activeSessionId: "s1",
            activeServerId: "sha256:abc",
            selectedTab: "workspaces",
            composerDraft: "draft text",
            scrollAnchorItemId: "item-42",
            wasNearBottom: false,
            timestamp: Date()
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RestorationState.self, from: data)

        #expect(decoded.version == state.version)
        #expect(decoded.activeSessionId == "s1")
        #expect(decoded.activeServerId == "sha256:abc")
        #expect(decoded.selectedTab == "workspaces")
        #expect(decoded.composerDraft == "draft text")
        #expect(decoded.scrollAnchorItemId == "item-42")
        #expect(decoded.wasNearBottom == false)
    }

    @Test func encodeDecodeNilOptionals() throws {
        let state = RestorationState(
            version: RestorationState.schemaVersion,
            activeSessionId: nil,
            activeServerId: nil,
            selectedTab: "settings",
            composerDraft: nil,
            scrollAnchorItemId: nil,
            wasNearBottom: nil,
            timestamp: Date()
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RestorationState.self, from: data)

        #expect(decoded.activeSessionId == nil)
        #expect(decoded.activeServerId == nil)
        #expect(decoded.composerDraft == nil)
        #expect(decoded.scrollAnchorItemId == nil)
        #expect(decoded.wasNearBottom == nil)
        #expect(decoded.selectedTab == "settings")
    }

    // MARK: - Save and Load

    @MainActor
    @Test func saveAndLoad() {
        RestorationState.clear()

        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        let conn = coordinator.connection
        conn.sessionStore.activeSessionId = "s1"
        conn.composerDraft = "test draft"

        let nav = AppNavigation()
        nav.selectedTab = .workspaces

        RestorationState.save(from: conn, coordinator: coordinator, navigation: nav)

        let loaded = RestorationState.load()
        #expect(loaded != nil)
        #expect(loaded?.activeSessionId == "s1")
        #expect(loaded?.composerDraft == "test draft")
        #expect(loaded?.selectedTab == "workspaces")

        RestorationState.clear()
    }

    // MARK: - Freshness

    @Test func staleStateReturnsNil() {
        let old = RestorationState(
            version: RestorationState.schemaVersion,
            activeSessionId: "s1",
            activeServerId: nil,
            selectedTab: "sessions",
            composerDraft: nil,
            scrollAnchorItemId: nil,
            wasNearBottom: nil,
            timestamp: Date().addingTimeInterval(-7200)
        )

        if let data = try? JSONEncoder().encode(old) {
            UserDefaults.standard.set(data, forKey: RestorationState.key)
        }

        let loaded = RestorationState.load()
        #expect(loaded == nil, "State older than 1 hour should return nil")

        RestorationState.clear()
    }

    // MARK: - Schema version mismatch

    @Test func wrongVersionReturnsNil() {
        let wrong = RestorationState(
            version: 999,
            activeSessionId: "s1",
            activeServerId: nil,
            selectedTab: "sessions",
            composerDraft: nil,
            scrollAnchorItemId: nil,
            wasNearBottom: nil,
            timestamp: Date()
        )

        if let data = try? JSONEncoder().encode(wrong) {
            UserDefaults.standard.set(data, forKey: RestorationState.key)
        }

        let loaded = RestorationState.load()
        #expect(loaded == nil, "Wrong schema version should return nil")

        RestorationState.clear()
    }

    // MARK: - Clear

    @MainActor
    @Test func clearRemovesState() {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        let nav = AppNavigation()
        RestorationState.save(from: coordinator.connection, coordinator: coordinator, navigation: nav)

        #expect(RestorationState.load() != nil)

        RestorationState.clear()

        #expect(RestorationState.load() == nil)
    }

    // MARK: - Missing data returns nil

    @Test func noDataReturnsNil() {
        RestorationState.clear()
        #expect(RestorationState.load() == nil)
    }

    // MARK: - Corrupted data returns nil

    @Test func corruptedDataReturnsNil() {
        UserDefaults.standard.set("not json".data(using: .utf8), forKey: RestorationState.key)
        #expect(RestorationState.load() == nil)
        RestorationState.clear()
    }

    // MARK: - Scroll restoration

    @MainActor
    @Test func saveAndLoadScrollPosition() {
        RestorationState.clear()

        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        let conn = coordinator.connection
        conn.sessionStore.activeSessionId = "s1"
        conn.scrollAnchorItemId = "msg-77"
        conn.scrollWasNearBottom = false

        let nav = AppNavigation()
        RestorationState.save(from: conn, coordinator: coordinator, navigation: nav)

        let loaded = RestorationState.load()
        #expect(loaded != nil)
        #expect(loaded?.scrollAnchorItemId == "msg-77")
        #expect(loaded?.wasNearBottom == false)

        RestorationState.clear()
    }

    @MainActor
    @Test func scrollNearBottomSavedCorrectly() {
        RestorationState.clear()

        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        let conn = coordinator.connection
        conn.sessionStore.activeSessionId = "s1"
        conn.scrollAnchorItemId = "msg-99"
        conn.scrollWasNearBottom = true

        let nav = AppNavigation()
        RestorationState.save(from: conn, coordinator: coordinator, navigation: nav)

        let loaded = RestorationState.load()
        #expect(loaded?.wasNearBottom == true)
        #expect(loaded?.scrollAnchorItemId == "msg-99")

        RestorationState.clear()
    }

    @Test func v1StateWithoutScrollFieldsDecodesGracefully() throws {
        // Simulate a v1 state that lacks scroll and server fields
        let v1JSON = """
        {"version":1,"activeSessionId":"s1","selectedTab":"sessions","composerDraft":null,"timestamp":0}
        """
        let data = Data(v1JSON.utf8)
        let decoded = try JSONDecoder().decode(RestorationState.self, from: data)

        #expect(decoded.scrollAnchorItemId == nil)
        #expect(decoded.wasNearBottom == nil)
        #expect(decoded.activeServerId == nil)
    }

    // MARK: - Server ID restoration

    @MainActor
    @Test func savesAndRestoresServerId() {
        RestorationState.clear()

        let serverStore = ServerStore()
        let coordinator = ConnectionCoordinator(serverStore: serverStore)

        // Simulate switching to a server
        let creds = ServerCredentials(
            host: "studio.local", port: 7749, token: "sk_t", name: "studio",
            serverFingerprint: "sha256:test-restore"
        )
        if let server = PairedServer(from: creds) {
            coordinator.addServer(server, switchTo: true)
        }

        let nav = AppNavigation()
        RestorationState.save(from: coordinator.connection, coordinator: coordinator, navigation: nav)

        let loaded = RestorationState.load()
        #expect(loaded?.activeServerId == "sha256:test-restore")

        // Clean up
        RestorationState.clear()
        coordinator.removeServer(id: "sha256:test-restore")
    }
}

// MARK: - AppTab serialization

@Suite("AppTab serialization")
struct AppTabTests {

    @Test func rawStringRoundTrips() {
        #expect(AppTab.workspaces.rawString == "workspaces")
        #expect(AppTab.settings.rawString == "settings")
    }

    @Test func initFromRawString() {
        #expect(AppTab(rawString: "workspaces") == .workspaces)
        #expect(AppTab(rawString: "sessions") == .workspaces)
        #expect(AppTab(rawString: "settings") == .settings)
    }

    @Test func unknownRawStringDefaultsToWorkspaces() {
        #expect(AppTab(rawString: "unknown") == .workspaces)
        #expect(AppTab(rawString: "") == .workspaces)
    }
}
