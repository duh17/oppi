#if DEBUG
import Testing
@testable import Oppi

@Suite("Harness frame interval recorder")
struct HarnessFrameIntervalRecorderTests {
    @Test func recordsIntervalsBelowDiscontinuityInFilteredAndRawStats() {
        var recorder = HarnessFrameIntervalRecorder()
        recorder.record(16)
        recorder.record(33)
        recorder.record(50)

        let snapshot = recorder.snapshot()
        #expect(snapshot.sampleCount == 3)
        #expect(snapshot.maxIntervalMs == 50)
        #expect(snapshot.filteredMaxIntervalMs == 50)
        #expect(snapshot.over50MsCount == 1)
        #expect(snapshot.filteredOver50MsCount == 1)
        #expect(snapshot.p95IntervalMs <= 50)
        #expect(snapshot.p95IntervalMs >= 16)
    }

    @Test func keepsRawMaxAtDiscontinuityThresholdWithoutFilteredPollution() {
        var recorder = HarnessFrameIntervalRecorder()
        recorder.record(16)
        recorder.record(HarnessFrameIntervalRecorder.discontinuityMs)

        let snapshot = recorder.snapshot()
        #expect(snapshot.maxIntervalMs == 120)
        #expect(snapshot.filteredMaxIntervalMs == 16)
        #expect(snapshot.sampleCount == 1)
        #expect(snapshot.p95IntervalMs == 16)
        #expect(snapshot.p99IntervalMs == 16)
        #expect(snapshot.over50MsCount == 1)
        #expect(snapshot.filteredOver50MsCount == 0)
    }

    @Test func keepsRawMaxAboveDiscontinuityWithoutRaisingFilteredP95() {
        var recorder = HarnessFrameIntervalRecorder()
        recorder.record(16)
        recorder.record(18)
        recorder.record(200)

        let snapshot = recorder.snapshot()
        #expect(snapshot.maxIntervalMs == 200)
        #expect(snapshot.filteredMaxIntervalMs == 18)
        #expect(snapshot.sampleCount == 2)
        #expect(snapshot.p95IntervalMs <= 18)
        #expect(snapshot.p99IntervalMs <= 18)
        #expect(snapshot.over50MsCount == 1)
        #expect(snapshot.filteredOver50MsCount == 0)
        #expect(snapshot.over50MsPercent == 0)
    }
}
#endif
