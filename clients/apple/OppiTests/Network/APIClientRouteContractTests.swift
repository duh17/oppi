import Foundation
import Testing
@testable import Oppi

/// The client half of the route contract: `protocol/routes.json` (generated from the server's
/// `server/src/routes/registry.ts`) lists every route the server answers, and every `APIClient`
/// endpoint method must build a request for one of them.
///
/// One row here per endpoint method, with placeholder ids that survive path interpolation. The
/// test drives each row through `TestURLProtocol` and checks the method and path it sent, so a
/// typo'd path, a wrong verb, or a route the server dropped fails before any screen or transport
/// refactor can ship it. This is the only coverage most of these methods have.
///
/// Not driven here, and why:
/// - `makeHostFileMediaSource`, `makeWorkspaceMediaSource`, `makeSessionFileMediaSource`,
///   `makeGitBlobMediaSource`, `makeSessionAttachmentMediaSource`: they return an `AuthenticatedMediaSource`
///   and send nothing, so no request reaches the protocol double.
/// - `fileEditingCapability(for:)`: a synchronous read of the capabilities `/server/info` recorded.
/// - `uploadMetricKitPayload`, `uploadClientLogs`: both return before building a request unless
///   `TelemetrySettings.allowsRemoteDiagnosticsUpload` is on, which it is not under test.
/// - `get`, `post`, `put`, `patch`, `delete` and their `as:` forms, `request` (five overloads),
///   `performAuthorized`, `performData`, `putAttachmentContent`, `makeURL` (three),
///   `percentEncodePathSegment`, `checkStatus`, `attachAuthSession`, `setResponseFailureObserver`:
///   transport mechanics and URL building, exercised through every row above.
struct APIClientRouteContractTests {
    @Test func everyAPIClientRequestMatchesARegisteredServerRoute() async throws {
        let registry = try RouteRegistry()
        let recorder = RequestRecorder()
        let scope = TestURLProtocol.routeScope { request in try recorder.answer(request) }
        defer { scope.end() }

        let client = makeTestURLProtocolClient()
        // The file-editing rows refuse to build a request until `/server/info` advertises them.
        _ = try? await client.serverInfo()

        var unregistered: [String] = []
        var silent: [String] = []
        for endpoint in APIClientEndpoint.all {
            recorder.begin()
            await endpoint.drive(client)
            let requests = recorder.drain()
            if requests.isEmpty { silent.append(endpoint.name) }
            for request in requests where !registry.matches(method: request.method, path: request.path) {
                unregistered.append("\(endpoint.name) → \(request.method) \(request.path)")
            }
        }

        #expect(
            unregistered.isEmpty,
            "APIClient requests that match no route in protocol/routes.json: \(unregistered.joined(separator: "; "))"
        )
        #expect(
            silent.isEmpty,
            "endpoint rows that sent no request (a guard or a throw now runs before the request): \(silent.joined(separator: ", "))"
        )
    }

    @Test func endpointRowsNameEachMethodOnce() {
        let names = APIClientEndpoint.all.map(\.name)
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicates.isEmpty, "duplicate endpoint rows: \(duplicates.sorted().joined(separator: ", "))")
    }

    @Test func routeTemplatesMatchOnlyTheirOwnPaths() throws {
        let registry = try RouteRegistry()
        #expect(registry.matches(method: "GET", path: "/sessions/s1"))
        #expect(registry.matches(method: "GET", path: "/workspaces/ws1/sessions/s1/tool-output/tc1"))
        #expect(registry.matches(method: "GET", path: "/workspaces/ws1/contents/src/Button.tsx"))
        #expect(registry.matches(method: "GET", path: "/workspaces/ws1/contents/"))
        // A path the server does not serve, a verb it does not allow, and one segment too many.
        #expect(!registry.matches(method: "GET", path: "/sessions/s1/nope"))
        #expect(!registry.matches(method: "PATCH", path: "/health"))
        // `stop` is a POST row: the path exists, the verb does not.
        #expect(!registry.matches(method: "GET", path: "/workspaces/ws1/sessions/s1/stop"))
    }
}

// MARK: - The fixture

/// `protocol/routes.json`: the server's route table as the client reads it.
private struct RouteRegistry {
    struct Row: Decodable {
        let method: String
        let path: String
        let params: [String]
    }

    private struct Document: Decodable {
        let routes: [Row]
    }

    private let rows: [Row]

    init() throws {
        rows = try JSONDecoder().decode(Document.self, from: ProtocolFixtures.data("routes.json")).routes
    }

    func matches(method: String, path: String) -> Bool {
        rows.contains { row in row.method == method && Self.matches(template: row.path, path: path) }
    }

    /// Segment-wise match: a literal segment must be equal, `{name}` and `:name` take one
    /// segment, and `{name+}` takes the rest of the path (at least one segment).
    static func matches(template: String, path: String) -> Bool {
        let templateSegments = template.split(separator: "/", omittingEmptySubsequences: true)
        let pathSegments = path.split(separator: "/", omittingEmptySubsequences: true)
        var index = 0
        for segment in templateSegments {
            if let takesRest = paramTakesRest(segment) {
                if takesRest { return pathSegments.count > index }
                guard index < pathSegments.count else { return false }
            } else {
                guard index < pathSegments.count, segment == pathSegments[index] else { return false }
            }
            index += 1
        }
        return index == pathSegments.count
    }

