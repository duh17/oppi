import Foundation
import Testing
@testable import Oppi

@Suite("Command metric classification")
@MainActor
struct CommandMetricClassificationTests {

    @Test func cancellationIsNotAUserVisibleFailure() {
        let cases: [Error] = [
            CancellationError(),
            URLError(.cancelled),
            TurnSendUnconfirmedError(
                command: "get_queue",
                clientTurnId: "turn",
                underlying: CancellationError()
            ),
        ]
        for error in cases {
            let classification = CommandMetricClassification.recorded(for: error)
            #expect(classification.outcome == "cancelled")
            #expect(classification.errorKind == "cancelled")
            #expect(classification.outcome != "error")
        }
    }

    @Test func userVisibleFailuresKeepOutcomeError() {
        let decode = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "bad queue payload")
        )
        let cases: [(Error, String)] = [
            (CommandRequestError.timeout(command: "get_queue"), "timeout"),
            (CommandRequestError.rejected(command: "get_queue", reason: "refused"), "other"),
            (WebSocketError.notConnected, "not_connected"),
            (WebSocketError.sendTimeout, "timeout"),
            (WebSocketError.encodingFailed, "other"),
            (URLError(.timedOut), "timeout"),
            (URLError(.networkConnectionLost), "network"),
            (URLError(.badURL), "other"),
            (decode, "decode"),
            (ClassificationProbeError(), "other"),
        ]
        for (error, kind) in cases {
            let classification = CommandMetricClassification.recorded(for: error)
            #expect(classification.outcome == "error")
            #expect(classification.errorKind == kind)
        }
    }

    @Test func queueSyncTagsUseCancelledStatusForSupersededRefresh() {
        let cancelled = MessageSender.queueSyncMetricTags(
            transport: "lan",
            phase: "initial",
            error: CancellationError()
        )
        #expect(cancelled["status"] == "cancelled")
        #expect(cancelled["error_kind"] == "cancelled")
        #expect(cancelled["phase"] == "initial")

        let timedOut = MessageSender.queueSyncMetricTags(
            transport: "paired",
            phase: "retry",
            error: CommandRequestError.timeout(command: "get_queue")
        )
        #expect(timedOut["status"] == "error")
        #expect(timedOut["error_kind"] == "timeout")

        let ok = MessageSender.queueSyncMetricTags(transport: "lan", phase: "initial", error: nil)
        #expect(ok["status"] == "ok")
        #expect(ok["error_kind"] == nil)
    }

    @Test func roundtripSeamRecordsCancellationAsCancelled() async {
        let sender = MessageSender()
        var recorded: [(ChatMetricName, [String: String])] = []
        sender._recordCommandMetricForTesting = { metric, tags in
            recorded.append((metric, tags))
        }
        sender._sendMessageForTesting = { _ in
            sender.commands.failAllCommands(error: CancellationError())
        }

        await #expect(throws: CancellationError.self) {
            _ = try await sender.sendCommandAwaitingResult(
                command: "get_queue",
                timeout: .seconds(2)
            ) { requestId in
                .getQueue(requestId: requestId)
            }
        }

        let roundtrip = recorded.filter { $0.0 == .commandRoundtripMs }
        #expect(roundtrip.count == 1)
        #expect(roundtrip.first?.1["outcome"] == "cancelled")
        #expect(roundtrip.first?.1["error_kind"] == "cancelled")
        #expect(roundtrip.first?.1["command"] == "get_queue")
    }

    @Test func roundtripSeamRecordsTimeoutAndRejectionAsErrors() async {
        let timeout = await recordedRoundtrip { sender in
            sender._sendMessageForTesting = { _ in }
            _ = try await sender.sendCommandAwaitingResult(
                command: "get_queue",
                timeout: .milliseconds(40)
            ) { requestId in
                .getQueue(requestId: requestId)
            }
        }
        #expect(timeout?["outcome"] == "error")
        #expect(timeout?["error_kind"] == "timeout")

        let rejected = await recordedRoundtrip { sender in
            sender._sendMessageForTesting = { message in
                guard case .getQueue(let requestId) = message, let requestId else { return }
                _ = sender.commands.resolveCommandResult(
                    command: "get_queue",
                    requestId: requestId,
                    success: false,
                    data: nil,
                    error: "refused"
                )
            }
            _ = try await sender.sendCommandAwaitingResult(command: "get_queue") { requestId in
                .getQueue(requestId: requestId)
            }
        }
        #expect(rejected?["outcome"] == "error")
        #expect(rejected?["error_kind"] == "other")
    }

    @Test func sendFailureSeamRecordsNotConnectedOnBothMetrics() async {
        let sender = MessageSender()
        var recorded: [(ChatMetricName, [String: String])] = []
        sender._recordCommandMetricForTesting = { metric, tags in
            recorded.append((metric, tags))
        }
        sender._sendMessageForTesting = { _ in throw WebSocketError.notConnected }

        await #expect(throws: WebSocketError.self) {
            _ = try await sender.sendCommandAwaitingResult(command: "get_queue") { requestId in
                .getQueue(requestId: requestId)
            }
        }

        let outcomes = recorded.map { ($0.0, $0.1["outcome"], $0.1["error_kind"]) }
        #expect(outcomes.contains { $0.0 == .commandSendMs && $0.1 == "error" && $0.2 == "not_connected" })
        #expect(outcomes.contains { $0.0 == .commandRoundtripMs && $0.1 == "error" && $0.2 == "not_connected" })
    }

    @Test func transportReplacementRecordsCancelledRoundtrip() async {
        let sender = MessageSender()
        var recorded: [(ChatMetricName, [String: String])] = []
        sender._recordCommandMetricForTesting = { metric, tags in
            recorded.append((metric, tags))
        }
        sender._sendMessageForTesting = { _ in
            sender.advanceTransportGeneration()
        }

        await #expect(throws: CancellationError.self) {
            _ = try await sender.sendCommandAwaitingResult(
                command: "get_queue",
                timeout: .seconds(2)
            ) { requestId in
                .getQueue(requestId: requestId)
            }
        }

        let roundtrip = recorded.filter { $0.0 == .commandRoundtripMs }
        #expect(roundtrip.count == 1)
        #expect(roundtrip.first?.1["outcome"] == "cancelled")
        #expect(roundtrip.first?.1["error_kind"] == "cancelled")
    }

    private func recordedRoundtrip(
        _ body: (MessageSender) async throws -> Void
    ) async -> [String: String]? {
        let sender = MessageSender()
        var recorded: [(ChatMetricName, [String: String])] = []
        sender._recordCommandMetricForTesting = { metric, tags in
            recorded.append((metric, tags))
        }
        do {
            try await body(sender)
        } catch {
            // The seam records before rethrowing.
        }
        return recorded.last { $0.0 == .commandRoundtripMs }?.1
    }
}

private struct ClassificationProbeError: Error {}
