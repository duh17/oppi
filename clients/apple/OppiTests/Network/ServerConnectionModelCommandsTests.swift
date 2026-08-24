import Foundation
import Testing
@testable import Oppi

@Suite("ServerConnection+ModelCommands")
@MainActor
struct ServerConnectionModelCommandsTests {
    @Test func setModelSendsCorrectClientMessage() async throws {
        let (connection, _) = makeTestConnection()
        await markFocusedSessionFullySubscribed(connection)
        defer { connection.streamConsumptionTask?.cancel() }
        let sink = CapturedClientMessages()
        connection._sendMessageForTesting = { message in
            await sink.append(message)
            guard case .setModel(_, _, let requestId, _) = message,
                  let requestId else {
                return
            }
            _ = connection.commands.resolveCommandResult(
                command: "set_model",
                requestId: requestId,
                success: true,
                data: ["provider": "anthropic", "id": "claude-sonnet-4"],
                error: nil
            )
        }

        try await connection.setModel(provider: "anthropic", modelId: "claude-sonnet-4")

        let messages = await sink.messages
        let modelMessages = messages.compactMap { message -> (String, String, String)? in
            guard case .setModel(let provider, let modelId, let requestId, let persist) = message,
                  let requestId else { return nil }
            #expect(persist == nil)
            return (provider, modelId, requestId)
        }
        #expect(modelMessages.count == 1)
        let (provider, modelId, requestId) = try #require(modelMessages.first)
        #expect(provider == "anthropic")
        #expect(modelId == "claude-sonnet-4")
        #expect(!requestId.isEmpty)
    }

    @Test func setModelPersistSendsPersistFlag() async throws {
        let (connection, _) = makeTestConnection()
        await markFocusedSessionFullySubscribed(connection)
        defer { connection.streamConsumptionTask?.cancel() }
        let sink = CapturedClientMessages()
        connection._sendMessageForTesting = { message in
            await sink.append(message)
            guard case .setModel(_, _, let requestId, _) = message,
                  let requestId else {
                return
            }
            _ = connection.commands.resolveCommandResult(
                command: "set_model",
                requestId: requestId,
                success: true,
                data: ["provider": "anthropic", "id": "claude-sonnet-4"],
                error: nil
            )
        }

        try await connection.setModel(provider: "anthropic", modelId: "claude-sonnet-4", persist: true)

        let messages = await sink.messages
        guard case .setModel(_, _, _, let persist) = messages[0] else {
            Issue.record("Expected setModel")
            return
        }
        #expect(persist == true)
    }

