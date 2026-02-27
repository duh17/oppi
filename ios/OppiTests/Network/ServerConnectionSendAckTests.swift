import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Send ACK")
struct ServerConnectionSendAckTests {

    @MainActor
    @Test func sendAckSuccessForPromptSteerAndFollowUp() async throws {
        for command in EventFlowAckCommand.allCases {
            let conn = makeEventFlowAckTestConnection()

            var sentRequestId: String?
            conn._sendMessageForTesting = { message in
                guard let sent = extractEventFlowAckRequest(from: message) else {
                    Issue.record("Expected prompt/steer/follow_up message")
                    return
                }
                #expect(sent.command == command.rawValue)
                #expect(sent.clientTurnId != nil)
                sentRequestId = sent.requestId

                if let requestId = sent.requestId {
                    conn.handleServerMessage(
                        .commandResult(
                            command: sent.command,
                            requestId: requestId,
                            success: true,
                            data: nil,
                            error: nil
                        ),
                        sessionId: "s1"
                    )
                }
            }

            try await command.send(using: conn, text: "hello")
            #expect(sentRequestId != nil, "\(command.rawValue) should include requestId")
        }
    }

    @MainActor
    @Test func sendAckUsesTurnAckStages() async throws {
        let conn = makeEventFlowAckTestConnection()

        conn._sendMessageForTesting = { message in
            guard let sent = extractEventFlowAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId else {
                Issue.record("Expected turn command with clientTurnId")
                return
            }

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .accepted,
                    requestId: sent.requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: sent.requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        try await conn.sendPrompt("hello")
    }

    @MainActor
    @Test func sendAckStageCallbackReceivesProgressStages() async throws {
        let conn = makeEventFlowAckTestConnection()

        let stageRecorder = EventFlowAckStageRecorder()

        conn._sendMessageForTesting = { message in
            guard let sent = extractEventFlowAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId,
                  let requestId = sent.requestId else {
                Issue.record("Expected turn command with requestId/clientTurnId")
                return
            }

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .accepted,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .started,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        try await conn.sendPrompt("hello", onAckStage: { stage in
            Task { await stageRecorder.record(stage) }
        })

        #expect(await waitForTestCondition(timeoutMs: 500) {
            await stageRecorder.snapshot() == [.accepted, .dispatched, .started]
        })
    }

