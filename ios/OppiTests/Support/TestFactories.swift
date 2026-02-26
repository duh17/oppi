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
        firstMessage: nil,
        lastMessage: nil,
        thinkingLevel: thinkingLevel
    )
}

@MainActor
func makeTestConnection(sessionId: String = "s1") -> ServerConnection {
    let connection = ServerConnection()
    connection.configure(credentials: makeTestCredentials())
    connection._setActiveSessionIdForTesting(sessionId)
    return connection
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

func makeTestPermission(
    id: String = "p1",
    sessionId: String = "s1",
    tool: String = "bash",
    timeoutOffset: TimeInterval = 120
) -> PermissionRequest {
    PermissionRequest(
        id: id,
        sessionId: sessionId,
        tool: tool,
        input: [:],
        displaySummary: "\(tool): test",
        reason: "Test",
        timeoutAt: Date().addingTimeInterval(timeoutOffset)
    )
}

func makeTestWorkspace(
    id: String = "w1",
    name: String = "Workspace",
    description: String? = nil,
    icon: String? = nil,
    skills: [String] = [],
    systemPrompt: String? = nil,
    hostMount: String? = nil,
    memoryEnabled: Bool? = nil,
    memoryNamespace: String? = nil,
    extensions: [String]? = nil,
    gitStatusEnabled: Bool? = nil,
    defaultModel: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> Workspace {
    Workspace(
        id: id,
        name: name,
        description: description,
        icon: icon,
        skills: skills,
        systemPrompt: systemPrompt,
        hostMount: hostMount,
        memoryEnabled: memoryEnabled,
        memoryNamespace: memoryNamespace,
        extensions: extensions,
        gitStatusEnabled: gitStatusEnabled,
        defaultModel: defaultModel,
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}