    @Test func setModelSurfacesAuthoritativeRejection() async throws {
        let (connection, _) = makeTestConnection()
        await markFocusedSessionFullySubscribed(connection)
        defer { connection.streamConsumptionTask?.cancel() }
        connection._sendMessageForTesting = { message in
            guard case .setModel(_, _, let requestId, _) = message,
                  let requestId else {
                return
            }
            _ = connection.commands.resolveCommandResult(
                command: "set_model",
                requestId: requestId,
                success: false,
                data: nil,
                error: "model unavailable"
            )
        }

        await #expect(throws: CommandRequestError.self) {
            try await connection.setModel(provider: "anthropic", modelId: "missing")
        }
    }

    @Test func thinkingCommandsSendCorrectClientMessages() async throws {
        let (connection, _) = makeTestConnection()
        await markFocusedSessionFullySubscribed(connection)
        defer { connection.streamConsumptionTask?.cancel() }
        let sink = CapturedClientMessages()
        connection._sendMessageForTesting = { message in
            await sink.append(message)
        }

        try await connection.setThinkingLevel(.high)
        try await connection.cycleThinkingLevel()

        let messages = await sink.messages
        let thinkingMessages = messages.filter { message in
            switch message {
            case .setThinkingLevel, .cycleThinkingLevel:
                return true
            default:
                return false
            }
        }
        #expect(thinkingMessages.count == 2)

        guard case .setThinkingLevel(let level, _, _) = thinkingMessages[0] else {
            Issue.record("Expected setThinkingLevel client message")
            return
        }
        #expect(level == .high)

        guard case .cycleThinkingLevel = thinkingMessages[1] else {
            Issue.record("Expected cycleThinkingLevel client message")
            return
        }
    }

    @Test func sessionCommandsSendCorrectClientMessages() async throws {
        let (connection, _) = makeTestConnection()
        let sink = CapturedClientMessages()
        connection._sendMessageForTesting = { message in
            await sink.append(message)
        }

        try await connection.newSession()
        try await connection.setSessionName("rename me")
        try await connection.compact(instructions: "keep important stuff")

        async let shareTask = connection.shareSession()
        #expect(await waitForMainActorCondition { !connection.commands.pendingCommandsByRequestId.isEmpty })

        let requestId = try #require(connection.commands.pendingCommandsByRequestId.keys.first)
        _ = connection.commands.resolveCommandResult(
            command: "share_session",
            requestId: requestId,
            success: true,
            data: [
                "shareUrl": "https://pi.dev/session/#abc123",
                "gistUrl": "https://gist.github.com/demo-user/abc123",
                "gistId": "abc123",
            ],
            error: nil
        )
        _ = try await shareTask

        let messages = await sink.messages
        #expect(messages.count == 4)

        guard case .newSession = messages[0] else {
            Issue.record("Expected newSession client message")
            return
        }
        guard case .setSessionName(let name, _) = messages[1] else {
            Issue.record("Expected setSessionName client message")
            return
        }
        #expect(name == "rename me")
        guard case .compact(let instructions, _) = messages[2] else {
            Issue.record("Expected compact client message")
            return
        }
        #expect(instructions == "keep important stuff")

        guard case .shareSession = messages[3] else {
            Issue.record("Expected shareSession client message")
            return
        }
    }

    @Test func syncsMaxThinkingLevelFromSessionState() {
        let connection = makeTestConnection().conn
        let session = makeTestSession(thinkingLevel: "max")

        connection.syncThinkingLevel(from: session)

        #expect(connection.chatState.thinkingLevel == .max)
    }

    @Test func syncThinkingLevelUpdatesOnlyForValidChangedValues() {
        let (connection, _) = makeTestConnection()
        var session = makeTestSession(thinkingLevel: "high")

        connection.syncThinkingLevel(from: session)
        #expect(connection.chatState.thinkingLevel == .high)

        session.thinkingLevel = "high"
        connection.syncThinkingLevel(from: session)
        #expect(connection.chatState.thinkingLevel == .high)

        session.thinkingLevel = "definitely_not_real"
        connection.syncThinkingLevel(from: session)
        #expect(connection.chatState.thinkingLevel == .high)

        session.thinkingLevel = nil
        connection.syncThinkingLevel(from: session)
        #expect(connection.chatState.thinkingLevel == .high)
    }

    @Test func refreshSlashCommandsSkipsWarmMatchingCache() async {
        let (connection, _) = makeTestConnection()
        let session = makeTestSession(id: "s1", workspaceId: "w1")
        connection.chatState.slashCommands = [
            Self.slashCommand(name: "compact", description: nil, source: .prompt)
        ]
        connection.chatState.slashCommandsCacheKey = connection.slashCommandCacheKey(for: session)

        var sendCount = 0
        connection._sendMessageForTesting = { _ in
            sendCount += 1
        }

        await connection.refreshSlashCommands(for: session, force: false)

        #expect(sendCount == 0)
        #expect(connection.chatState.slashCommandsRequestId == nil)
    }

    @Test func refreshSlashCommandsSendsCommandAndTracksRequestId() async {
        let (connection, _) = makeTestConnection()
        let session = makeTestSession(id: "s1", workspaceId: "w1")
        let sink = CapturedClientMessages()
        connection._sendMessageForTesting = { message in
            await sink.append(message)
        }

        await connection.refreshSlashCommands(for: session, force: true)

        let messages = await sink.messages
        #expect(messages.count == 1)
        guard case .getCommands(let requestId) = messages[0] else {
            Issue.record("Expected getCommands message")
            return
        }
        #expect(!(requestId ?? "").isEmpty)
        #expect(connection.chatState.slashCommandsRequestId == requestId)
    }

    @Test func refreshSlashCommandsClearsRequestIdWhenSendFails() async {
        let (connection, _) = makeTestConnection()
        let session = makeTestSession(id: "s1", workspaceId: "w1")
        struct SendFailure: Error {}

        connection._sendMessageForTesting = { _ in
            throw SendFailure()
        }

        await connection.refreshSlashCommands(for: session, force: true)

        #expect(connection.chatState.slashCommandsRequestId == nil)
    }

    @Test func handleSlashCommandsResultIgnoresMismatchedRequestId() {
        let (connection, _) = makeTestConnection()
        let session = makeTestSession(id: "s1", workspaceId: "w1")
        connection.sessionStore.upsert(session)
        connection.chatState.slashCommandsRequestId = "expected"
        connection.chatState.slashCommands = [
            Self.slashCommand(name: "existing", description: nil, source: .prompt)
        ]

        connection.handleSlashCommandsResult(
            requestId: "wrong",
            success: true,
            data: makeSlashCommandsPayload(),
            error: nil,
            sessionId: session.id
        )

        #expect(connection.chatState.slashCommands.map(\.name) == ["existing"])
        #expect(connection.chatState.slashCommandsRequestId == "expected")
    }

    @Test func handleSlashCommandsResultUpdatesCommandsAndCacheKey() {
        let (connection, _) = makeTestConnection()
        let session = makeTestSession(id: "s1", workspaceId: "w1")
        connection.sessionStore.upsert(session)
        connection.chatState.slashCommandsRequestId = "expected"

        connection.handleSlashCommandsResult(
            requestId: "expected",
            success: true,
            data: makeSlashCommandsPayload(),
            error: nil,
            sessionId: session.id
        )

        #expect(connection.chatState.slashCommands.map(\.name) == ["compact", "share", "skill:lint"])
        #expect(connection.chatState.slashCommandsCacheKey == connection.slashCommandCacheKey(for: session))
        #expect(connection.chatState.slashCommandsRequestId == nil)
    }

    @Test func handleSlashCommandsFailureClearsOnlyRequestTracking() {
        let (connection, _) = makeTestConnection()
        connection.chatState.slashCommandsRequestId = "expected"
        connection.chatState.slashCommands = [Self.slashCommand(name: "existing", description: nil, source: .prompt)]

        connection.handleSlashCommandsResult(
            requestId: "expected",
            success: false,
            data: makeSlashCommandsPayload(),
            error: "boom",
            sessionId: "missing"
        )

        #expect(connection.chatState.slashCommands.map(\.name) == ["existing"])
        #expect(connection.chatState.slashCommandsRequestId == nil)
    }

    @Test func parseSlashCommandsDedupesCaseInsensitivelyAndSorts() {
        let commands = ServerConnection.parseSlashCommands(from: [
            "commands": [
                ["name": "Skill:Lint", "description": "later duplicate", "source": "skill"],
                ["name": "compact", "description": "compact context", "source": "prompt"],
                ["name": "skill:lint", "description": "first wins", "source": "extension"],
                ["name": "", "description": "invalid", "source": "skill"],
                ["name": "explain", "description": "explain", "source": "prompt"],
            ]
        ])

        #expect(commands.map(\.name) == ["compact", "explain", "Skill:Lint"])
        #expect(commands.last?.source == .skill)
        #expect(commands.last?.description == "later duplicate")
    }

    private static func slashCommand(
        name: String,
        description: String?,
        source: SlashCommand.Source
    ) -> SlashCommand {
        guard let command = SlashCommand(.object([
            "name": .string(name),
            "description": description.map(JSONValue.string) ?? .null,
            "source": .string(source.rawValue),
        ])) else {
            fatalError("Invalid test slash command")
        }
        return command
    }

    @Test func parseSharedSessionLinkParsesPayload() {
        let link = ServerConnection.parseSharedSessionLink(from: [
            "shareUrl": "https://pi.dev/session/#abc123",
            "gistUrl": "https://gist.github.com/user/abc123",
            "gistId": "abc123",
        ])

        #expect(link == SharedSessionLink(
            shareURL: "https://pi.dev/session/#abc123",
            gistURL: "https://gist.github.com/user/abc123",
            gistID: "abc123"
        ))
    }

    @Test func parseShareErrorEnvelopeExtractsCodeAndMessage() {
        let parsed = ServerConnection.parseShareErrorEnvelope(
            "[share:gh_not_authenticated] GitHub CLI is not logged in."
        )

        #expect(parsed.code == "gh_not_authenticated")
        #expect(parsed.message == "GitHub CLI is not logged in.")
    }

    @Test func parseSharedSessionLinkParsesStructuredPayload() {
        let link = ServerConnection.parseSharedSessionLink(from: [
            "phase": "published",
            "share": [
                "url": "https://pi.dev/session/#abc123",
                "providerRef": [
                    "gistUrl": "https://gist.github.com/user/abc123",
                    "gistId": "abc123",
                ],
            ],
        ])

        #expect(link == SharedSessionLink(
            shareURL: "https://pi.dev/session/#abc123",
            gistURL: "https://gist.github.com/user/abc123",
            gistID: "abc123"
        ))
    }

    @Test func parseShareSessionRedactionReportParsesPayload() {
        let report = ServerConnection.parseShareSessionRedactionReport(from: [
            "redaction": [
                "policy": [
                    "secrets": true,
                    "emails": true,
                    "phones": false,
                    "userPaths": true,
                    "ipAddresses": true,
                    "jwtAndBearer": true,
                    "namesHeuristic": false,
                ],
                "totalReplacements": 3,
                "findings": [
                    [
                        "kind": "openai_api_key",
                        "count": 1,
                        "replacement": "[REDACTED_OPENAI_API_KEY]",
                        "samples": ["sk-A…ZZZZ"],
                    ],
                    [
                        "kind": "email_address",
                        "count": 2,
                        "replacement": "[REDACTED_EMAIL]",
                        "samples": ["a***@example.com"],
                    ],
                ],
            ],
        ])

        #expect(report == ShareSessionRedactionReport(
            policy: ShareSessionRedactionPolicy(
                secrets: true,
                emails: true,
                phones: false,
                userPaths: true,
                ipAddresses: true,
                jwtAndBearer: true,
                namesHeuristic: false,
                skills: true
            ),
            totalReplacements: 3,
            findings: [
                ShareSessionRedactionFinding(
                    kind: "openai_api_key",
                    count: 1,
                    replacement: "[REDACTED_OPENAI_API_KEY]",
                    samples: ["sk-A…ZZZZ"]
                ),
                ShareSessionRedactionFinding(
                    kind: "email_address",
                    count: 2,
                    replacement: "[REDACTED_EMAIL]",
                    samples: ["a***@example.com"]
                ),
            ]
        ))
    }

    @Test func parseShareSessionPublishResultParsesLinkAndRedaction() {
        let result = ServerConnection.parseShareSessionPublishResult(from: [
            "phase": "published",
            "share": [
                "url": "https://pi.dev/session/#abc123",
                "providerRef": [
                    "gistUrl": "https://gist.github.com/user/abc123",
                    "gistId": "abc123",
                ],
            ],
            "redaction": [
                "totalReplacements": 1,
                "findings": [
                    [
                        "kind": "email_address",
                        "count": 1,
                        "replacement": "[REDACTED_EMAIL]",
                        "samples": ["a***@example.com"],
                    ],
                ],
            ],
        ])

        #expect(result == SharedSessionPublishResult(
            link: SharedSessionLink(
                shareURL: "https://pi.dev/session/#abc123",
                gistURL: "https://gist.github.com/user/abc123",
                gistID: "abc123"
            ),
            redaction: ShareSessionRedactionReport(
                policy: nil,
                totalReplacements: 1,
                findings: [
                    ShareSessionRedactionFinding(
                        kind: "email_address",
                        count: 1,
                        replacement: "[REDACTED_EMAIL]",
                        samples: ["a***@example.com"]
                    ),
                ]
            )
        ))
    }

    @Test func parseShareSessionPrepareResultParsesPayload() {
        let prepared = ServerConnection.parseShareSessionPrepareResult(from: [
            "phase": "prepared",
            "canPublish": false,
            "artifact": ["bytes": 1234],
            "scan": [
                "blocked": true,
                "findings": [
                    ["kind": "openai_api_key", "count": 2],
                ],
            ],
            "redaction": [
                "totalReplacements": 2,
                "findings": [
                    [
                        "kind": "phone_number",
                        "count": 2,
                        "replacement": "[REDACTED_PHONE]",
                        "samples": ["+1…0199"],
                    ],
                ],
            ],
        ])

        #expect(prepared == ShareSessionPrepareResult(
            canPublish: false,
            blocked: true,
            findings: [ShareSessionScanFinding(kind: "openai_api_key", count: 2)],
            artifactBytes: 1234,
            redaction: ShareSessionRedactionReport(
                policy: nil,
                totalReplacements: 2,
                findings: [
                    ShareSessionRedactionFinding(
                        kind: "phone_number",
                        count: 2,
                        replacement: "[REDACTED_PHONE]",
                        samples: ["+1…0199"]
                    ),
                ]
            )
        ))
    }

    @Test func normalizeShareSessionErrorMapsStructuredCodes() {
        let normalized = ServerConnection.normalizeShareSessionError(
            .rejected(
                command: "share_session",
                reason: "[share:gh_not_installed] GitHub CLI (gh) is missing"
            )
        )

        switch normalized {
        case .failed(let message):
            #expect(message.contains("GitHub CLI"))
            #expect(!message.contains("[share:"))
        case .timedOut:
            Issue.record("Expected mapped .failed share error")
        }
    }

    @Test func normalizeShareSessionErrorMapsTimeouts() {
        let normalized = ServerConnection.normalizeShareSessionError(
            .timeout(command: "share_session")
        )

        switch normalized {
        case .timedOut:
            #expect(true)
        case .failed:
            Issue.record("Expected .timedOut share error")
        }
    }

    @Test func parseSessionStatsParsesStringsAndFallsBackTotal() {
        let stats = ServerConnection.parseSessionStats(from: [
            "tokens": [
                "input": "12",
                "output": 34,
                "cacheRead": "5",
                "cacheWrite": 6,
            ],
            "cost": "1.25",
            "cacheWaste": [
                "missedTokens": "20000",
                "missedCost": "0.15",
                "missCount": 2,
            ],
            "modelBreakdown": [
                ["provider": "anthropic", "model": "claude-sonnet", "tokens": "40", "cost": "0.75"],
                ["provider": "openai-codex", "model": "gpt-5.6-sol", "tokens": 17, "cost": 0.5],
                ["model": "Tools & summaries", "tokens": 9, "cost": 0.1],
            ],
            "contextComposition": [
                "piSystemPromptChars": "100",
                "piSystemPromptTokens": 20,
                "agentsChars": 30,
                "agentsTokens": "4",
                "agentsFiles": [
                    ["path": "/tmp/AGENTS.md", "chars": "40", "tokens": 8],
                    ["chars": 1, "tokens": 1],
                ],
                "skillsListingChars": "50",
                "skillsListingTokens": 9,
            ],
        ])

        #expect(stats?.tokens.input == 12)
        #expect(stats?.tokens.output == 34)
        #expect(stats?.tokens.cacheRead == 5)
        #expect(stats?.tokens.cacheWrite == 6)
        #expect(stats?.tokens.total == 57)
        #expect(stats?.cost == 1.25)
        #expect(stats?.cacheWaste == SessionCacheWasteSnapshot(
            missedTokens: 20_000,
            missedCost: 0.15,
            missCount: 2
        ))
        #expect(stats?.modelBreakdown == [
            SessionModelUsageSnapshot(provider: "anthropic", model: "claude-sonnet", tokens: 40, cost: 0.75),
            SessionModelUsageSnapshot(provider: "openai-codex", model: "gpt-5.6-sol", tokens: 17, cost: 0.5),
            SessionModelUsageSnapshot(provider: nil, model: "Tools & summaries", tokens: 9, cost: 0.1),
        ])
        #expect(stats?.contextComposition?.agentsFiles == [
            ContextFileTokenSnapshot(path: "/tmp/AGENTS.md", chars: 40, tokens: 8)
        ])
    }

    @Test func getSessionStatsResolvesCommandResultPayload() async throws {
        let (connection, _) = makeTestConnection()
        let sink = CapturedClientMessages()
        connection._sendMessageForTesting = { message in
            await sink.append(message)
        }

        async let statsTask = connection.getSessionStats()
        #expect(await waitForMainActorCondition { !connection.commands.pendingCommandsByRequestId.isEmpty })

        let requestId = try #require(connection.commands.pendingCommandsByRequestId.keys.first)
        _ = connection.commands.resolveCommandResult(
            command: "get_session_stats",
            requestId: requestId,
            success: true,
            data: [
                "tokens": [
                    "input": 1,
                    "output": 2,
                    "cacheRead": 3,
                    "cacheWrite": 4,
                    "total": 10,
                ],
                "cost": 0.5,
            ],
            error: nil
        )

        let stats = try await statsTask
        let messages = await sink.messages

        #expect(messages.count == 1)
        guard case .getSessionStats(let sentRequestId) = messages[0] else {
            Issue.record("Expected getSessionStats message")
            return
        }
        #expect(sentRequestId == requestId)
        #expect(stats?.tokens.total == 10)
        #expect(stats?.cost == 0.5)
    }
}

@MainActor
private func markFocusedSessionFullySubscribed(_ connection: ServerConnection, sessionId: String = "s1") async {
    connection.wsClient?._setStatusForTesting(.connected)
    connection.streamConsumptionTask = makeCancellableNeverCompletingTaskForTesting()
    connection._setActiveSessionIdForTesting(sessionId)
    connection.setFocusedSessionStreamEndpointKindForTesting("split_session")
    _ = await connection.sessionStreamCoordinator.streamSession(
        connection: connection,
        sessionId: sessionId,
        routeScope: .workspace("w1")
    )
}

private actor CapturedClientMessages {
    private var storage: [ClientMessage] = []

    func append(_ message: ClientMessage) {
        storage.append(message)
    }

    var messages: [ClientMessage] { storage }
}

private func makeSlashCommandsPayload() -> JSONValue {
    [
        "commands": [
            ["name": "compact", "description": "Compact context", "source": "prompt"],
            ["name": "share", "description": "Share session", "source": "builtin"],
            ["name": "skill:lint", "description": "Run linter", "source": "skill"],
        ]
    ]
}
