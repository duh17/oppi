import Testing
@testable import Oppi

@MainActor
@Suite("ChatTimelinePerf suspension ceiling")
struct ChatTimelinerPerfSuspensionCeilingTests {
    @Test func suspensionCeilingIsReasonable() {
        // The ceiling must be high enough to pass through real stalls (seconds)
        // but low enough to reject process-suspension artifacts (10-20s).
        #expect(ChatTimelinePerf.suspensionCeilingMs >= 3_000)
        #expect(ChatTimelinePerf.suspensionCeilingMs <= 10_000)
    }

    @Test func guardrailApplyThresholdIsBelowSuspensionCeiling() {
        // The guardrail threshold must always be below the ceiling,
        // otherwise every guardrail breach would also be discarded.
        #expect(ChatTimelinePerf.suspensionCeilingMs > 250)
    }
}
