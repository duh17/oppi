import Testing
import Foundation
@testable import Oppi

@Suite("ServerConnection Send ACK")
@MainActor
struct ServerConnectionSendAckTests {

    @Test func sendAckSuccessForPromptSteerAndFollowUp() async throws {
        for command in EventFlowAckCommand.allCases {
            let (conn, pipe) = makeEventFlowAckTestConnection()

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
                    pipe.handle(
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

    @Test func sendAckUsesTurnAckStages() async throws {
        let (conn, pipe) = makeEventFlowAckTestConnection()

        conn._sendMessageForTesting = { message in
            guard let sent = extractEventFlowAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId else {
                Issue.record("Expected turn command with clientTurnId")
                return
            }

            pipe.handle(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .accepted,
                    requestId: sent.requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            pipe.handle(
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

    @Test func sendAckStageCallbackReceivesProgressStages() async throws {
        let (conn, pipe) = makeEventFlowAckTestConnection()

        let stageRecorder = EventFlowAckStageRecorder()

        conn._sendMessageForTesting = { message in
            guard let sent = extractEventFlowAckRequest(from: message),
                  let clientTurnId = sent.clientTurnId,
                  let requestId = sent.requestId else {
                Issue.record("Expected turn command with requestId/clientTurnId")
                return
            }

            pipe.handle(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .accepted,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            pipe.handle(
                .turnAck(
                    command: sent.command,
                    clientTurnId: clientTurnId,
                    stage: .dispatched,
                    requestId: requestId,
                    duplicate: false
                ),
                sessionId: "s1"
            )

            pipe.handle(
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

    @Test func sendRetryReusesClientTurnId() async throws {
        let (conn, pipe) = makeEventFlowAckTestConnection()

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

            pipe.handle(
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

    @Test func sendPromptChurnAlwaysResolvesWithoutSilentDrop() async {
        let (conn, pipe) = makeEventFlowAckTestConnection(timeout: .milliseconds(160))

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

            pipe.handle(
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

    @Test func sendAckRejectedForPromptSteerAndFollowUp() async {
        for command in EventFlowAckCommand.allCases {
            let (conn, pipe) = makeEventFlowAckTestConnection()

            conn._sendMessageForTesting = { message in
                guard let sent = extractEventFlowAckRequest(from: message) else {
                    Issue.record("Expected prompt/steer/follow_up message")
                    return
                }
                #expect(sent.clientTurnId != nil)

                if let requestId = sent.requestId {
                    pipe.handle(
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

    @Test func sendAckTimeoutForPromptSteerAndFollowUp() async {
        for command in EventFlowAckCommand.allCases {
            let (conn, pipe) = makeEventFlowAckTestConnection(timeout: .milliseconds(40))

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

    @Test func commandTimeoutPolicyAppliesRouteSpecificBudgets() {
        let defaultTimeout = MessageSender.defaultCommandTimeout(
            command: "get_session_tree",
            message: .getSessionTree(requestId: "req-default")
        )

        let navigateNoSummary = MessageSender.defaultCommandTimeout(
            command: "navigate_tree",
            message: .navigateTree(targetId: "entry-1", summarize: false, requestId: "req-nav-1")
        )

        let navigateWithSummary = MessageSender.defaultCommandTimeout(
            command: "navigate_tree",
            message: .navigateTree(targetId: "entry-1", summarize: true, requestId: "req-nav-2")
        )

        let compactTimeout = MessageSender.defaultCommandTimeout(
            command: "compact",
            message: .compact(customInstructions: nil, requestId: "req-compact")
        )

        let sharePrepareTimeout = MessageSender.defaultCommandTimeout(
            command: "share_session",
            message: .shareSession(action: .prepare, redactionPolicy: nil, requestId: "req-share-prepare")
        )

        let sharePublishTimeout = MessageSender.defaultCommandTimeout(
            command: "share_session",
            message: .shareSession(action: .publish, redactionPolicy: nil, requestId: "req-share-publish")
        )

        let shareImplicitPublishTimeout = MessageSender.defaultCommandTimeout(
            command: "share_session",
            message: .shareSession(action: nil, redactionPolicy: nil, requestId: "req-share-implicit")
        )

        #expect(defaultTimeout == MessageSender.commandRequestTimeoutDefault)
        #expect(navigateNoSummary == MessageSender.commandRequestTimeoutDefault)
        #expect(navigateWithSummary == MessageSender.commandRequestTimeoutTreeNavigateSummarize)
        #expect(compactTimeout == MessageSender.commandRequestTimeoutCompact)
        #expect(sharePrepareTimeout == MessageSender.commandRequestTimeoutShareSessionPrepare)
        #expect(sharePublishTimeout == MessageSender.commandRequestTimeoutShareSessionPublish)
        #expect(shareImplicitPublishTimeout == MessageSender.commandRequestTimeoutShareSessionPublish)
    }

    // MARK: - Session Tree

    @Test func getSessionTreeParsesCommandResultPayload() async throws {
        let (conn, pipe) = makeTestConnection()

        conn._sendMessageForTesting = { message in
            switch message {
            case .getSessionTree(let filterMode, let requestId):
                #expect(filterMode == .standard)
                pipe.handle(
                    .commandResult(
                        command: "get_session_tree",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "leafId": .string("entry-2"),
                            "nodes": .array([
                                .object([
                                    "id": .string("entry-1"),
                                    "parentId": .null,
                                    "type": .string("message"),
                                    "timestamp": .string("2026-04-19T07:11:10.000Z"),
                                    "depth": .number(0),
                                    "isLeafPath": .bool(false),
                                    "defaultVisible": .bool(true),
                                    "matchesFilter": .bool(true),
                                    "role": .string("user"),
                                    "textPreview": .string("Plan rollout"),
                                    "label": .null,
                                ]),
                                .object([
                                    "id": .string("entry-2"),
                                    "parentId": .string("entry-1"),
                                    "type": .string("summary"),
                                    "timestamp": .string("2026-04-19T07:12:10.000Z"),
                                    "depth": .number(1),
                                    "isLeafPath": .bool(true),
                                    "defaultVisible": .bool(false),
                                    "matchesFilter": .bool(false),
                                    "label": .string("Branch summary"),
                                ]),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        let tree = try await conn.getSessionTree()

        #expect(tree.leafId == "entry-2")
        #expect(tree.nodes.count == 2)

        let root = tree.nodes[0]
        #expect(root.id == "entry-1")
        #expect(root.parentId == nil)
        #expect(root.type == "message")
        #expect(root.depth == 0)
        #expect(root.isLeafPath == false)
        #expect(root.defaultVisible == true)
        #expect(root.matchesFilter == true)
        #expect(root.role == "user")
        #expect(root.textPreview == "Plan rollout")
        #expect(root.label == nil)

        let leaf = tree.nodes[1]
        #expect(leaf.id == "entry-2")
        #expect(leaf.parentId == "entry-1")
        #expect(leaf.type == "summary")
        #expect(leaf.depth == 1)
        #expect(leaf.isLeafPath == true)
        #expect(leaf.defaultVisible == false)
        #expect(leaf.matchesFilter == false)
        #expect(leaf.label == "Branch summary")
    }

    @Test func getSessionTreeRejectsMalformedPayload() async {
        let (conn, pipe) = makeTestConnection()

        conn._sendMessageForTesting = { message in
            switch message {
            case .getSessionTree(let filterMode, let requestId):
                #expect(filterMode == .standard)
                pipe.handle(
                    .commandResult(
                        command: "get_session_tree",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "leafId": .string("entry-2"),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )
            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        do {
            _ = try await conn.getSessionTree()
            Issue.record("Expected get_session_tree payload rejection")
        } catch let error as CommandRequestError {
            switch error {
            case .rejected(let command, let reason):
                #expect(command == "get_session_tree")
                #expect(reason?.contains("invalid payload") == true)
                #expect(reason?.contains("nodes") == true)
            case .timeout:
                Issue.record("Expected rejected error, got timeout")
            }
        } catch {
            Issue.record("Expected CommandRequestError.rejected, got \(error)")
        }
    }

    @Test func navigateTreeParsesSuccessResult() async throws {
        let (conn, pipe) = makeTestConnection()
        var capturedTargetId: String?
        var capturedSummarize: Bool?
        var capturedInstructions: String?
        var capturedReplaceInstructions: Bool?
        var capturedLabel: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .navigateTree(
                let targetId,
                let summarize,
                let customInstructions,
                let replaceInstructions,
                let label,
                let requestId
            ):
                capturedTargetId = targetId
                capturedSummarize = summarize
                capturedInstructions = customInstructions
                capturedReplaceInstructions = replaceInstructions
                capturedLabel = label

                pipe.handle(
                    .commandResult(
                        command: "navigate_tree",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "editorText": .string("Continue from this branch"),
                            "cancelled": .bool(false),
                            "aborted": .bool(true),
                            "summaryEntry": .object([
                                "id": .string("summary-1"),
                            ]),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )

            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        let result = try await conn.navigateTree(
            targetId: "entry-12",
            summarize: true,
            customInstructions: "Focus on TODOs",
            replaceInstructions: false,
            label: "Branch summary"
        )

        #expect(capturedTargetId == "entry-12")
        #expect(capturedSummarize == true)
        #expect(capturedInstructions == "Focus on TODOs")
        #expect(capturedReplaceInstructions == false)
        #expect(capturedLabel == "Branch summary")

        #expect(result.editorText == "Continue from this branch")
        #expect(result.cancelled == false)
        #expect(result.aborted == true)
        #expect(result.summaryEntry?.id == "summary-1")
    }

    @Test func navigateTreeRejectsMalformedPayload() async {
        let (conn, pipe) = makeTestConnection()

        conn._sendMessageForTesting = { message in
            switch message {
            case .navigateTree(_, _, _, _, _, let requestId):
                pipe.handle(
                    .commandResult(
                        command: "navigate_tree",
                        requestId: requestId,
                        success: true,
                        data: .object([
                            "editorText": .string("Continue from this branch"),
                            "cancelled": .string("false"),
                        ]),
                        error: nil
                    ),
                    sessionId: "s1"
                )
            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        do {
            _ = try await conn.navigateTree(targetId: "entry-99", summarize: false)
            Issue.record("Expected navigate_tree payload rejection")
        } catch let error as CommandRequestError {
            switch error {
            case .rejected(let command, let reason):
                #expect(command == "navigate_tree")
                #expect(reason?.contains("invalid payload") == true)
                #expect(reason?.contains("cancelled") == true)
            case .timeout:
                Issue.record("Expected rejected error, got timeout")
            }
        } catch {
            Issue.record("Expected CommandRequestError.rejected, got \(error)")
        }
    }

    @Test func navigateTreeSurfacesCommandFailure() async {
        let (conn, pipe) = makeTestConnection()

        conn._sendMessageForTesting = { message in
            switch message {
            case .navigateTree(_, _, _, _, _, let requestId):
                pipe.handle(
                    .commandResult(
                        command: "navigate_tree",
                        requestId: requestId,
                        success: false,
                        data: nil,
                        error: "navigation failed"
                    ),
                    sessionId: "s1"
                )
            default:
                Issue.record("Unexpected message sent: \(message.typeLabel)")
            }
        }

        do {
            _ = try await conn.navigateTree(targetId: "entry-99", summarize: false)
            Issue.record("Expected navigate_tree rejection")
        } catch let error as CommandRequestError {
            switch error {
            case .rejected(let command, let reason):
                #expect(command == "navigate_tree")
                #expect(reason == "navigation failed")
            case .timeout:
                Issue.record("Expected rejected error, got timeout")
            }
        } catch {
            Issue.record("Expected CommandRequestError.rejected, got \(error)")
        }
    }

    // MARK: - Fork

    @Test func forkFromTimelineEntryUsesGetForkMessagesThenFork() async throws {
        let (conn, pipe) = makeTestConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                pipe.handle(
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
                pipe.handle(
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

    @Test func forkFromTimelineEntryParsesForkMessageIdField() async throws {
        let (conn, pipe) = makeTestConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                pipe.handle(
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
                pipe.handle(
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

    @Test func forkFromTimelineEntryNormalizesTraceSyntheticIDs() async throws {
        let (conn, pipe) = makeTestConnection()
        var sentTypes: [String] = []
        var forkEntryId: String?

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                pipe.handle(
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
                pipe.handle(
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

    @Test func forkFromTimelineEntryRejectsNonForkableEntry() async {
        let (conn, pipe) = makeTestConnection()
        var sentTypes: [String] = []

        conn._sendMessageForTesting = { message in
            switch message {
            case .getForkMessages(let requestId):
                sentTypes.append("get_fork_messages")
                pipe.handle(
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
