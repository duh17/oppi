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
    currentTurnStartedAt: Date? = nil,
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
        currentTurnStartedAt: currentTurnStartedAt,
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

@MainActor
func makeTestConnection(sessionId: String = "s1") -> (conn: ServerConnection, pipe: TestEventPipeline) {
    let connection = ServerConnection()
    connection.configure(credentials: makeTestCredentials())
    connection._setActiveSessionIdForTesting(sessionId)
    let pipeline = TestEventPipeline(sessionId: sessionId, connection: connection)
    return (connection, pipeline)
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

func makeTestIrohOnlyCredentials(
    token: String = "dt_iroh",
    name: String = "Iroh Server",
    fingerprint: String = "sha256:iroh-server-fp",
    alpns: [String] = [IrohTunnelProtocol.alpn]
) -> ServerCredentials {
    ServerCredentials(
        host: "",
        port: 0,
        token: token,
        name: name,
        scheme: nil,
        serverFingerprint: fingerprint,
        transports: ServerTransports(
            preference: .irohOnly,
            iroh: IrohServerTransport(
                version: 2,
                nodeId: "node-id-123",
                alpns: alpns,
                addressMode: .nodeId,
                ticket: nil
            ),
            http: nil
        )
    )
}

func makeTestWorkspace(
    id: String = "w1",
    name: String = "Workspace",
    description: String? = nil,
    icon: String? = nil,
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