    /// Nil for a literal segment; otherwise whether the param spans the rest of the path.
    private static func paramTakesRest(_ segment: Substring) -> Bool? {
        if segment.hasPrefix("{"), segment.hasSuffix("}") {
            return segment.hasSuffix("+}")
        }
        if segment.hasPrefix(":") { return false }
        return nil
    }
}

// MARK: - The recording double

/// Answer every request with a JSON body and keep the method and path of each one.
private final class RequestRecorder: @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
    }

    private let lock = NSLock()
    private var pending: [Recorded] = []

    func begin() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    func drain() -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        let requests = pending
        pending.removeAll()
        return requests
    }

    func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        lock.lock()
        pending.append(Recorded(method: request.httpMethod ?? "GET", path: url.path))
        lock.unlock()
        let body = url.path == "/server/info" ? Self.serverInfo : Data("{}".utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw URLError(.badServerResponse)
        }
        return (body, response)
    }

    /// Every editing capability on, so `/files/current` rows can run. Shape from
    /// `APIClientWorkspaceFileEditingTests`, which pins the same decode.
    private static let serverInfo = Data("""
    {"name":"Test","version":"1.0","uptime":1,"os":"darwin","arch":"arm64","hostname":"test",\
    "nodeVersion":"22","piVersion":"1","configVersion":1,"capabilities":{\
    "workspaceFileEditing":{"version":1,"maxBytes":1048576},\
    "skillFileEditing":{"version":1,"maxBytes":1048576},\
    "piFileEditing":{"version":1,"maxBytes":1048576},\
    "fileEditOrigins":{"version":1,"maxBytes":1048576}},\
    "stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,\
    "modelCount":0}}
    """.utf8)
}

// MARK: - The endpoint table

/// One endpoint method: its name, and a call with placeholder arguments. Errors are ignored —
/// the request is what this file checks.
private struct APIClientEndpoint {
    let name: String
    let drive: @Sendable (APIClient) async -> Void

    init(_ name: String, _ drive: @escaping @Sendable (APIClient) async -> Void) {
        self.name = name
        self.drive = drive
    }
}

private enum Placeholder {
    static let workspace = "ws1"
    static let session = "s1"
    static let agent = "ag1"
    static let schedule = "sch1"
    static let toolCall = "tc1"
    static let attachment = "att1"
    static let flow = "fl1"
    static let name = "n1"
    static let path = "dir/notes.md"
    static let devicePublicKey = DevicePublicKey(x: "x", y: "y")
    static let since = Date(timeIntervalSince1970: 1_700_000_000)
    static let until = Date(timeIntervalSince1970: 1_700_086_400)
    static let upload = FileManager.default.temporaryDirectory
        .appending(path: "oppi-route-contract-upload.bin")

    static func writeUploadFile() {
        try? Data("attachment".utf8).write(to: upload)
    }
}

extension APIClientEndpoint {
    static let all: [APIClientEndpoint] = healthAndAuth + sessions + agentRoutes + settingsRoutes +
        diagnosticsRoutes + mcpRoutes + serverMetricRoutes + serverResourceRoutes + dictationRoutes

    // MARK: Health & Auth

