#if DEBUG
import SwiftUI

/// Short user / assistant / user exchange for speaker-chrome screenshots.
/// Screens: `chat-speaker-contrast-{dark,oled,night,light}` plus Dark Increase
/// Contrast and Differentiate Without Color variants.
struct ChatSpeakerContrastPreview: View {
    let themeID: ThemeID
    var increasedContrast: Bool = false
    var differentiateWithoutColor: Bool = false
    var legacyPaint: Bool = false

    @State private var connection = ServerConnection()
    @State private var sessionManager = ChatSessionManager(sessionId: "speaker-contrast")
    @State private var scrollController = ChatScrollController()
    @State private var audioPlayer = AudioPlayerService()
    @State private var audioLifecycleCoordinator = AudioLifecycleCoordinator()
    @State private var seeded = false

    init(
        themeID: ThemeID,
        increasedContrast: Bool = false,
        differentiateWithoutColor: Bool = false,
        legacyPaint: Bool = false
    ) {
        self.themeID = themeID
        self.increasedContrast = increasedContrast
        self.differentiateWithoutColor = differentiateWithoutColor
        self.legacyPaint = legacyPaint
        ThemeRuntimeState.setThemeID(themeID)
        TimelineSpeakerChrome.increasedContrastOverride = increasedContrast
        TimelineSpeakerChrome.differentiateWithoutColorOverride = differentiateWithoutColor
        TimelineSpeakerChrome.legacyScreenshotPaint = legacyPaint
    }

    var body: some View {
        NavigationStack {
            ChatTimelineView(
                sessionId: "speaker-contrast",
                serverId: nil,
                workspaceId: nil,
                isBusy: false,
                extensionWorkingState: nil,
                extensionHiddenThinkingLabel: nil,
                currentModel: nil,
                sessionContent: connection.sessionContent,
                iconAssetCache: nil,
                openDestination: nil,
                loadOlderPage: nil,
                scrollController: scrollController,
                sessionManager: sessionManager,
                audioLifecycleCoordinator: audioLifecycleCoordinator,
                onFork: { _ in },
                onOpenCurrentFile: { _ in },
                onBackSwipe: {},
                reviewCommentSelectionRouter: nil,
                topOverlap: 0,
                bottomOverlap: 0
            )
            .ignoresSafeArea(.container, edges: .top)
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(sessionManager.reducer)
        .environment(sessionManager.reducer.toolOutputStore)
        .environment(sessionManager.reducer.toolArgsStore)
        .environment(audioPlayer)
        .preferredColorScheme(themeID.preferredColorScheme)
        .task {
            guard !seeded else { return }
            seeded = true
            ThemeRuntimeState.setThemeID(themeID)
            TimelineSpeakerChrome.increasedContrastOverride = increasedContrast
            TimelineSpeakerChrome.differentiateWithoutColorOverride = differentiateWithoutColor
            TimelineSpeakerChrome.legacyScreenshotPaint = legacyPaint
            NotificationCenter.default.post(name: .oppiThemeDidChange, object: nil)
            seed(sessionManager.reducer)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private func seed(_ reducer: TimelineReducer) {
        _ = reducer.appendUserMessage("Hello")
        reducer.processBatch([
            .agentStart(sessionId: "speaker-contrast"),
            .messageEnd(
                sessionId: "speaker-contrast",
                content: "Here is a two-line reply.\nThe second line stays in this turn."
            ),
            .agentEnd(sessionId: "speaker-contrast"),
        ])
        _ = reducer.appendUserMessage("Can you make that clearer?")
    }
}
#endif
