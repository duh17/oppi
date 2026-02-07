import Testing
import Foundation
@testable import PiRemote

@Suite("RestorationState")
struct RestorationStateTests {

    // MARK: - Codable round-trip

    @Test func encodeDecodeRoundTrip() throws {
        let state = RestorationState(
            version: RestorationState.schemaVersion,
            activeSessionId: "s1",
            selectedTab: "sessions",
            composerDraft: "draft text",
            timestamp: Date()
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RestorationState.self, from: data)

        #expect(decoded.version == state.version)
        #expect(decoded.activeSessionId == "s1")
        #expect(decoded.selectedTab == "sessions")
        #expect(decoded.composerDraft == "draft text")
    }

    @Test func encodeDecodeNilOptionals() throws {
        let state = RestorationState(
            version: 1,
            activeSessionId: nil,
            selectedTab: "settings",
            composerDraft: nil,
            timestamp: Date()
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RestorationState.self, from: data)

        #expect(decoded.activeSessionId == nil)
        #expect(decoded.composerDraft == nil)
        #expect(decoded.selectedTab == "settings")
    }

    // MARK: - Save and Load

    @MainActor
    @Test func saveAndLoad() {
        // Clean up first
        RestorationState.clear()

        let conn = ServerConnection()
        conn.sessionStore.activeSessionId = "s1"
        conn.composerDraft = "test draft"

        let nav = AppNavigation()
        nav.selectedTab = .sessions

        RestorationState.save(from: conn, navigation: nav)

        let loaded = RestorationState.load()
        #expect(loaded != nil)
        #expect(loaded?.activeSessionId == "s1")
        #expect(loaded?.composerDraft == "test draft")
        #expect(loaded?.selectedTab == "sessions")

        // Clean up
        RestorationState.clear()
    }

    // MARK: - Freshness

    @Test func staleStateReturnsNil() {
        // Save a state with a very old timestamp
        let old = RestorationState(
            version: RestorationState.schemaVersion,
            activeSessionId: "s1",
            selectedTab: "sessions",
            composerDraft: nil,
            timestamp: Date().addingTimeInterval(-7200) // 2 hours ago
        )

        if let data = try? JSONEncoder().encode(old) {
            UserDefaults.standard.set(data, forKey: RestorationState.key)
        }

        let loaded = RestorationState.load()
        #expect(loaded == nil, "State older than 1 hour should return nil")

        // Clean up
        RestorationState.clear()
    }

    // MARK: - Schema version mismatch

    @Test func wrongVersionReturnsNil() {
        let wrong = RestorationState(
            version: 999, // future version
            activeSessionId: "s1",
            selectedTab: "sessions",
            composerDraft: nil,
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
        let conn = ServerConnection()
        let nav = AppNavigation()
        RestorationState.save(from: conn, navigation: nav)

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
}

// MARK: - AppTab serialization

@Suite("AppTab serialization")
struct AppTabTests {

    @Test func rawStringRoundTrips() {
        #expect(AppTab.sessions.rawString == "sessions")
        #expect(AppTab.settings.rawString == "settings")
    }

    @Test func initFromRawString() {
        #expect(AppTab(rawString: "sessions") == .sessions)
        #expect(AppTab(rawString: "settings") == .settings)
    }

    @Test func unknownRawStringDefaultsToSessions() {
        #expect(AppTab(rawString: "unknown") == .sessions)
        #expect(AppTab(rawString: "") == .sessions)
    }
}
