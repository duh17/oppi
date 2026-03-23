import Foundation
import Testing
@testable import Oppi

@Suite("ServerConnection+ModelCommands")
@MainActor
struct ServerConnectionModelCommandsTests {
    @Test func setModelSendsCorrectClientMessage() async throws {
        let (connection, _) = makeTestConnection()
        let sink = CapturedClientMessages()
        connection._sendMessageForTesting = { message in
            await sink.append(message)
        }

        try await connection.setModel(provider: "anthropic", modelId: "claude-sonnet-4")

        let messages = await sink.messages
        #expect(messages.count == 1)
        guard case .setModel(let provider, let modelId, _) = messages[0] else {
            Issue.record("Expected setModel client message")
            return
        }
        #expect(provider == "anthropic")
        #expect(modelId == "claude-sonnet-4")
    }

    @Test func thinkingCommandsSendCorrectClientMessages() async throws {
        let (connection, _) = makeTestConnection()
        let sink = CapturedClientMessages()
        connection._sendMessageForTesting = { message in
            await sink.append(message)
        }

        try await connection.setThinkingLevel(.high)
        try await connection.cycleThinkingLevel()

        let messages = await sink.messages
        #expect(messages.count == 2)

        guard case .setThinkingLevel(let level, _) = messages[0] else {
            Issue.record("Expected setThinkingLevel client message")
            return
        }
        #expect(level == .high)

        guard case .cycleThinkingLevel = messages[1] else {
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

        let messages = await sink.messages
        #expect(messages.count == 3)

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
            SlashCommand(name: "compact", description: nil, source: .prompt)
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
            SlashCommand(name: "existing", description: nil, source: .prompt)
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

        #expect(connection.chatState.slashCommands.map(\.name) == ["compact", "skill:lint"])
        #expect(connection.chatState.slashCommandsCacheKey == connection.slashCommandCacheKey(for: session))
        #expect(connection.chatState.slashCommandsRequestId == nil)
    }

    @Test func handleSlashCommandsFailureClearsOnlyRequestTracking() {
        let (connection, _) = makeTestConnection()
        connection.chatState.slashCommandsRequestId = "expected"
        connection.chatState.slashCommands = [SlashCommand(name: "existing", description: nil, source: .prompt)]

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

    @Test func parseSessionStatsParsesStringsAndFallsBackTotal() {
        let stats = ServerConnection.parseSessionStats(from: [
            "tokens": [
                "input": "12",
                "output": 34,
                "cacheRead": "5",
                "cacheWrite": 6,
            ],
            "cost": "1.25",
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
            ["name": "skill:lint", "description": "Run linter", "source": "skill"],
        ]
    ]
}
