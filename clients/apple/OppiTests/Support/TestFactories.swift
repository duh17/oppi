import UIKit
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
    lastAgentReplyAt: Date? = nil,
    currentTurnStartedAt: Date? = nil,
    programStatus: ProgramStatus? = nil,
    model: String? = nil,
    messageCount: Int = 0,
    firstMessage: String? = nil,
    thinkingLevel: String? = nil,
    runtime: SessionRuntimeKind? = nil
) -> Session {
    Session(
        id: id,
        workspaceId: workspaceId,
        workspaceName: workspaceName,
        name: name,
        status: status,
        createdAt: createdAt,
        lastActivity: lastActivity,
        lastAgentReplyAt: lastAgentReplyAt,
        currentTurnStartedAt: currentTurnStartedAt,
        programStatus: programStatus,
        model: model,
        messageCount: messageCount,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0,
        contextTokens: nil,
        contextWindow: nil,
        firstMessage: firstMessage,
        lastMessage: nil,
        thinkingLevel: thinkingLevel,
        runtime: runtime
    )
}

/// App root services for hosting tests, with no paired server. Drafts go to a
/// throwaway file unless the test passes its own store.
@MainActor
func makeTestAppRoot(
    coordinator: ConnectionCoordinator? = nil,
    themeStore: ThemeStore = ThemeStore(),
    composerDraftStore: ComposerDraftStore? = nil,
    sessionRows: SessionRowDisplayStore = SessionRowDisplayStore(fixed: SessionRowDisplay())
) -> AppRootEnvironment {
    AppRootEnvironment(
        coordinator: coordinator ?? ConnectionCoordinator(serverStore: ServerStore()),
        navigation: AppNavigation(),
        themeStore: themeStore,
        quickCommentTemplateStore: QuickCommentTemplateStore(templates: []),
        composerDraftStore: composerDraftStore ?? ComposerDraftStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "test-app-root-drafts-\(UUID().uuidString).json", directoryHint: .notDirectory),
            saveDelay: .seconds(60)
        ),
        chatReaderPayloadStore: ChatReaderPayloadStore(),
        sessionRows: sessionRows
    )
}

/// App root services whose coordinator has `serverId` paired and active, so a
/// screen's server switch to it succeeds at once, reading through `apiClient`.
/// The server lives only in memory, never in the Keychain.
@MainActor
func makeTestAppRoot(readyServerId serverId: String, apiClient: APIClient) throws -> AppRootEnvironment {
    let credentials = ServerCredentials(
        host: "ready-server.test",
        port: 7749,
        token: "sk_test",
        name: "Ready",
        scheme: .https,
        serverFingerprint: serverId
    )
    let server = try #require(PairedServer(from: credentials, sortOrder: 0))
    let serverStore = ServerStore()
    serverStore.replaceServersForPreview([server])
    let coordinator = ConnectionCoordinator(serverStore: serverStore)
    coordinator.ensureConnection(for: server).setAPIClientForTesting(apiClient)
    #expect(coordinator.restoreActiveServer(server.id))
    return makeTestAppRoot(coordinator: coordinator)
}

extension ExtensionSurfaceStore {
    /// The session's whole surface, or nil when it shows nothing.
    func state(for sessionId: String) -> ExtensionSurfaceState? {
        let state = surface(for: sessionId).state
        return state.hasRetainedContent ? state : nil
    }
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

/// Records every open a producer delivers. Its opener absorbs the request, so
/// a test can prove delivery without a server, a browser, or the system.
@MainActor
final class TestOpenRequestRecorder {
    private(set) var requests: [AppOpenRequest] = []

    func record(_ request: AppOpenRequest) -> Bool {
        requests.append(request)
        return true
    }
}

/// An app root whose opener records every request instead of opening it.
@MainActor
func makeRecordingAppRoot() -> (root: AppRootEnvironment, recorder: TestOpenRequestRecorder) {
    let recorder = TestOpenRequestRecorder()
    let coordinator = ConnectionCoordinator(serverStore: ServerStore())
    let navigation = AppNavigation()
    let drafts = ComposerDraftStore(
        fileURL: FileManager.default.temporaryDirectory
            .appending(path: "test-recording-drafts-\(UUID().uuidString).json", directoryHint: .notDirectory),
        saveDelay: .seconds(60)
    )
    let opener = AppOpener(
        coordinator: coordinator,
        navigation: navigation,
        composerDraftStore: drafts,
        browserPresent: { _ = recorder.record(.webLink($0)) },
        systemOpen: { _ = recorder.record(.system($0)) }
    )
    opener._openRequestObserverForTesting = { recorder.record($0) }
    let root = AppRootEnvironment(
        coordinator: coordinator,
        navigation: navigation,
        themeStore: ThemeStore(),
        quickCommentTemplateStore: QuickCommentTemplateStore(templates: []),
        composerDraftStore: drafts,
        chatReaderPayloadStore: ChatReaderPayloadStore(),
        sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay()),
        opener: opener
    )
    return (root, recorder)
}

/// A window that publishes `root`, the same trait `HostFactory.root(near:)`
/// reads in the app, so a producer's tap can find the opener.
@MainActor
func makeAppRootWindow(_ root: AppRootEnvironment) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.traitOverrides.appRootEnvironment = root
    window.isHidden = false
    return window
}
