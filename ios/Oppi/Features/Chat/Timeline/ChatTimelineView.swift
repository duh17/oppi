import SwiftUI

/// Extracted from ChatView so that @State inputText changes (every keystroke)
/// do NOT trigger a full ForEach re-diff of 200+ items.
///
/// As a separate View struct, this gets its own SwiftUI observation scope.
/// It only re-evaluates when its own dependencies change (reducer.items,
/// renderVersion, session status) — NOT when the parent's @State changes.
struct ChatTimelineView: View {
    private static let initialRenderWindow = 80
    private static let renderWindowStep = 60
    /// Guardrail for exact scroll restoration. Expanding the window to thousands
    /// of rows in one pass can stall placement on older devices.
    private static let maxRestorationWindow = 180

    let sessionId: String
    let workspaceId: String?
    let isBusy: Bool
    let scrollController: ChatScrollController
    let sessionManager: ChatSessionManager
    let onFork: (String) -> Void

    @Environment(TimelineReducer.self) private var reducer
    @Environment(ServerConnection.self) private var connection
    @Environment(AudioPlayerService.self) private var audioPlayer
    @Environment(\.theme) private var theme

    @State private var renderWindow = Self.initialRenderWindow
    @State private var fileToOpen: FileToOpen?
    @State private var scrollCommandNonce = 0
    @State private var pendingScrollCommand: ChatTimelineScrollCommand?

    private var visibleItems: ArraySlice<ChatItem> {
        reducer.items.suffix(renderWindow)
    }

    private var hiddenCount: Int {
        max(0, reducer.items.count - visibleItems.count)
    }

    private var showsWorkingIndicator: Bool {
        isBusy && reducer.streamingAssistantID == nil
    }

    private var bottomItemID: String? {
        if showsWorkingIndicator {
            return ChatTimelineCollectionHost.workingIndicatorID
        }
        return visibleItems.last?.id
    }

    var body: some View {
        ChatTimelineCollectionHost(
            configuration: .init(
                items: Array(visibleItems),
                hiddenCount: hiddenCount,
                renderWindowStep: Self.renderWindowStep,
                isBusy: isBusy,
                streamingAssistantID: reducer.streamingAssistantID,
                sessionId: sessionId,
                workspaceId: workspaceId,
                onFork: onFork,
                onOpenFile: { fileToOpen = $0 },
                onShowEarlier: {
                    renderWindow = min(reducer.items.count, renderWindow + Self.renderWindowStep)
                },
                scrollCommand: pendingScrollCommand,
                scrollController: scrollController,
                reducer: reducer,
                toolOutputStore: reducer.toolOutputStore,
                toolArgsStore: reducer.toolArgsStore,
                toolSegmentStore: reducer.toolSegmentStore,
                connection: connection,
                audioPlayer: audioPlayer,
                theme: theme,
                themeID: ThemeRuntimeState.currentThemeID()
            )
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PermissionOverlay(sessionId: sessionId)
        }
        .background(Color.themeBg)
        .overlay {
            if reducer.items.isEmpty && !isBusy {
                ChatEmptyState()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if scrollController.isJumpToBottomHintVisible {
                JumpToBottomHintButton(isStreaming: scrollController.isDetachedStreamingHintVisible) {
                    jumpToLatest()
                }
                .padding(.trailing, 27)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: scrollController.isJumpToBottomHintVisible)
        .onChange(of: reducer.renderVersion) { _, _ in
            scrollController.itemCount = visibleItems.count
            let hasNewItems = scrollController.consumeHasNewItems()
            scrollController.handleContentChange(
                isBusy: isBusy,
                streamingAssistantID: reducer.streamingAssistantID,
                bottomItemID: bottomItemID
            ) { _ in
                // Always target the actual bottom of the timeline.
                // During streaming, bottomItemID == streaming assistant (correct).
                // During tool calls, bottomItemID == latest tool or working indicator.
                guard let bottom = bottomItemID else { return }
                let animate = hasNewItems
                issueScrollCommand(id: bottom, anchor: .bottom, animated: animate)
            }
        }
        .onChange(of: sessionManager.needsInitialScroll) { _, needs in
            guard needs else { return }
            sessionManager.needsInitialScroll = false
            scrollController.needsInitialScroll = true
            scrollController.handleInitialScroll(bottomItemID: bottomItemID) { targetID in
                issueScrollCommand(id: targetID, anchor: .bottom, animated: false)
            }
        }
        .onChange(of: scrollController.scrollTargetID) { _, targetID in
            guard targetID != nil else { return }
            if let targetID, !visibleItems.contains(where: { $0.id == targetID }) {
                renderWindow = reducer.items.count
            }
            scrollController.handleScrollTarget { target in
                issueScrollCommand(id: target, anchor: .top, animated: true)
            }
        }
        .onChange(of: sessionManager.restorationScrollItemId) { _, itemId in
            guard let itemId else { return }
            sessionManager.restorationScrollItemId = nil

            guard let targetIndex = reducer.items.firstIndex(where: { $0.id == itemId }) else { return }
            let requiredWindow = reducer.items.count - targetIndex
            guard requiredWindow <= Self.maxRestorationWindow else { return }

            if !visibleItems.contains(where: { $0.id == itemId }) {
                renderWindow = max(renderWindow, requiredWindow)
            }
            scrollController.scrollTargetID = itemId
        }
        .onChange(of: scrollController.scrollToBottomNonce) { _, _ in
            guard let bottomItemID else { return }
            issueScrollCommand(id: bottomItemID, anchor: .bottom, animated: true)
        }
        .sheet(item: $fileToOpen) { file in
            RemoteFileView(workspaceId: file.workspaceId, sessionId: file.sessionId, path: file.path)
        }
    }

    private func jumpToLatest() {
        guard let bottomItemID else { return }
        // Re-attach so auto-follow resumes and the programmatic scroll
        // animation doesn't re-flash the hints.
        scrollController.updateNearBottom(true)
        scrollController.setDetachedStreamingHintVisible(false)
        scrollController.setJumpToBottomHintVisible(false)
        issueScrollCommand(id: bottomItemID, anchor: .bottom, animated: true)
    }

    private func issueScrollCommand(id: String, anchor: ChatTimelineScrollCommand.Anchor, animated: Bool) {
        scrollCommandNonce &+= 1
        pendingScrollCommand = ChatTimelineScrollCommand(
            id: id,
            anchor: anchor,
            animated: animated,
            nonce: scrollCommandNonce
        )
    }
}
