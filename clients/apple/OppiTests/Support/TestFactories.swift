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
/// throwaway file unless the test passes its own store. `settings` replaces the
/// device settings store (a test's, on a suite of its own); `serverSettings`
/// makes each server's store (a test's, over a fake route).
@MainActor
func makeTestAppRoot(
    coordinator: ConnectionCoordinator? = nil,
    themeStore: ThemeStore = ThemeStore(),
    composerDraftStore: ComposerDraftStore? = nil,
    sessionRows: SessionRowDisplayStore = SessionRowDisplayStore(fixed: SessionRowDisplay()),
    liveVoiceCalls: LiveVoiceCallCenter = LiveVoiceCallCenter(),
    settings: SettingsStore? = nil,
    serverSettings: ((String) -> SettingsStore)? = nil
) -> AppRootEnvironment {
    let coordinator = coordinator ?? ConnectionCoordinator(serverStore: ServerStore())
    if let settings { coordinator.deviceSettings = settings }
    if let serverSettings { coordinator.makeServerSettings = serverSettings }
    return AppRootEnvironment(
        coordinator: coordinator,
        navigation: AppNavigation(),
        themeStore: themeStore,
        quickCommentTemplateStore: QuickCommentTemplateStore(templates: []),
        composerDraftStore: composerDraftStore ?? ComposerDraftStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "test-app-root-drafts-\(UUID().uuidString).json", directoryHint: .notDirectory),
            saveDelay: .seconds(60)
        ),
        chatReaderPayloadStore: ChatReaderPayloadStore(),
        sessionRows: sessionRows,
        liveVoiceCalls: liveVoiceCalls
    )
}

/// App root services whose coordinator has `serverId` paired and active, so a
/// screen's server switch to it succeeds at once, reading through `apiClient`.
/// The server lives only in memory, never in the Keychain.
@MainActor
func makeTestAppRoot(
    readyServerId serverId: String,
    apiClient: APIClient,
    settings: SettingsStore? = nil,
    serverSettings: ((String) -> SettingsStore)? = nil
) async throws -> AppRootEnvironment {
    try await makeTestAppRoot(
        readyServers: [TestReadyServer(id: serverId, client: apiClient)],
        settings: settings,
        serverSettings: serverSettings
    )
}

/// App root services for a host switch: `firstId` active on `ready-server.test`, the one a
/// screen opened for, and `otherId` paired beside it as `Other`. Both read through
/// `TestURLProtocol`, so the test's `routeScope` answers them.
@MainActor
func makeTestTwoServerRoot(
    firstId: String,
    otherId: String,
    otherName: String = "Other",
    otherHost: String = "other-server.test"
) async throws -> AppRootEnvironment {
    try await makeTestAppRoot(readyServers: [
        TestReadyServer(id: firstId, client: makeTestURLProtocolClient(host: "ready-server.test")),
        TestReadyServer(
            id: otherId, name: otherName, host: otherHost,
            client: makeTestURLProtocolClient(host: otherHost)
        ),
    ])
}

/// One server for `makeTestAppRoot(readyServers:)`: paired as `name`, reached through
/// `client`. Its fingerprint is its id, so the server store lists it under `id`.
struct TestReadyServer {
    var id: String
    var name: String = "Ready"
    var host: String = "ready-server.test"
    var client: APIClient
}

/// App root services whose coordinator has `readyServers` paired and the first active,
/// so a screen's host switch to any of them succeeds at once, each reading through its
/// own `client`. The servers live only in memory, never in the Keychain.
@MainActor
func makeTestAppRoot(
    readyServers: [TestReadyServer],
    settings: SettingsStore? = nil,
    serverSettings: ((String) -> SettingsStore)? = nil
) async throws -> AppRootEnvironment {
    let servers = try readyServers.enumerated().map { index, setup in
        try #require(PairedServer(
            from: ServerCredentials(
                host: setup.host,
                port: 7749,
                token: "sk_test",
                name: setup.name,
                scheme: .https,
                serverFingerprint: setup.id
            ),
            sortOrder: index
        ))
    }
    let serverStore = ServerStore()
    serverStore.replaceServersForPreview(servers)
    let coordinator = ConnectionCoordinator(serverStore: serverStore)
    for (server, setup) in zip(servers, readyServers) {
        await coordinator.ensureTestConnectionReady(for: server).setAPIClientForTesting(setup.client)
    }
    let first = try #require(servers.first)
    #expect(coordinator.restoreActiveServer(first.id))
    return makeTestAppRoot(coordinator: coordinator, settings: settings, serverSettings: serverSettings)
}

