import Foundation
import Testing
@testable import Oppi

@Suite("ServerConnection — Invariants")
struct ServerConnectionInvariantTests {

    @MainActor
    @Test func stopLifecycleFollowsStateMachineAcrossDeterministicSequences() {
        for sequence in stopLifecycleSequences(length: 4) {
            let scenario = ServerConnectionScenario(sessionId: "s-stop")
                .givenStoredSession(status: .busy)

            var expected: SessionStatus = .busy

            for event in sequence {
                scenario.whenHandle(event.message, sessionId: "s-stop")
                expected = reduceStopLifecycleModel(current: expected, event: event)
                #expect(
                    scenario.firstSessionStatus() == expected,
                    "sequence=\(sequence.map(\.label).joined(separator: ","))"
                )
            }
        }
    }

    @MainActor
    @Test func nonActiveSessionMessagesDoNotMutateLocalState() {
        let scenario = ServerConnectionScenario(sessionId: "s-active")
            .givenStoredSession(id: "s-active", status: .ready)

        let beforeStatus = scenario.firstSessionStatus()
        let beforeRenderVersion = scenario.connection.reducer.renderVersion
        let beforePermissionCount = scenario.connection.permissionStore.pending.count

        for message in deterministicForeignSessionMessages() {
            scenario.whenHandle(message, sessionId: "s-foreign")
        }

        #expect(scenario.firstSessionStatus() == beforeStatus)
        #expect(scenario.connection.reducer.renderVersion == beforeRenderVersion)
        #expect(scenario.connection.permissionStore.pending.count == beforePermissionCount)
    }

    @MainActor
    @Test func liveActivityFilterSkipsDeltaOnlyFlushes() {
        let connection = ServerConnection()
        let events: [AgentEvent] = [
            .textDelta(sessionId: "s1", delta: "a"),
            .thinkingDelta(sessionId: "s1", delta: "b"),
            .toolOutput(sessionId: "s1", toolEventId: "t1", output: "chunk", isError: false),
            .messageEnd(sessionId: "s1", content: "done"),
        ]

        #expect(connection.liveActivityRelevantEvents(from: events).isEmpty)
    }

    @MainActor
    @Test func liveActivityFilterKeepsLifecycleEventsOnly() {
        let connection = ServerConnection()
        let permission = PermissionRequest(
            id: "p1",
            sessionId: "s1",
            tool: "bash",
            input: [:],
            displaySummary: "bash: pwd",
            reason: "Need permission",
            timeoutAt: Date().addingTimeInterval(60)
        )
        let events: [AgentEvent] = [
            .textDelta(sessionId: "s1", delta: "ignore"),
            .agentStart(sessionId: "s1"),
            .toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]),
            .toolOutput(sessionId: "s1", toolEventId: "t1", output: "chunk", isError: false),
            .permissionRequest(permission),
            .error(sessionId: "s1", message: "Retrying (attempt 1/3)"),
            .error(sessionId: "s1", message: "boom"),
            .sessionEnded(sessionId: "s1", reason: "done"),
        ]

        let relevant = connection.liveActivityRelevantEvents(from: events)
        #expect(relevant.map(\.typeLabel) == [
            "agentStart",
            "toolStart",
            "permissionRequest",
            "error",
            "sessionEnded",
        ])
    }
}

private enum StopLifecycleEvent: CaseIterable {
    case requested
    case confirmed
    case failed

    var label: String {
        switch self {
        case .requested: return "requested"
        case .confirmed: return "confirmed"
        case .failed: return "failed"
        }
    }

    var message: ServerMessage {
        switch self {
        case .requested:
            return .stopRequested(source: .user, reason: "Stopping")
        case .confirmed:
            return .stopConfirmed(source: .user, reason: "Done")
        case .failed:
            return .stopFailed(source: .user, reason: "Nope")
        }
    }
}

private func stopLifecycleSequences(length: Int) -> [[StopLifecycleEvent]] {
    guard length > 0 else { return [[]] }

    var results: [[StopLifecycleEvent]] = [[]]
    for _ in 0..<length {
        var next: [[StopLifecycleEvent]] = []
        next.reserveCapacity(results.count * StopLifecycleEvent.allCases.count)
        for prefix in results {
            for event in StopLifecycleEvent.allCases {
                next.append(prefix + [event])
            }
        }
        results = next
    }
    return results
}

private func reduceStopLifecycleModel(current: SessionStatus, event: StopLifecycleEvent) -> SessionStatus {
    switch event {
    case .requested:
        return .stopping
    case .confirmed:
        return current == .stopping ? .ready : current
    case .failed:
        return current == .stopping ? .busy : current
    }
}

private func deterministicForeignSessionMessages() -> [ServerMessage] {
    let perm = PermissionRequest(
        id: "p-foreign",
        sessionId: "s-foreign",
        tool: "bash",
        input: [:],
        displaySummary: "bash: ls",
        reason: "Need permission",
        timeoutAt: Date().addingTimeInterval(60)
    )

    return [
        .agentStart,
        .textDelta(delta: "ignored"),
        .toolStart(tool: "bash", args: ["command": .string("pwd")], toolCallId: "t-1", callSegments: nil),
        .toolOutput(output: "x", isError: false, toolCallId: "t-1", mode: .append, truncated: false, totalBytes: nil),
        .toolEnd(tool: "bash", toolCallId: "t-1", details: nil, isError: false, resultSegments: nil),
        .permissionRequest(perm),
        .sessionEnded(reason: "done"),
    ]
}