    @MainActor
    @Test func sendRetryReusesClientTurnId() async throws {
        let conn = makeEventFlowAckTestConnection()

        var attempt = 0
        var seenTurnIds: [String] = []
        var seenRequestIds: [String] = []

        conn._sendMessageForTesting = { message in
            guard let sent = extractEventFlowAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId,
                  let requestId = sent.requestId else {
                Issue.record("Expected turn command with requestId/clientTurnId")
                return
            }

            attempt += 1
            seenTurnIds.append(clientTurnId)
            seenRequestIds.append(requestId)

            if attempt == 1 {
                throw WebSocketError.notConnected
            }

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        try await conn.sendPrompt("hello")

        #expect(attempt == 2)
        #expect(seenTurnIds.count == 2)
        #expect(seenTurnIds[0] == seenTurnIds[1])
        #expect(seenRequestIds.count == 2)
        #expect(seenRequestIds[0] == seenRequestIds[1])
    }

    @MainActor
    @Test func sendPromptChurnAlwaysResolvesWithoutSilentDrop() async {
        let conn = makeEventFlowAckTestConnection(timeout: .milliseconds(160))

        var requestOrder: [String: Int] = [:]
        var attemptsByRequest: [String: Int] = [:]
        var turnIdsByRequest: [String: Set<String>] = [:]
        var nextOrder = 0

        conn._sendMessageForTesting = { message in
            guard let sent = extractEventFlowAckRequest(from: message),
                  let requestId = sent.requestId,
                  let clientTurnId = sent.clientTurnId else {
                Issue.record("Expected prompt/steer/follow_up with ids")
                return
            }

            if requestOrder[requestId] == nil {
                nextOrder += 1
                requestOrder[requestId] = nextOrder
            }

            attemptsByRequest[requestId, default: 0] += 1
            turnIdsByRequest[requestId, default: Set<String>()].insert(clientTurnId)

            let order = requestOrder[requestId] ?? 0
            let attempt = attemptsByRequest[requestId] ?? 0

            if order.isMultiple(of: 2) {
                throw WebSocketError.notConnected
            }

            if attempt == 1 {
                throw WebSocketError.notConnected
            }

            conn.handleServerMessage(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )
        }

        var delivered = 0
        var failed = 0

        for i in 0..<12 {
            do {
                try await conn.sendPrompt("msg-\(i)")
                delivered += 1
            } catch let error as WebSocketError {
                switch error {
                case .notConnected:
                    failed += 1
                default:
                    Issue.record("Unexpected WebSocket error: \(error)")
                }
            } catch let error as SendAckError {
                switch error {
                case .timeout:
                    failed += 1
                case .rejected:
                    Issue.record("Unexpected rejection during churn test: \(error)")
                }
            } catch {
                Issue.record("Unexpected churn send failure: \(error)")
            }
        }

        #expect(delivered + failed == 12)
        #expect(delivered == 6)
        #expect(failed == 6)
        #expect(requestOrder.count == 12)
        #expect(attemptsByRequest.values.allSatisfy { $0 == 2 })
        #expect(turnIdsByRequest.values.allSatisfy { $0.count == 1 })

        do {
            try await conn.sendPrompt("recovery")
            delivered += 1
        } catch {
            Issue.record("Expected recovery prompt to succeed, got \(error)")
        }

        #expect(delivered == 7)
    }

    @MainActor
    @Test func sendAckRejectedForPromptSteerAndFollowUp() async {
        for command in EventFlowAckCommand.allCases {
            let conn = makeEventFlowAckTestConnection()

            conn._sendMessageForTesting = { message in
                guard let sent = extractEventFlowAckRequest(from: message) else {
                    Issue.record("Expected prompt/steer/follow_up message")
                    return
                }
                #expect(sent.clientTurnId != nil)

                if let requestId = sent.requestId {
                    conn.handleServerMessage(
                        .commandResult(
                            command: sent.command,
                            requestId: requestId,
                            success: false,
                            data: nil,
                            error: "rejected-by-test"
                        ),
                        sessionId: "s1"
                    )
                }
            }

            do {
                try await command.send(using: conn, text: "hello")
                Issue.record("Expected \(command.rawValue) rejection")
            } catch let error as SendAckError {
                switch error {
                case .rejected(let rejectedCommand, let reason):
                    #expect(rejectedCommand == command.rawValue)
                    #expect(reason == "rejected-by-test")
                default:
                    Issue.record("Expected rejected error, got \(error)")
                }
            } catch {
                Issue.record("Expected SendAckError.rejected, got \(error)")
            }
        }
    }

    @MainActor
    @Test func sendAckTimeoutForPromptSteerAndFollowUp() async {
        for command in EventFlowAckCommand.allCases {
            let conn = makeEventFlowAckTestConnection(timeout: .milliseconds(120))

            conn._sendMessageForTesting = { _ in }

            do {
                try await command.send(using: conn, text: "hello")
                Issue.record("Expected \(command.rawValue) timeout")
            } catch let error as SendAckError {
                switch error {
                case .timeout(let timedOutCommand):
                    #expect(timedOutCommand == command.rawValue)
                default:
                    Issue.record("Expected timeout error, got \(error)")
                }
            } catch {
                Issue.record("Expected SendAckError.timeout, got \(error)")
            }
        }
    }

    // MARK: - Fork

    @MainActor
    @Test func forkFromTimelineEntryUsesGetForkMessagesThenFork() async throws {
        let conn = makeTestConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                conn.handleServerMessage(
                    .commandResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "entryId": .string("entry-123"),
                                    "text": .string("Original user prompt"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork(let entryId, let requestId):
                sentTypes.append("fork")
                forkEntryId = entryId
                conn.handleServerMessage(
                    .commandResult(
                        command: "fork",
                        requestId: requestId,
                        success: true,
                        data: .object([:]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        try await conn.forkFromTimelineEntry("entry-123")

        #expect(sentTypes == ["get_fork_messages", "fork"])
        #expect(forkEntryId == "entry-123")
    }

    @MainActor
    @Test func forkFromTimelineEntryParsesForkMessageIdField() async throws {
        let conn = makeTestConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                conn.handleServerMessage(
                    .commandResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "id": .string("fork-entry-123"),
                                    "text": .string("Original user prompt"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork(let entryId, let requestId):
                sentTypes.append("fork")
                forkEntryId = entryId
                conn.handleServerMessage(
                    .commandResult(
                        command: "fork",
                        requestId: requestId,
                        success: true,
                        data: .object([:]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        try await conn.forkFromTimelineEntry("fork-entry-123")

        #expect(sentTypes == ["get_fork_messages", "fork"])
        #expect(forkEntryId == "fork-entry-123")
    }

    @MainActor
    @Test func forkFromTimelineEntryNormalizesTraceSyntheticIDs() async throws {
        let conn = makeTestConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                conn.handleServerMessage(
                    .commandResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "entryId": .string("entry-123"),
                                    "text": .string("Original user prompt"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork(let entryId, let requestId):
                sentTypes.append("fork")
                forkEntryId = entryId
                conn.handleServerMessage(
                    .commandResult(
                        command: "fork",
                        requestId: requestId,
                        success: true,
                        data: .object([:]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        try await conn.forkFromTimelineEntry("entry-123-text-0")

        #expect(sentTypes == ["get_fork_messages", "fork"])
        #expect(forkEntryId == "entry-123")
    }

    @MainActor
    @Test func forkFromTimelineEntryRejectsNonForkableEntry() async {
        let conn = makeTestConnection()
        var sentTypes: [String] = []

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                conn.handleServerMessage(
                    .commandResult(
                        command: "get_fork_messages",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "messages": .array([
                                .object([
                                    "entryId": .string("entry-allowed"),
                                    "text": .string("Allowed"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            case .fork:
                sentTypes.append("fork")

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        do {
            try await conn.forkFromTimelineEntry("entry-denied")
            Issue.record("Expected entryNotForkable error")
        } catch let error as ForkRequestError {
            #expect(error == .entryNotForkable)
        } catch {
            Issue.record("Expected ForkRequestError.entryNotForkable, got \(error)")
        }

        #expect(sentTypes == ["get_fork_messages"])
    }
}