    private static let healthAndAuth: [APIClientEndpoint] = [
        APIClientEndpoint("health") { _ = try? await $0.health() },
        APIClientEndpoint("health(timeoutInterval:)") { _ = try? await $0.health(timeoutInterval: 5) },
        APIClientEndpoint("pairDevice") {
            _ = try? await $0.pairDevice(pairingToken: "pt", devicePublicKey: Placeholder.devicePublicKey)
        },
        APIClientEndpoint("startPairDevice") {
            _ = try? await $0.startPairDevice(pairingToken: "pt", devicePublicKey: Placeholder.devicePublicKey)
        },
        APIClientEndpoint("pollPairingApprovalStatus") {
            _ = try? await $0.pollPairingApprovalStatus(approvalId: "ap1", pendingToken: "pend1")
        },
        APIClientEndpoint("listPairingApprovals") { _ = try? await $0.listPairingApprovals() },
        APIClientEndpoint("approvePairingApproval") {
            try? await $0.approvePairingApproval(id: "ap1", signature: "sig1")
        },
        APIClientEndpoint("denyPairingApproval") { try? await $0.denyPairingApproval(id: "ap1") },
        APIClientEndpoint("issueTailscalePairingInvite") {
            _ = try? await $0.issueTailscalePairingInvite()
        },
        APIClientEndpoint("me") { _ = try? await $0.me() },
        APIClientEndpoint("listAuthDevices") { _ = try? await $0.listAuthDevices() },
        APIClientEndpoint("revokeAuthDevice") { try? await $0.revokeAuthDevice(id: "d1") },
        APIClientEndpoint("serverInfo") { _ = try? await $0.serverInfo() },
        APIClientEndpoint("startServerUpdate") {
            _ = try? await $0.startServerUpdate(version: "1.2.3")
        },
        APIClientEndpoint("serverInfo(bootstrapDeadline:)") {
            _ = try? await $0.serverInfo(bootstrapDeadline: .after(.seconds(5)))
        },
        APIClientEndpoint("fetchStats") { _ = try? await $0.fetchStats(range: .week) },
        APIClientEndpoint("fetchDailyDetail") {
            _ = try? await $0.fetchDailyDetail(date: "2026-11-02")
        },
        APIClientEndpoint("fetchProviderQuotas") { _ = try? await $0.fetchProviderQuotas() },
        APIClientEndpoint("requestChallenge") {
            _ = try? await $0.requestChallenge(deviceId: "d1")
        },
        APIClientEndpoint("refresh") {
            _ = try? await $0.refresh(deviceId: "d1", nonce: "n1", signature: "sig1")
        },
        APIClientEndpoint("listModels") { _ = try? await $0.listModels() },
        APIClientEndpoint("listProviderAuthStatus") { _ = try? await $0.listProviderAuthStatus() },
        APIClientEndpoint("startProviderAuthFlow") {
            _ = try? await $0.startProviderAuthFlow(providerId: Placeholder.name)
        },
        APIClientEndpoint("getProviderAuthFlow") {
            _ = try? await $0.getProviderAuthFlow(flowId: Placeholder.flow)
        },
        APIClientEndpoint("submitProviderAuthPromptResponse") {
            _ = try? await $0.submitProviderAuthPromptResponse(flowId: Placeholder.flow, value: "v")
        },
        APIClientEndpoint("submitProviderAuthManualCode") {
            _ = try? await $0.submitProviderAuthManualCode(flowId: Placeholder.flow, input: "code")
        },
        APIClientEndpoint("cancelProviderAuthFlow") {
            _ = try? await $0.cancelProviderAuthFlow(flowId: Placeholder.flow)
        },
        APIClientEndpoint("setProviderAPIKey") {
            try? await $0.setProviderAPIKey(providerId: Placeholder.name, key: "sk-test")
        },
        APIClientEndpoint("removeProviderCredential") {
            try? await $0.removeProviderCredential(providerId: Placeholder.name)
        },
        APIClientEndpoint("listThemes") { _ = try? await $0.listThemes() },
        APIClientEndpoint("getTheme") { _ = try? await $0.getTheme(name: Placeholder.name) },
    ]

    // MARK: Sessions, workspaces, git, files

