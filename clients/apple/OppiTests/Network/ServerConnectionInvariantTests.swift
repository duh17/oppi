import Foundation
import Testing
@testable import Oppi

@Suite("ServerConnection — Invariants")
@MainActor
struct ServerConnectionInvariantTests {

    @Test func stopLifecycleEventsNeverMutateLocalStatus() async {
        for sequence in stopLifecycleSequences(length: 4) {
            let scenario = await ServerConnectionScenario(sessionId: "s-stop")
                .givenStoredSession(status: .busy)

            for event in sequence {
                scenario.whenHandle(event.message, sessionId: "s-stop")
                #expect(
                    scenario.firstSessionStatus() == .busy,
                    "stop_requested/stop_confirmed/stop_failed carry no status; sequence=\(sequence.map(\.label).joined(separator: ","))"
                )
            }
        }
    }

    @Test func nonActiveSessionMessagesDoNotMutateLocalState() async {
        let scenario = await ServerConnectionScenario(sessionId: "s-active")
            .givenStoredSession(id: "s-active", status: .ready)

        let beforeStatus = scenario.firstSessionStatus()
        let beforeRenderVersion = scenario.reducer.renderVersion

        for message in deterministicForeignSessionMessages() {
            scenario.whenHandle(message, sessionId: "s-foreign")
        }

        #expect(scenario.firstSessionStatus() == beforeStatus)
        #expect(scenario.reducer.renderVersion == beforeRenderVersion)
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

private func deterministicForeignSessionMessages() -> [ServerMessage] {
    return [
        .agentStart,
        .textDelta(delta: "ignored"),
        .toolStart(tool: "bash", args: ["command": .string("pwd")], toolCallId: "t-1", callSegments: nil),
        .toolOutput(output: "x", isError: false, toolCallId: "t-1", mode: .append, truncated: false, totalBytes: nil, details: nil),
        .toolEnd(tool: "bash", toolCallId: "t-1", details: nil, isError: false, resultSegments: nil),
        .sessionEnded(reason: "done"),
    ]
}
