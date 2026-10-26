#if DEBUG
import UIKit

/// The workspace shell with a Live Voice call on a fake channel, so the call strip and the
/// session row's call badge can be captured without a server or a microphone
/// (`SCREENSHOT_SCREEN=live-voice-call-strip`). `SCREENSHOT_CALL_STRIP` picks the call's
/// state: `live` (default), `connecting`, `muted`, `failed`, `none` (the same screen with no
/// call, the baseline to compare against), or `untitled` (a call whose
/// session title is unknown or locked: the strip says "Live Voice"). `SCREENSHOT_COLOR_SCHEME=dark|light`
/// pins the theme.
@MainActor
enum LiveVoiceCallStripScreenshotPreview {
    enum Variant: String {
        case live, connecting, muted, failed, untitled, none
    }

    static let root: AppRootEnvironment = {
        let environment = ProcessInfo.processInfo.environment
        let variant = Variant(rawValue: environment["SCREENSHOT_CALL_STRIP"] ?? "") ?? .live
        // Before `ThemeStore()` reads it.
        switch environment["SCREENSHOT_COLOR_SCHEME"] {
        case "dark": ScreenshotVolatileDefaults.applyTheme(.dark)
        case "light": ScreenshotVolatileDefaults.applyTheme(.light)
        default: break
        }
        let calls = LiveVoiceCallCenter {
            LiveVoiceCallController(
                channel: PreviewCallChannel(variant: variant),
                memory: PreviewCallMemory()
            )
        }
        let coordinator = makeCoordinator()
        let root = AppRootEnvironment(
            coordinator: coordinator,
            navigation: AppNavigation(),
            themeStore: ThemeStore(),
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay()),
            liveVoiceCalls: calls
        )
        let sessionId = variant == .untitled ? "not-listed" : "call-session"
        if variant != .none, let call = calls.placeCall(serverId: server.id, sessionId: sessionId) {
            Task { @MainActor in
                await call.start(sessionId: sessionId, routeScope: .workspace(workspaceId))
                if variant == .muted { call.toggleMute() }
            }
        }
        return root
    }()

    private static let workspaceId = "oppi"
    private static let server: PairedServer = {
        guard let server = PairedServer(from: ServerCredentials(
            host: "mac-studio.local",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            scheme: .https,
            serverFingerprint: "sha256:call-strip-preview",
            tlsCertFingerprint: "sha256:call-strip-preview-leaf"
        )) else {
            preconditionFailure("call strip preview server")
        }
        return server
    }()

    private static func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview([server])
        guard coordinator.switchToServer(server),
              let connection = coordinator.connection(for: server.id) else { return coordinator }
        connection.workspaceStore.upsert(Workspace(
            id: workspaceId,
            name: "oppi",
            description: "Preview workspace",
            icon: .symbol("iphone.and.arrow.forward"),
            systemPrompt: nil,
            hostMount: "~/workspace/oppi",
            gitStatusEnabled: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ), serverId: server.id)
        connection.sessionStore.switchServer(to: server.id)
        connection.sessionStore.sessions = [
            session(id: "call-session", name: "Plan the call strip", status: .busy, minutesAgo: 1),
            session(id: "other-session", name: "Tidy the release notes", status: .ready, minutesAgo: 14),
        ]
        return coordinator
    }

    private static func session(id: String, name: String, status: SessionStatus, minutesAgo: Double) -> Session {
        let lastActivity = Date().addingTimeInterval(-minutesAgo * 60)
        return Session(
            id: id,
            workspaceId: workspaceId,
            workspaceName: "oppi",
            name: name,
            status: status,
            createdAt: lastActivity.addingTimeInterval(-600),
            lastActivity: lastActivity,
            model: "anthropic/claude-opus-5-5",
            messageCount: 4,
            tokens: TokenUsage(input: 8_000, output: 1_200),
            cost: 0.18
        )
    }
}

/// A server that answers a call start: it confirms the call, stays connecting, or fails it.
@MainActor
private final class PreviewCallChannel: LiveVoiceCallChannel {
    let variant: LiveVoiceCallStripScreenshotPreview.Variant
    var onInboundAudio: (@MainActor (Data) -> Void)?
    private var continuation: AsyncStream<ServerMessage>.Continuation?
    private var sessionId = ""

    init(variant: LiveVoiceCallStripScreenshotPreview.Variant) {
        self.variant = variant
    }

    func open(sessionId: String, routeScope: SessionRouteScope) -> AsyncStream<ServerMessage> {
        self.sessionId = sessionId
        let (stream, continuation) = AsyncStream<ServerMessage>.makeStream()
        self.continuation = continuation
        continuation.yield(.streamConnected(userName: "preview", serverDictationAvailable: false))
        return stream
    }

    func send(_ message: ClientMessage) async throws {
        guard case .voiceCallStart(_, let requestId) = message else { return }
        switch variant {
        case .connecting:
            return
        case .failed:
            continuation?.yield(.commandResult(
                command: "voice_call_start",
                requestId: requestId,
                success: false,
                data: nil,
                error: "The server's voice backend stopped. Try again in a moment."
            ))
        case .live, .muted, .untitled, .none:
            continuation?.yield(.voiceCallState(VoiceCallStateSnapshot(
                callId: "preview-call",
                controlSessionId: sessionId,
                lifecycle: .active,
                frontend: .attached,
                controllerLeaseEpoch: 1,
                controllerLeaseExpiresAt: 30_000,
                eventSeq: 1,
                startedAt: 1_000,
                updatedAt: 2_000,
                delegations: [],
                partialTranscript: nil
            )))
        }
    }

    func sendAudio(_ pcm: Data) async throws {}

    func close() {
        continuation?.finish()
        continuation = nil
    }
}

/// Nothing written to the simulator's defaults.
@MainActor
private final class PreviewCallMemory: LiveVoiceSessionMemory {
    func callIdentity(forServer serverKey: String) -> LiveVoiceCallIdentity? { nil }
    func store(callIdentity: LiveVoiceCallIdentity, forServer serverKey: String) {}
    func clearCallIdentity(forServer serverKey: String) {}
}
#endif
