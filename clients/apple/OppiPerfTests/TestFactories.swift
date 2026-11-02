import Foundation
import Testing
@testable import Oppi

func makeTestSession(
    id: String = "s1",
    workspaceId: String? = nil,
    workspaceName: String? = nil,
    name: String? = "Session",
    status: SessionStatus = .ready,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    lastActivity: Date = Date(timeIntervalSince1970: 1_700_000_000),
    model: String? = nil,
    messageCount: Int = 0,
    firstMessage: String? = nil,
    thinkingLevel: String? = nil
) -> Session {
    Session(
        id: id,
        workspaceId: workspaceId,
        workspaceName: workspaceName,
        name: name,
        status: status,
        createdAt: createdAt,
        lastActivity: lastActivity,
        model: model,
        messageCount: messageCount,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0,
        contextTokens: nil,
        contextWindow: nil,
        firstMessage: firstMessage,
        lastMessage: nil,
        thinkingLevel: thinkingLevel
    )
}

func makeTestCredentials(
    host: String = "localhost",
    port: Int = 7749,
    token: String = "sk_test",
    name: String = "Test",
    fingerprint: String? = nil
) -> ServerCredentials {
    ServerCredentials(
        host: host,
        port: port,
        token: token,
        name: name,
        serverFingerprint: fingerprint
    )
}

/// Configure `connection` through the production setup path (`configureForUse`),
/// answering its authenticated `/server/info` bootstrap in memory with a server
/// that streams sessions.
@MainActor
@discardableResult
func configureTestConnection(
    _ connection: ServerConnection,
    credentials: ServerCredentials = makeTestCredentials()
) async -> Bool {
    let info = ServerInfo(
        name: "Test",
        version: "1.0.0",
        uptime: 1,
        os: "darwin",
        arch: "arm64",
        hostname: "test.local",
        nodeVersion: "22",
        piVersion: "1",
        configVersion: 1,
        identity: nil,
        uploadProtocol: nil,
        images: nil,
        capabilities: .init(
            sessionStream: .init(version: 1),
            dictationStream: nil,
            appEventStream: nil,
            extensionNativeUI: nil
        ),
        stats: .init(
            workspaceCount: 0,
            activeSessionCount: 0,
            totalSessionCount: 0,
            skillCount: 0,
            modelCount: 0
        )
    )
    return await connection.configureForUse(
        credentials: credentials,
        serverInfoBootstrap: { _, _ in info }
    )
}

func makeTestWorkspace(
    id: String = "w1",
    name: String = "Workspace",
    description: String? = nil,
    icon: IconChoice = .defaultValue,
    systemPrompt: String? = nil,
    systemPromptMode: WorkspaceSystemPromptMode = .append,
    hostMount: String? = nil,
    gitStatusEnabled: Bool? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> Workspace {
    Workspace(
        id: id,
        name: name,
        description: description,
        icon: icon,
        systemPrompt: systemPrompt,
        systemPromptMode: systemPromptMode,
        hostMount: hostMount,
        gitStatusEnabled: gitStatusEnabled,
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}
