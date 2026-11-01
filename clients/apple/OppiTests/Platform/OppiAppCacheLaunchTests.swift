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
}
