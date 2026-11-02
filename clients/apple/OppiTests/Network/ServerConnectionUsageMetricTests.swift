import Foundation
import Testing
@testable import Oppi

@Suite("Session Usage Metrics")
@MainActor
struct ServerConnectionUsageMetricTests {
    @Test func skipsEmptyUsageSnapshot() {
        let reporter = SessionUsageMetricsReporter()
        let session = makeTestSession(id: "s-usage", status: .ready)
        let snapshot = SessionUsageMetricsReporter.snapshot(from: session)

        #expect(!reporter.shouldEmit(
            for: session,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 100)
        ))
    }

    @Test func debouncesReadyUsageSnapshots() {
        let reporter = SessionUsageMetricsReporter()
        var session = makeTestSession(id: "s-usage", status: .ready, messageCount: 10)
        session.tokens = TokenUsage(input: 100, output: 20)

        let firstSnapshot = SessionUsageMetricsReporter.snapshot(from: session)
        #expect(reporter.shouldEmit(
            for: session,
            snapshot: firstSnapshot,
            now: Date(timeIntervalSince1970: 100)
        ))

        let firstDate = Date()
        reporter.reportIfNeeded(session)

        session.messageCount = 11
        let changedSnapshot = SessionUsageMetricsReporter.snapshot(from: session)
        #expect(!reporter.shouldEmit(
            for: session,
            snapshot: changedSnapshot,
            now: firstDate.addingTimeInterval(30)
        ))
        #expect(reporter.shouldEmit(
            for: session,
            snapshot: changedSnapshot,
            now: firstDate.addingTimeInterval(61)
        ))
    }

    @Test func emitsStoppedUsageSnapshotWithoutDebounce() {
        let reporter = SessionUsageMetricsReporter()
        var session = makeTestSession(id: "s-usage", status: .ready, messageCount: 10)
        session.tokens = TokenUsage(input: 100, output: 20)
        let firstDate = Date()
        reporter.reportIfNeeded(session)

        session.status = .stopped
        session.messageCount = 11
        let stoppedSnapshot = SessionUsageMetricsReporter.snapshot(from: session)

        #expect(reporter.shouldEmit(
            for: session,
            snapshot: stoppedSnapshot,
            now: firstDate.addingTimeInterval(5)
        ))
    }
}
