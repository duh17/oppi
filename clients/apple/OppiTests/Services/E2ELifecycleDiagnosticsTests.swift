import Testing
@testable import Oppi

@Suite("E2E lifecycle diagnostics")
@MainActor
struct E2ELifecycleDiagnosticsTests {
    @Test func recordsCompletedHandlersWithBoundedDurations() {
        let diagnostics = E2ELifecycleDiagnostics()

        diagnostics.record(phase: "inactive", step: "end")
        diagnostics.record(phase: "background", step: "begin")
        diagnostics.record(phase: "background", step: "end")
        #expect(diagnostics.backgroundCompleted == 0)
        diagnostics.complete(phase: "background", durationMs: 17)
        diagnostics.record(phase: "active", step: "begin")
        diagnostics.record(phase: "active", step: "end")
        diagnostics.complete(phase: "active", durationMs: 70_000)

        #expect(diagnostics.sequence == 5)
        #expect(diagnostics.backgroundCompleted == 1)
        #expect(diagnostics.activeCompleted == 1)
        #expect(diagnostics.backgroundDurationMs == 17)
        #expect(diagnostics.activeDurationMs == 60_000)
        #expect(
            diagnostics.accessibilityValue == "seq=5 phase=active step=end bgCompleted=1 activeCompleted=1 bgMs=17 activeMs=60000"
        )
    }
}