    private static let sessions: [APIClientEndpoint] = [
        APIClientEndpoint("searchSessions") { _ = try? await $0.searchSessions(query: "looking") },
        APIClientEndpoint("getSessionEvents(workspace)") {
            _ = try? await $0.getSessionEvents(scope: .workspace(Placeholder.workspace), id: Placeholder.session, since: 0)
        },
        APIClientEndpoint("getSessionEvents(control)") {
            _ = try? await $0.getSessionEvents(scope: .control, id: Placeholder.session, since: 0)
        },
        APIClientEndpoint("getSession(scope:workspace)") {
            _ = try? await $0.getSession(scope: .workspace(Placeholder.workspace), sessionId: Placeholder.session, traceView: .context)
        },
        APIClientEndpoint("getSession") {
            _ = try? await $0.getSession(scope: .control, sessionId: Placeholder.session, traceView: .context)
        },
        APIClientEndpoint("getSessionRecord") {
            _ = try? await $0.getSessionRecord(sessionId: Placeholder.session)
        },
        APIClientEndpoint("getSessionDialogs") {
            _ = try? await $0.getSessionDialogs(sessionId: Placeholder.session)
        },
        APIClientEndpoint("getSessionTracePage(workspace)") {
            _ = try? await $0.getSessionTracePage(scope: .workspace(Placeholder.workspace), sessionId: Placeholder.session)
        },
        APIClientEndpoint("getSessionTracePage(control)") {
            _ = try? await $0.getSessionTracePage(scope: .control, sessionId: Placeholder.session)
        },
        APIClientEndpoint("getSessionTraceOutline") {
            _ = try? await $0.getSessionTraceOutline(scope: .control, sessionId: Placeholder.session)
        },
        APIClientEndpoint("stopSession(workspace)") {
            _ = try? await $0.stopSession(scope: .workspace(Placeholder.workspace), sessionId: Placeholder.session)
        },
        APIClientEndpoint("stopSession(control)") {
            _ = try? await $0.stopSession(scope: .control, sessionId: Placeholder.session)
        },
        APIClientEndpoint("deleteSession(workspace)") {
            try? await $0.deleteSession(scope: .workspace(Placeholder.workspace), sessionId: Placeholder.session)
        },
        APIClientEndpoint("deleteSession(control)") {
            try? await $0.deleteSession(scope: .control, sessionId: Placeholder.session)
        },
        APIClientEndpoint("sendSessionCommand(workspace)") {
            try? await $0.sendSessionCommand(
                scope: .workspace(Placeholder.workspace), sessionId: Placeholder.session, message: .stop()
            )
        },
        APIClientEndpoint("sendSessionCommand(control)") {
            try? await $0.sendSessionCommand(scope: .control, sessionId: Placeholder.session, message: .stop())
        },
        APIClientEndpoint("sendExtensionUIResponse(workspace)") {
            try? await $0.sendExtensionUIResponse(
                scope: .workspace(Placeholder.workspace),
                sessionId: Placeholder.session,
                id: "ui1",
                payload: ExtensionUIResponsePayload(value: "v")
            )
        },
        APIClientEndpoint("sendExtensionUIResponse(control)") {
            try? await $0.sendExtensionUIResponse(
                scope: .control,
                sessionId: Placeholder.session,
                id: "ui1",
                payload: ExtensionUIResponsePayload(cancelled: true)
            )
        },
        APIClientEndpoint("listWorkspaceCatalog") { _ = try? await $0.listWorkspaceCatalog() },
        APIClientEndpoint("listWorkspaces") { _ = try? await $0.listWorkspaces() },
        APIClientEndpoint("listWorkspaceWorktrees") {
            _ = try? await $0.listWorkspaceWorktrees(workspaceId: Placeholder.workspace)
        },
        APIClientEndpoint("createWorkspace") {
            _ = try? await $0.createWorkspace(CreateWorkspaceRequest(name: "W"))
        },
        APIClientEndpoint("updateWorkspace") {
            _ = try? await $0.updateWorkspace(id: Placeholder.workspace, UpdateWorkspaceRequest(name: "W"))
        },
        APIClientEndpoint("deleteWorkspace") { try? await $0.deleteWorkspace(id: Placeholder.workspace) },
        APIClientEndpoint("getGitGraph") {
            _ = try? await $0.getGitGraph(workspaceId: Placeholder.workspace, worktreeId: nil)
        },
        APIClientEndpoint("getCommitDetail") {
            _ = try? await $0.getCommitDetail(workspaceId: Placeholder.workspace, sha: "abc1234")
        },
        APIClientEndpoint("getCommitFileDiff") {
            _ = try? await $0.getCommitFileDiff(
                workspaceId: Placeholder.workspace, sha: "abc1234", path: Placeholder.path
            )
        },
        APIClientEndpoint("getGitBlob") {
            _ = try? await $0.getGitBlob(workspaceId: Placeholder.workspace, revision: "HEAD", path: Placeholder.path)
        },
        APIClientEndpoint("getWorkspaceGitSummary") {
            _ = try? await $0.getWorkspaceGitSummary(workspaceId: Placeholder.workspace)
        },
        APIClientEndpoint("getGitStatus") {
            _ = try? await $0.getGitStatus(workspaceId: Placeholder.workspace)
        },
        APIClientEndpoint("getWorkspaceReviewDiff") {
            _ = try? await $0.getWorkspaceReviewDiff(workspaceId: Placeholder.workspace, path: Placeholder.path)
        },
        APIClientEndpoint("getWorkspaceQuickActions") {
            _ = try? await $0.getWorkspaceQuickActions(workspaceId: Placeholder.workspace)
        },
        APIClientEndpoint("prepareWorkspaceQuickActionSelection") {
            _ = try? await $0.prepareWorkspaceQuickActionSelection(
                workspaceId: Placeholder.workspace, paths: [Placeholder.path], promptTemplateName: "review"
            )
        },
        APIClientEndpoint("createWorkspaceQuickActionSession") {
            _ = try? await $0.createWorkspaceQuickActionSession(
                workspaceId: Placeholder.workspace, paths: [Placeholder.path], promptTemplateName: "review"
            )
        },
        APIClientEndpoint("listSkills") { _ = try? await $0.listSkills() },
        APIClientEndpoint("setPiResourceEnabled") {
            try? await $0.setPiResourceEnabled(type: "skill", path: Placeholder.path, enabled: true)
        },
        APIClientEndpoint("listExtensions") { _ = try? await $0.listExtensions() },
        APIClientEndpoint("listDirectories") { _ = try? await $0.listDirectories() },
        APIClientEndpoint("getHostPathStatus") {
            _ = try? await $0.getHostPathStatus(path: "/Users/alex/workspace")
        },
        APIClientEndpoint("completeHostPath") {
            _ = try? await $0.completeHostPath(prefix: "/Users/alex/wor")
        },
        APIClientEndpoint("createHostPath") {
            _ = try? await $0.createHostPath(path: "/Users/alex/new-project")
        },
        APIClientEndpoint("getSkillDetail") {
            _ = try? await $0.getSkillDetail(name: Placeholder.name)
        },
        APIClientEndpoint("getSkillFile") {
            _ = try? await $0.getSkillFile(name: Placeholder.name, path: "SKILL.md")
        },
        APIClientEndpoint("getWorkspaceAttention") {
            _ = try? await $0.getWorkspaceAttention(workspaceId: Placeholder.workspace)
        },
        APIClientEndpoint("getWorkspaceSessionList") {
            _ = try? await $0.getWorkspaceSessionList(
                workspace: makeTestWorkspace(id: Placeholder.workspace),
                since: Placeholder.since,
                until: Placeholder.until
            )
        },
        APIClientEndpoint("getWorkspaceSessionListBucket") {
            _ = try? await $0.getWorkspaceSessionListBucket(
                workspaceId: Placeholder.workspace, since: Placeholder.since, until: Placeholder.until
            )
        },
        APIClientEndpoint("listRecentWorkspaceSessionSummaries") {
            _ = try? await $0.listRecentWorkspaceSessionSummaries()
        },
        APIClientEndpoint("listSessionsFromWorkspaces") {
            _ = try? await $0.listSessionsFromWorkspaces()
        },
        APIClientEndpoint("createWorkspaceSession") {
            _ = try? await $0.createWorkspaceSession(workspaceId: Placeholder.workspace, prompt: "hi")
        },
        APIClientEndpoint("createControlSession") {
            _ = try? await $0.createControlSession(APIClient.CreateControlSessionRequest(prompt: "hi"))
        },
        APIClientEndpoint("createSessionAttachmentUpload(workspace)") {
            _ = try? await $0.createSessionAttachmentUpload(
                scope: .workspace(Placeholder.workspace),
                sessionId: Placeholder.session,
                name: "a.png",
                mimeType: "image/png",
                sizeBytes: 8
            )
        },
        APIClientEndpoint("createSessionAttachmentUpload(control)") {
            _ = try? await $0.createSessionAttachmentUpload(
                scope: .control,
                sessionId: Placeholder.session,
                name: "a.png",
                mimeType: "image/png",
                sizeBytes: 8
            )
        },
        APIClientEndpoint("uploadSessionAttachmentContent(workspace,data:)") {
            _ = try? await $0.uploadSessionAttachmentContent(
                scope: .workspace(Placeholder.workspace),
                sessionId: Placeholder.session,
                attachmentId: Placeholder.attachment,
                data: Data("body".utf8)
            )
        },
        APIClientEndpoint("uploadSessionAttachmentContent(control,data:)") {
            _ = try? await $0.uploadSessionAttachmentContent(
                scope: .control,
                sessionId: Placeholder.session,
                attachmentId: Placeholder.attachment,
                data: Data("body".utf8)
            )
        },
        APIClientEndpoint("uploadSessionAttachmentContent(workspace,fileURL:)") {
            Placeholder.writeUploadFile()
            _ = try? await $0.uploadSessionAttachmentContent(
                scope: .workspace(Placeholder.workspace),
                sessionId: Placeholder.session,
                attachmentId: Placeholder.attachment,
                fileURL: Placeholder.upload
            )
        },
        APIClientEndpoint("uploadSessionAttachmentContent(control,fileURL:)") {
            Placeholder.writeUploadFile()
            _ = try? await $0.uploadSessionAttachmentContent(
                scope: .control,
                sessionId: Placeholder.session,
                attachmentId: Placeholder.attachment,
                fileURL: Placeholder.upload
            )
        },
        APIClientEndpoint("createWorkspaceSessionFromLocal") {
            _ = try? await $0.createWorkspaceSessionFromLocal(
                workspaceId: Placeholder.workspace, piSessionFile: "/tmp/session.jsonl"
            )
        },
        APIClientEndpoint("resumeSession(workspace)") {
            _ = try? await $0.resumeSession(scope: .workspace(Placeholder.workspace), sessionId: Placeholder.session)
        },
        APIClientEndpoint("resumeSession(control)") {
            _ = try? await $0.resumeSession(scope: .control, sessionId: Placeholder.session)
        },
        APIClientEndpoint("forkWorkspaceSession") {
            _ = try? await $0.forkWorkspaceSession(
                workspaceId: Placeholder.workspace, sessionId: Placeholder.session, entryId: "e1"
            )
        },
        APIClientEndpoint("getInputCardOutput") {
            _ = try? await $0.getInputCardOutput(
                scope: .control, sessionId: Placeholder.session, entryId: "e1"
            )
        },
        APIClientEndpoint("getInternalURLView(workspace)") {
            _ = try? await $0.getInternalURLView(
                scope: .workspace(Placeholder.workspace), sessionId: Placeholder.session, url: "proc://bash-1", from: 12
            )
        },
        APIClientEndpoint("getInternalURLView(control)") {
            _ = try? await $0.getInternalURLView(
                scope: .control, sessionId: Placeholder.session, url: "proc://bash-1", from: nil
            )
        },
        APIClientEndpoint("stopInternalURL(workspace)") {
            try? await $0.stopInternalURL(
                scope: .workspace(Placeholder.workspace), sessionId: Placeholder.session, url: "proc://bash-1"
            )
        },
        APIClientEndpoint("stopInternalURL(control)") {
            try? await $0.stopInternalURL(scope: .control, sessionId: Placeholder.session, url: "proc://bash-1")
        },
        APIClientEndpoint("getNonEmptyToolOutput(workspace)") {
            _ = try? await $0.getNonEmptyToolOutput(
                scope: .workspace(Placeholder.workspace), sessionId: Placeholder.session, toolCallId: Placeholder.toolCall
            )
        },
        APIClientEndpoint("getNonEmptyToolOutput(control)") {
            _ = try? await $0.getNonEmptyToolOutput(
                scope: .control, sessionId: Placeholder.session, toolCallId: Placeholder.toolCall
            )
        },
        APIClientEndpoint("getNonEmptyFullToolOutput(workspace)") {
            _ = try? await $0.getNonEmptyFullToolOutput(
                scope: .workspace(Placeholder.workspace), sessionId: Placeholder.session, toolCallId: Placeholder.toolCall
            )
        },
        APIClientEndpoint("getNonEmptyFullToolOutput(control)") {
            _ = try? await $0.getNonEmptyFullToolOutput(
                scope: .control, sessionId: Placeholder.session, toolCallId: Placeholder.toolCall
            )
        },
        APIClientEndpoint("headFullToolOutput") {
            _ = try? await $0.headFullToolOutput(
                scope: .control, sessionId: Placeholder.session, toolCallId: Placeholder.toolCall
            )
        },
        APIClientEndpoint("getTerminalOutputRange") {
            _ = try? await $0.getTerminalOutputRange(
                scope: .control, sessionId: Placeholder.session, toolCallId: Placeholder.toolCall, range: 0..<16
            )
        },
        APIClientEndpoint("getFullToolOutputSidecarWindow") {
            _ = try? await $0.getFullToolOutputSidecarWindow(
                scope: .control, sessionId: Placeholder.session, toolCallId: Placeholder.toolCall, startByte: 0
            )
        },
        APIClientEndpoint("openFullToolOutputSidecar") {
            _ = try? await $0.openFullToolOutputSidecar(
                scope: .control, sessionId: Placeholder.session, toolCallId: Placeholder.toolCall
            )
        },
        APIClientEndpoint("fetchSessionAttachment(session)") {
            _ = try? await $0.fetchSessionAttachment(
                scope: nil, sessionId: Placeholder.session, attachmentId: Placeholder.attachment
            )
        },
        APIClientEndpoint("fetchSessionAttachment(control)") {
            _ = try? await $0.fetchSessionAttachment(
                scope: .control, sessionId: Placeholder.session, attachmentId: Placeholder.attachment
            )
        },
        APIClientEndpoint("getSessionFileData") {
            _ = try? await $0.getSessionFileData(sessionId: Placeholder.session, path: Placeholder.path)
        },
        APIClientEndpoint("fetchWorkspaceFile") {
            _ = try? await $0.fetchWorkspaceFile(workspaceID: Placeholder.workspace, path: Placeholder.path)
        },
        APIClientEndpoint("listWorkspaceDirectory(root)") {
            _ = try? await $0.listWorkspaceDirectory(workspaceId: Placeholder.workspace)
        },
        APIClientEndpoint("listWorkspaceDirectory(subdirectory)") {
            _ = try? await $0.listWorkspaceDirectory(workspaceId: Placeholder.workspace, path: "src/")
        },
        APIClientEndpoint("listHostDirectory") { _ = try? await $0.listHostDirectory() },
        APIClientEndpoint("fetchFileIndex") {
            _ = try? await $0.fetchFileIndex(workspaceId: Placeholder.workspace)
        },
        APIClientEndpoint("browseWorkspaceFile") {
            _ = try? await $0.browseWorkspaceFile(workspaceId: Placeholder.workspace, path: Placeholder.path)
        },
        APIClientEndpoint("readFileForEditing") {
            _ = try? await $0.readFileForEditing(APIClientEndpoint.editableFile)
        },
        APIClientEndpoint("readFileForEditingOutcome") {
            _ = await $0.readFileForEditingOutcome(APIClientEndpoint.editableFile)
        },
        APIClientEndpoint("writeEditedFile") {
            _ = await $0.writeEditedFile(
                APIClientEndpoint.editableFile, bytes: Data("edited".utf8), condition: .version("\"tag-1\"")
            )
        },
        APIClientEndpoint("resolveFileForEditing") {
            _ = await $0.resolveFileForEditing(
                FileEditLocation(serverId: "s1", origin: .host(controlSessionId: nil), path: "/Users/alex/notes.md")
            )
        },
        APIClientEndpoint("resolveHostFile") {
            _ = try? await $0.resolveHostFile(path: "/Users/alex/notes.md")
        },
        APIClientEndpoint("browseHostFile") {
            _ = try? await $0.browseHostFile(path: "/Users/alex/notes.md")
        },
        APIClientEndpoint("browseHostFileContent") {
            _ = try? await $0.browseHostFileContent(path: "/Users/alex/notes.md")
        },
        APIClientEndpoint("listCurrentFileSidecars") {
            _ = try? await $0.listCurrentFileSidecars(
                .workspace(workspaceId: Placeholder.workspace, worktreeId: nil), mediaPath: "media/clip.mp4"
            )
        },
        APIClientEndpoint("listSessionChanges") {
            _ = try? await $0.listSessionChanges(
                workspaceId: Placeholder.workspace, sessionId: Placeholder.session
            )
        },
        APIClientEndpoint("getSessionDiff") {
            _ = try? await $0.getSessionDiff(
                workspaceId: Placeholder.workspace, sessionId: Placeholder.session, path: Placeholder.path
            )
        },
        APIClientEndpoint("putPushRegistration") {
            _ = try? await $0.putPushRegistration(
                PushRegistrationRequest(
                    keyId: "k1",
                    publicKey: "pk",
                    sendToken: "st",
                    relay: "https://relay.invalid",
                    issuedAt: 0,
                    signature: "sig",
                    liveActivity: false,
                    events: ["needs_you"]
                )
            )
        },
        APIClientEndpoint("deletePushRegistration") { try? await $0.deletePushRegistration() },
    ]

