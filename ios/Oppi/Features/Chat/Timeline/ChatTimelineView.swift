import SwiftUI

enum ZenTimelineRenderWindowPolicy {
    static let standardWindow = 80
    static let zenAttachedWindow = 40
    static let renderWindowStep = 60

    static func syncedWindow(
        currentWindow: Int,
        totalItems: Int,
        isZenMode: Bool,
        isNearBottom: Bool
    ) -> Int {
        let clampedTotal = max(0, totalItems)
        let clampedCurrent = min(max(0, currentWindow), clampedTotal)

        if isZenMode, isNearBottom {
            return min(clampedTotal, zenAttachedWindow)
        }

        let baseline = min(clampedTotal, standardWindow)
        return max(clampedCurrent, baseline)
    }
}

/// Extracted from ChatView so that @State inputText changes (every keystroke)
/// do NOT trigger a full ForEach re-diff of 200+ items.
///
/// As a separate View struct, this gets its own SwiftUI observation scope.
/// It only re-evaluates when its own dependencies change (reducer.items,
/// renderVersion, session status) — NOT when the parent's @State changes.
struct ChatTimelineView: View {
    private static let initialRenderWindow = ZenTimelineRenderWindowPolicy.standardWindow
    private static let renderWindowStep = ZenTimelineRenderWindowPolicy.renderWindowStep

    let sessionId: String
    let workspaceId: String?
    let isBusy: Bool
    let isZenMode: Bool
    let scrollController: ChatScrollController
    let sessionManager: ChatSessionManager
    let onFork: (String) -> Void
    let selectedTextPiRouter: SelectedTextPiActionRouter?
    let topOverlap: CGFloat
    let bottomOverlap: CGFloat

    @Environment(TimelineReducer.self) private var reducer
    @Environment(ServerConnection.self) private var connection
    @Environment(AudioPlayerService.self) private var audioPlayer

    @State private var renderWindow = Self.initialRenderWindow
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

    private func syncRenderWindowToMode() {
        renderWindow = ZenTimelineRenderWindowPolicy.syncedWindow(
            currentWindow: renderWindow,
            totalItems: reducer.items.count,
            isZenMode: isZenMode,
            isNearBottom: scrollController.isCurrentlyNearBottom
        )
    }

    var body: some View {
        ChatTimelineCollectionHost(
            configuration: .init(
                items: Array(visibleItems),
                hiddenCount: hiddenCount,
                renderWindowStep: Self.renderWindowStep,
                isBusy: isBusy,
                isZenMode: isZenMode,
                streamingAssistantID: reducer.streamingAssistantID,
                sessionId: sessionId,
                workspaceId: workspaceId,
                onFork: onFork,
                onShowEarlier: {
                    renderWindow = min(reducer.items.count, renderWindow + Self.renderWindowStep)
                },
                scrollCommand: pendingScrollCommand,
                scrollController: scrollController,
                reducer: reducer,
                toolOutputStore: reducer.toolOutputStore,
                toolArgsStore: reducer.toolArgsStore,
                toolSegmentStore: reducer.toolSegmentStore,
                toolDetailsStore: reducer.toolDetailsStore,
                connection: connection,
                audioPlayer: audioPlayer,
                themeID: ThemeRuntimeState.currentThemeID(),
                selectedTextPiRouter: selectedTextPiRouter,
                topOverlap: topOverlap,
                bottomOverlap: bottomOverlap
            )
        )
        .overlay(alignment: .bottom) {
            PermissionOverlay(sessionId: sessionId)
                .padding(.bottom, bottomOverlap)
        }
        .background(Color.themeBg)
        .overlay {
            if reducer.items.isEmpty && !isBusy {
                ChatEmptyState()
            }
        }
        .onAppear {
            syncRenderWindowToMode()
        }
        .onChange(of: isZenMode) { _, _ in
            syncRenderWindowToMode()
        }
        .onChange(of: scrollController.isCurrentlyNearBottom) { _, _ in
            syncRenderWindowToMode()
        }
        .onChange(of: reducer.items.count) { _, _ in
            syncRenderWindowToMode()
        }
        // Jump-to-bottom button lives in ChatView (above the footer overlay) to avoid
        // the footer's z-order blocking taps on this overlay.
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
        .onChange(of: scrollController.scrollToBottomNonce) { _, _ in
            guard let bottomItemID else { return }
            issueScrollCommand(id: bottomItemID, anchor: .bottom, animated: true)
        }
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
