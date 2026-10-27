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
            #expect(classification.outcome == .cancelled)
            #expect(classification.errorKind == .cancelled)
        }
    }

    @Test func userVisibleFailuresKeepOutcomeError() {
        let decode = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "bad queue payload")
        )
        let cases: [(Error, TelemetryTag.ErrorKind)] = [
            (CommandRequestError.timeout(command: "get_queue"), .timeout),
            (CommandRequestError.rejected(command: "get_queue", reason: "refused"), .other),
            (WebSocketError.notConnected, .notConnected),
            (WebSocketError.sendTimeout, .timeout),
            (WebSocketError.encodingFailed, .other),
            (URLError(.timedOut), .timeout),
            (URLError(.networkConnectionLost), .network),
            (URLError(.badURL), .urlError),
            (decode, .decode),
            (ClassificationProbeError(), .other),
        ]
        for (error, kind) in cases {
            let classification = CommandMetricClassification.recorded(for: error)
            #expect(classification.outcome == .error)
            #expect(classification.errorKind == kind)
        }
    }

    @Test func queueSyncUsesCancelledStatusForSupersededRefresh() {
        let cancelled = MessageSender.queueSyncEvent(
            durationMs: 12, transport: .lan, phase: .initial, error: CancellationError()
        )
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.errorKind == .cancelled)
        #expect(cancelled.phase == .initial)

        // The coordinator's retry pass is the catalog's `deferred` phase.
        let timedOut = MessageSender.queueSyncEvent(
            durationMs: 3000,
            transport: .paired,
            phase: .retry,
            error: CommandRequestError.timeout(command: "get_queue")
        )
        #expect(timedOut.status == .error)
        #expect(timedOut.errorKind == .timeout)
        #expect(timedOut.phase == .deferred)

        let ok = MessageSender.queueSyncEvent(durationMs: 8, transport: .lan, phase: .initial, error: nil)
        #expect(ok.status == .ok)
        #expect(ok.errorKind == nil)
    }

    @Test func roundtripRecordsCancellationAsCancelled() async {
        let sender = MessageSender()
        sender._sendMessageForTesting = { _ in
            sender.commands.failAllCommands(error: CancellationError())
        }

        let command = await recordedCommand(sender) {
            _ = try await sender.sendCommandAwaitingResult(
                command: "get_queue",
                timeout: .seconds(2)
            ) { requestId in
                .getQueue(requestId: requestId)
            }
        }

        #expect(command?.tagValues["status"] == "cancelled")
        #expect(command?.tagValues["error_kind"] == "cancelled")
        #expect(command?.tagValues["command"] == "get_queue")
    }

    @Test func roundtripRecordsTimeoutAndRejectionAsErrors() async {
        let timeoutSender = MessageSender()
        timeoutSender._sendMessageForTesting = { _ in }
        let timeout = await recordedCommand(timeoutSender) {
            _ = try await timeoutSender.sendCommandAwaitingResult(
                command: "get_queue",
                timeout: .milliseconds(40)
            ) { requestId in
                .getQueue(requestId: requestId)
            }
        }
        #expect(timeout?.tagValues["status"] == "error")
        #expect(timeout?.tagValues["error_kind"] == "timeout")
        #expect(timeout?.fieldValues["roundtrip_ms"] != nil)

        let rejectedSender = MessageSender()
        rejectedSender._sendMessageForTesting = { message in
            guard case .getQueue(let requestId) = message, let requestId else { return }
            _ = rejectedSender.commands.resolveCommandResult(
                command: "get_queue",
                requestId: requestId,
                success: false,
                data: nil,
                error: "refused"
            )
        }
        let rejected = await recordedCommand(rejectedSender) {
            _ = try await rejectedSender.sendCommandAwaitingResult(command: "get_queue") { requestId in
                .getQueue(requestId: requestId)
            }
        }
        #expect(rejected?.tagValues["status"] == "error")
        #expect(rejected?.tagValues["error_kind"] == "other")
    }

    /// A send that fails has no round trip: one event with the send latency and the failure.
    @Test func sendFailureRecordsOneEventWithoutARoundtrip() async {
        let sender = MessageSender()
        sender._sendMessageForTesting = { _ in throw WebSocketError.notConnected }

        let capture = TelemetryCapture()
        await capture.run {
            await #expect(throws: WebSocketError.self) {
                _ = try await sender.sendCommandAwaitingResult(command: "get_queue") { requestId in
                    .getQueue(requestId: requestId)
                }
            }
        }

        let commands = capture.events(named: "app.command")
        #expect(commands.count == 1)
        #expect(commands.first?.tags?["status"] == "error")
        #expect(commands.first?.tags?["error_kind"] == "not_connected")
        #expect(commands.first?.fields["send_ms"] != nil)
        #expect(commands.first?.fields["roundtrip_ms"] == nil)
    }

    @Test func transportReplacementRecordsCancelledRoundtrip() async {
        let sender = MessageSender()
        sender._sendMessageForTesting = { _ in
            sender.advanceTransportGeneration()
        }

        let command = await recordedCommand(sender) {
            _ = try await sender.sendCommandAwaitingResult(
                command: "get_queue",
                timeout: .seconds(2)
            ) { requestId in
                .getQueue(requestId: requestId)
            }
        }

        #expect(command?.tagValues["status"] == "cancelled")
        #expect(command?.tagValues["error_kind"] == "cancelled")
    }

    /// The last `app.command` event recorded while `body` runs, rebuilt as the
    /// generated struct's field and tag values.
    private func recordedCommand(
        _ sender: MessageSender,
        _ body: () async throws -> Void
    ) async -> RecordedCommand? {
        let capture = TelemetryCapture()
        await capture.run {
            do {
                try await body()
            } catch {
                // The send path records before rethrowing.
            }
        }
        return capture.events(named: "app.command").last.map {
            RecordedCommand(fieldValues: $0.fields, tagValues: $0.tags ?? [:])
        }
    }
}

private struct RecordedCommand {
    let fieldValues: [String: Double]
    let tagValues: [String: String]
}

private struct ClassificationProbeError: Error {}