    private static let editableFile = WorkspaceFileEditIdentity(
        serverId: "srv1", workspaceId: Placeholder.workspace, worktreeId: nil, path: Placeholder.path
    )

    // MARK: Agents & schedules

    private static let agentRoutes: [APIClientEndpoint] = [
        APIClientEndpoint("uploadIconAsset") {
            _ = try? await $0.uploadIconAsset(data: Data("png".utf8), contentType: "image/png")
        },
        APIClientEndpoint("fetchIconAsset") {
            _ = try? await $0.fetchIconAsset(assetId: Placeholder.name)
        },
        APIClientEndpoint("listAgents") { _ = try? await $0.listAgents() },
        APIClientEndpoint("getAgent") { _ = try? await $0.getAgent(Placeholder.agent) },
        APIClientEndpoint("createAgent") {
            _ = try? await $0.createAgent(AgentDefinition(name: "Agent"))
        },
        APIClientEndpoint("setAgentDefaultModel") {
            _ = try? await $0.setAgentDefaultModel(
                agentId: Placeholder.agent, version: 1, model: "claude-4"
            )
        },
        APIClientEndpoint("updateAgentInstructions") {
            _ = try? await $0.updateAgentInstructions(
                agentId: Placeholder.agent, expectedVersion: 1, mode: .replace, text: "prompt"
            )
        },
        APIClientEndpoint("updateAgentSchedulePrompt") {
            _ = try? await $0.updateAgentSchedulePrompt(
                scheduleId: Placeholder.schedule, expectedVersion: 1, prompt: "prompt"
            )
        },
        APIClientEndpoint("updateAgentNative") {
            _ = try? await $0.updateAgentNative(
                agentId: Placeholder.agent,
                name: "Agent",
                description: nil,
                instructions: nil,
                capabilities: nil,
                context: nil,
                model: nil,
                thinkingLevel: nil
            )
        },
        APIClientEndpoint("updateAgentIcon") {
            _ = try? await $0.updateAgentIcon(agentId: Placeholder.agent, icon: .symbol("star"))
        },
        APIClientEndpoint("archiveAgent") { _ = try? await $0.archiveAgent(agentId: Placeholder.agent) },
        APIClientEndpoint("launchAgentSession") {
            _ = try? await $0.launchAgentSession(
                agentId: Placeholder.agent, prompt: "go", workspaceId: Placeholder.workspace
            )
        },
        APIClientEndpoint("listAgentSchedules") { _ = try? await $0.listAgentSchedules() },
        APIClientEndpoint("getAgentSchedule") {
            _ = try? await $0.getAgentSchedule(Placeholder.schedule)
        },
        APIClientEndpoint("createAgentSchedule") {
            _ = try? await $0.createAgentSchedule(
                name: "Nightly", trigger: APIClientEndpoint.dailyTrigger, action: APIClientEndpoint.newSessionAction
            )
        },
        APIClientEndpoint("updateAgentSchedule") {
            _ = try? await $0.updateAgentSchedule(
                scheduleId: Placeholder.schedule,
                name: "Nightly",
                trigger: APIClientEndpoint.dailyTrigger,
                action: APIClientEndpoint.newSessionAction
            )
        },
        APIClientEndpoint("updateAgentScheduleNative") {
            _ = try? await $0.updateAgentScheduleNative(
                scheduleId: Placeholder.schedule,
                name: "Nightly",
                trigger: APIClientEndpoint.dailyTrigger,
                action: APIClientEndpoint.newSessionAction
            )
        },
        APIClientEndpoint("pauseAgentSchedule") {
            _ = try? await $0.pauseAgentSchedule(Placeholder.schedule)
        },
        APIClientEndpoint("resumeAgentSchedule") {
            _ = try? await $0.resumeAgentSchedule(Placeholder.schedule)
        },
        APIClientEndpoint("archiveAgentSchedule") {
            _ = try? await $0.archiveAgentSchedule(Placeholder.schedule)
        },
        APIClientEndpoint("restoreAgentSchedule") {
            _ = try? await $0.restoreAgentSchedule(Placeholder.schedule)
        },
        APIClientEndpoint("runAgentSchedule") {
            _ = try? await $0.runAgentSchedule(Placeholder.schedule)
        },
        APIClientEndpoint("listAgentScheduleRuns") {
            _ = try? await $0.listAgentScheduleRuns(scheduleId: Placeholder.schedule)
        },
        APIClientEndpoint("scheduleCalendar") {
            _ = try? await $0.scheduleCalendar(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 86_400))
        },
    ]

    private static let dailyTrigger = AgentScheduleTrigger.cron(expression: "0 3 * * *", timeZone: "UTC")

    private static let newSessionAction = AgentScheduleAction.newSession(
        workspaceId: Placeholder.workspace,
        prompt: "Nightly review",
        agentId: nil,
        model: nil,
        thinkingLevel: nil,
        worktreeId: nil,
        name: nil
    )

    // MARK: Settings

    private static let settingsRoutes: [APIClientEndpoint] = SettingEndpoint.allCases.flatMap { endpoint in
        [
            APIClientEndpoint("loadSettings(\(endpoint.rawValue))") { _ = try? await $0.loadSettings(endpoint) },
            APIClientEndpoint("saveSettings(\(endpoint.rawValue))") {
                _ = try? await $0.saveSettings(endpoint, fields: ["enabled": .bool(true)], baseRevision: 1)
            },
        ]
    } + [
        APIClientEndpoint("durableSessionsSettings") { _ = try? await $0.durableSessionsSettings() },
        APIClientEndpoint("saveDurableSessionsSettings") {
            _ = try? await $0.saveDurableSessionsSettings(enabled: true, baseRevision: 1)
        },
    ]

    // MARK: Server metrics

    private static let serverMetricRoutes: [APIClientEndpoint] = [
        APIClientEndpoint("fetchServerMetrics") {
            _ = try? await $0.fetchServerMetrics(range: .week)
        },
        APIClientEndpoint("serverMetricsSettings") { _ = try? await $0.serverMetricsSettings() },
        APIClientEndpoint("serverMetricsEnabled") { _ = try? await $0.serverMetricsEnabled() },
        APIClientEndpoint("saveServerMetricsSettings") {
            _ = try? await $0.saveServerMetricsSettings(enabled: true)
        },
    ]

    // MARK: Server resources

    private static let serverResourceRoutes: [APIClientEndpoint] = [
        APIClientEndpoint("listServerSkills") { _ = try? await $0.listServerSkills() },
        APIClientEndpoint("getServerSkill") { _ = try? await $0.getServerSkill(id: "sk1") },
        APIClientEndpoint("setServerSkillEnabled") {
            _ = try? await $0.setServerSkillEnabled(id: "sk1", enabled: true)
        },
        APIClientEndpoint("listServerExtensions") { _ = try? await $0.listServerExtensions(plugins: true) },
        APIClientEndpoint("getServerExtension") { _ = try? await $0.getServerExtension(id: "ext1") },
        APIClientEndpoint("setServerExtensionEnabled") {
            _ = try? await $0.setServerExtensionEnabled(id: "ext1", enabled: true)
        },
        APIClientEndpoint("reloadServerExtensions") { _ = try? await $0.reloadServerExtensions() },
        APIClientEndpoint("getPiSystemPrompt") { _ = try? await $0.getPiSystemPrompt() },
        APIClientEndpoint("getPiDefaultTools") { _ = try? await $0.getPiDefaultTools() },
        APIClientEndpoint("setPiDefaultTools") { _ = try? await $0.setPiDefaultTools(["read"]) },
        APIClientEndpoint("setPiDefaultModel") { try? await $0.setPiDefaultModel("claude-4") },
        APIClientEndpoint("getMobileOutputGuideConfiguration") {
            _ = try? await $0.getMobileOutputGuideConfiguration()
        },
        APIClientEndpoint("setMobileOutputGuideConfiguration") {
            _ = try? await $0.setMobileOutputGuideConfiguration(enabled: true, baseRevision: 1)
        },
    ]

    // MARK: MCP

    private static let mcpRoutes: [APIClientEndpoint] = [
        APIClientEndpoint("listMcpServers") { _ = try? await $0.listMcpServers(scopeId: Placeholder.workspace) },
    ]

    // MARK: Diagnostics & dictation

    private static let diagnosticsRoutes: [APIClientEndpoint] = [
        APIClientEndpoint("uploadTelemetryEvents") {
            _ = try? await $0.uploadTelemetryEvents(
                request: TelemetryEventUploadRequest(generatedAt: 0, client: APIClientEndpoint.telemetryClient, events: [])
            )
        },
        APIClientEndpoint("speech") { _ = try? await $0.speech(text: "read this aloud") },
    ]

    private static let dictationRoutes: [APIClientEndpoint] = [
        APIClientEndpoint("dictationDictionary(global)") { _ = try? await $0.dictationDictionary(workspaceId: nil) },
        APIClientEndpoint("dictationDictionary(workspace)") {
            _ = try? await $0.dictationDictionary(workspaceId: Placeholder.workspace)
        },
        APIClientEndpoint("saveDictationDictionary") {
            _ = try? await $0.saveDictationDictionary(
                workspaceId: Placeholder.workspace, revision: 1, phrases: ["Oppi"]
            )
        },
        APIClientEndpoint("listPins") { _ = try? await $0.listPins() },
        APIClientEndpoint("addPin") { _ = try? await $0.addPin(.hostFiles(path: "~/notebook")) },
        APIClientEndpoint("savePins") {
            _ = try? await $0.savePins(baseRevision: 1, [PinOrderEntry(id: "pin_Notebook0001", label: nil)])
        },
    ]

    private static let telemetryClient = TelemetryClientInfo(
        kind: .ios,
        appVersion: nil,
        buildNumber: nil,
        gitCommit: nil,
        osVersion: nil,
        deviceModel: nil,
        appInstanceId: nil,
        bootId: nil,
        debugBuild: nil
    )
}
