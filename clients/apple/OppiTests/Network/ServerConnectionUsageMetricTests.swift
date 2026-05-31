import Foundation
import Testing
@testable import Oppi

@Suite("ServerConnection Usage Metrics")
@MainActor
struct ServerConnectionUsageMetricTests {
    @Test func skipsEmptyUsageSnapshot() {
        let connection = ServerConnection()
        let session = makeTestSession(id: "s-usage", status: .ready)
        let snapshot = connection.sessionUsageMetricSnapshot(from: session)

        #expect(!connection.shouldEmitSessionUsageMetrics(
            for: session,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 100)
        ))
    }

    @Test func debouncesReadyUsageSnapshots() {
        let connection = ServerConnection()
        var session = makeTestSession(id: "s-usage", status: .ready, messageCount: 10)
        session.tokens = TokenUsage(input: 100, output: 20)

        let firstSnapshot = connection.sessionUsageMetricSnapshot(from: session)
        let firstDate = Date(timeIntervalSince1970: 100)
        #expect(connection.shouldEmitSessionUsageMetrics(
            for: session,
            snapshot: firstSnapshot,
            now: firstDate
        ))

        connection.sessionUsageMetricSnapshots[session.id] = firstSnapshot
        connection.sessionUsageMetricLastEmittedAt[session.id] = firstDate

        session.messageCount = 11
        let changedSnapshot = connection.sessionUsageMetricSnapshot(from: session)
        #expect(!connection.shouldEmitSessionUsageMetrics(
            for: session,
            snapshot: changedSnapshot,
            now: firstDate.addingTimeInterval(30)
        ))
        #expect(connection.shouldEmitSessionUsageMetrics(
            for: session,
            snapshot: changedSnapshot,
            now: firstDate.addingTimeInterval(61)
        ))
    }

    @Test func emitsStoppedUsageSnapshotWithoutDebounce() {
        let connection = ServerConnection()
        var session = makeTestSession(id: "s-usage", status: .ready, messageCount: 10)
        session.tokens = TokenUsage(input: 100, output: 20)
        let firstSnapshot = connection.sessionUsageMetricSnapshot(from: session)
        let firstDate = Date(timeIntervalSince1970: 100)
        connection.sessionUsageMetricSnapshots[session.id] = firstSnapshot
        connection.sessionUsageMetricLastEmittedAt[session.id] = firstDate

        session.status = .stopped
        session.messageCount = 11
        let stoppedSnapshot = connection.sessionUsageMetricSnapshot(from: session)

        #expect(connection.shouldEmitSessionUsageMetrics(
            for: session,
            snapshot: stoppedSnapshot,
            now: firstDate.addingTimeInterval(5)
        ))
    }
}