extension ExtensionSurfaceStore {
    /// The session's whole surface, or nil when it shows nothing.
    func state(for sessionId: String) -> ExtensionSurfaceState? {
        let state = surface(for: sessionId).state
        return state.hasRetainedContent ? state : nil
    }
}

/// The server a test caches chat history under: traces are cached per server,
/// so a connection (or session store) that reads or writes one needs a server id.
let testTraceCacheServerId = "sha256:test-trace-cache"

/// `/server/info` of a server that streams sessions: what a test connection's
/// setup reads in memory instead of over the network.
func makeTestServerInfo(appEventStream: Bool = false) -> ServerInfo {
    ServerInfo(
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
            appEventStream: appEventStream ? .init(version: 1) : nil,
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
}

/// Configure `connection` through the production setup path (`configureForUse`),
/// answering its authenticated `/server/info` bootstrap in memory. `apiClient`,
/// when given, is the client the setup installs (a `TestURLProtocol` client keeps
/// every later request off the network).
@MainActor
@discardableResult
func configureTestConnection(
    _ connection: ServerConnection,
    credentials: ServerCredentials = makeTestCredentials(),
    serverInfo: ServerInfo = makeTestServerInfo(),
    apiClient: APIClient? = nil
) async -> Bool {
    if let apiClient {
        return await connection.configureForUse(
            credentials: credentials,
            apiClientFactory: { _, _ in apiClient },
            serverInfoBootstrap: { _, _ in serverInfo }
        )
    }
    return await connection.configureForUse(
        credentials: credentials,
        serverInfoBootstrap: { _, _ in serverInfo }
    )
}

/// A first setup that fails the way an unreachable server does (`/server/info`
/// times out): no route is committed and the failure stays retryable, so a
/// focused-stream bind waits for the route instead of failing.
@MainActor
func failTestConnectionSetupTemporarily(
    _ connection: ServerConnection,
    credentials: ServerCredentials = makeTestCredentials()
) async {
    let configured = await connection.configureForUse(
        credentials: credentials,
        apiClientFactory: { _, _ in makeTestURLProtocolClient(host: credentials.host) },
        serverInfoBootstrap: { _, _ in throw URLError(.timedOut) }
    )
    #expect(!configured)
    #expect(connection.canRetryInitialTransportOnTimer)
}

extension ConnectionCoordinator {
    /// Prepare `server` through `ensureConnectionReady`, the path navigation uses,
    /// with its `/server/info` bootstrap answered in memory and no wait for Bonjour.
    /// A coordinator whose test already set those answers keeps them.
    @discardableResult
    func ensureTestConnectionReady(for server: PairedServer) async -> ServerConnection {
        answerTestSetupInMemory()
        return await ensureConnectionReady(for: server)
    }

    /// `switchToServerReady` with the setup answers of `ensureTestConnectionReady`.
    @discardableResult
    func switchToTestServer(_ server: PairedServer) async -> Bool {
        answerTestSetupInMemory()
        return await switchToServerReady(server)
    }

    @discardableResult
    func switchToTestServer(_ serverId: String) async -> Bool {
        answerTestSetupInMemory()
        return await switchToServerReady(serverId)
    }

    /// `addServerReady` with the setup answers of `ensureTestConnectionReady`.
    @discardableResult
    func addTestServer(_ server: PairedServer, switchTo: Bool = true) async -> ServerPairingOutcome {
        answerTestSetupInMemory()
        return await addServerReady(server, switchTo: switchTo)
    }

    private func answerTestSetupInMemory() {
        if _serverInfoBootstrapForTesting == nil {
            _serverInfoBootstrapForTesting = { _, _ in makeTestServerInfo() }
        }
        if _initialLANEndpointForTesting == nil {
            _initialLANEndpointForTesting = { _ in nil }
        }
    }
}

@MainActor
func makeTestConnection(
    sessionId: String = "s1",
    fingerprint: String? = nil
) async -> (conn: ServerConnection, pipe: TestEventPipeline) {
    let connection = ServerConnection()
    await configureTestConnection(connection, credentials: makeTestCredentials(fingerprint: fingerprint))
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

/// A window that publishes `root`, the same trait `AppRootEnvironment.near()`
/// reads in the app, so a producer's tap can find the opener.
@MainActor
func makeAppRootWindow(_ root: AppRootEnvironment) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.traitOverrides.appRootEnvironment = root
    window.isHidden = false
    return window
}

/// Where a test drops an evidence file (a screenshot). `OPPI_TEST_ARTIFACTS`
/// when set, otherwise the temporary directory; never the source tree.
func testArtifactURL(_ name: String, in subdirectory: String? = nil) throws -> URL {
    var directory = ProcessInfo.processInfo.environment["OPPI_TEST_ARTIFACTS"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appending(path: "oppi-test-artifacts", directoryHint: .isDirectory)
    if let subdirectory { directory.append(path: subdirectory, directoryHint: .isDirectory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: name, directoryHint: .notDirectory)
}

/// Files from `OppiTests/Fixtures`, which the test bundle carries flat
/// (`project.yml` bundles every non-source file of the OppiTests group).
enum TestFixtures {
    private final class BundleAnchor {}

    static var bundle: Bundle { Bundle(for: BundleAnchor.self) }

    static func url(_ fileName: String) throws -> URL {
        let name = fileName as NSString
        return try #require(
            bundle.url(
                forResource: name.deletingPathExtension,
                withExtension: name.pathExtension.isEmpty ? nil : name.pathExtension
            ),
            "Missing \(fileName) in the OppiTests bundle"
        )
    }
}

/// The cross-language contract fixtures under the repository's `protocol/`
/// directory. `project.yml` copies that directory into the OppiTests bundle,
/// so tests read the shipped files without computing a path from their own
/// source location.
enum ProtocolFixtures {
    /// `protocol/<path>` inside the test bundle. Throws when the file is missing.
    static func url(_ path: String) throws -> URL {
        let url = try #require(TestFixtures.bundle.resourceURL, "OppiTests bundle has no resource directory")
            .appending(path: "protocol/\(path)", directoryHint: .notDirectory)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "Missing protocol/\(path) in the OppiTests bundle; is the protocol folder a resource in project.yml?"
        )
        return url
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }
}

/// Takes a test window off screen without leaving its keyboard behind.
///
/// Hiding a window does not resign its first responder. When the window (and
/// the focused field in it) goes away mid keyboard transition, the simulator's
/// software keyboard stays up with no responder left to resign it, and it keeps
/// the keyboard layout guide raised in every later test: the SSH terminal bar
/// test read a keyboard none of its own code showed. End editing first, so
/// UIKit runs the keyboard's dismissal for this window.
@MainActor
func hideTestWindow(_ window: UIWindow) {
    window.endEditing(true)
    window.isHidden = true
}

/// Closes an open inline review-comment composer the way its Cancel button
/// does. Tests that leave one open would otherwise hide their window with a
/// live input still focused, which keeps the simulator keyboard up for the rest
/// of the run (see `hideTestWindow(_:)`).
@MainActor
func closeInlineComposer(in root: UIView) {
    func search(_ view: UIView) -> ReviewCommentInlineDraftView? {
        if let composer = view as? ReviewCommentInlineDraftView { return composer }
        for child in view.subviews {
            if let found = search(child) { return found }
        }
        return nil
    }
    search(root)?.dismiss(animated: false)
}

/// Forgets every lock flag on `ScopedLockService.shared`.
///
/// `ChatReaderViewController` reads the process-wide service and replaces the
/// reader with the lock cover whenever any flag exists, because it cannot tell
/// which chat an origin-less payload came from. The service loads its flags from
/// the test host's `UserDefaults.standard`, so a flag already stored there (the
/// origin is unknown) blanks every hosted reader test at once. A test that
/// renders a reader calls this first so it does not depend on that state.
@MainActor
func forgetSharedScopedLockFlags() {
    let locks = ScopedLockService.shared
    for serverId in Set(locks.flags.map(\.serverId)) {
        locks.forgetServer(serverId)
    }
}
