import Foundation
import Testing
@testable import Oppi

@Suite("OppiApp Launch Cache")
struct OppiAppCacheLaunchTests {
    @Test func partialLaunchRefreshIsNotReportedAsOnlineSuccess() {
        let outcome = LaunchRefreshTelemetryOutcome.resolve(
            selectedServerReady: true,
            workspaceFailed: true,
            sessionFailed: false
        )

        #expect(outcome.overall == "online_refresh_partial")
        #expect(outcome.workspace == "failure")
        #expect(outcome.session == "success")
    }

    @Test func launchRefreshTelemetrySeparatesUnattemptedOfflineLists() {
        let outcome = LaunchRefreshTelemetryOutcome.resolve(
            selectedServerReady: false,
            workspaceFailed: false,
            sessionFailed: false
        )

        #expect(outcome.overall == "offline_cache_only")
        #expect(outcome.workspace == "not_attempted")
        #expect(outcome.session == "not_attempted")
    }

    @Test func legacyUnscopedSessionCacheIsNotAssignedToSoleServer() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "oppi-app-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let legacySessions = [makeTestSession(id: "legacy-session", workspaceId: "w-legacy")]
        let data = try JSONEncoder().encode(legacySessions)
        try data.write(to: root.appending(path: "session-list.json"), options: .atomic)

        let cache = TimelineCache(rootURL: root)
        let loaded = await OppiApp().loadLaunchSessionCache(
            cache: cache,
            serverId: "sha256:solo"
        )
        let persisted = await cache.loadSessionList(serverId: "sha256:solo")

        #expect(loaded == nil)
        #expect(persisted == nil)
    }
}
