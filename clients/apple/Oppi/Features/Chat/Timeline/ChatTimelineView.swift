import SwiftUI

enum TimelineRenderWindowPolicy {
    enum ShowEarlierAction: Equatable {
        case revealLocal(newWindow: Int)
        case fetchOlderPage
        case none
    }

    static let standardWindow = 80
    static let renderWindowStep = 60

    static func syncedWindow(currentWindow: Int, totalItems: Int) -> Int {
        let clampedTotal = max(0, totalItems)
        let clampedCurrent = min(max(0, currentWindow), clampedTotal)
        let baseline = min(clampedTotal, standardWindow)
        return max(clampedCurrent, baseline)
    }

    static func showsShowEarlierControl(hiddenCount: Int, hasOlderServerPage: Bool) -> Bool {
        hiddenCount > 0 || hasOlderServerPage
    }

    static func showEarlierAction(
        currentWindow: Int,
        totalItems: Int,
        step: Int,
        hasOlderServerPage: Bool
    ) -> ShowEarlierAction {
        let clampedTotal = max(0, totalItems)
        let clampedCurrent = min(max(0, currentWindow), clampedTotal)
        if clampedCurrent < clampedTotal {
            return .revealLocal(newWindow: min(clampedTotal, clampedCurrent + max(1, step)))
        }
        return hasOlderServerPage ? .fetchOlderPage : .none
    }
}

/// Extracted from ChatView so that @State inputText changes (every keystroke)
/// do NOT trigger a full ForEach re-diff of 200+ items.
///
/// As a separate View struct, this gets its own SwiftUI observation scope.
/// It only re-evaluates when its own dependencies change (reducer.items,
/// renderVersion, session status) — NOT when the parent's @State changes.
struct ChatTimelineView: View {
    private static let initialRenderWindow = TimelineRenderWindowPolicy.standardWindow
    private static let renderWindowStep = TimelineRenderWindowPolicy.renderWindowStep

    let sessionId: String
    let workspaceId: String?
    var routeScope: SessionRouteScope?
    let isBusy: Bool
    let extensionWorkingState: ExtensionWorkingState?
    let extensionHiddenThinkingLabel: String?
    let currentModel: String?
    let connection: ServerConnection
    let scrollController: ChatScrollController
    let sessionManager: ChatSessionManager
    let audioLifecycleCoordinator: AudioLifecycleCoordinator?
    let onFork: (String) -> Void
    let onBackSwipe: () -> Void
    let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    let topOverlap: CGFloat
    let bottomOverlap: CGFloat

    @Environment(TimelineReducer.self) private var reducer
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
        isBusy && (extensionWorkingState?.visible ?? true)
    }

    private var bottomItemID: String? {
        if showsWorkingIndicator {
            return ChatTimelineCollectionHost.workingIndicatorID
        }
        return visibleItems.last?.id
    }

    private func syncRenderWindow() {
        renderWindow = TimelineRenderWindowPolicy.syncedWindow(
            currentWindow: renderWindow,
            totalItems: reducer.items.count
        )
    }

    private func consumeInitialScrollIfNeeded() {
        guard sessionManager.needsInitialScroll else { return }
        guard let bottomItemID else { return }

        sessionManager.needsInitialScroll = false
        scrollController.needsInitialScroll = true
        scrollController.handleInitialScroll(bottomItemID: bottomItemID) { targetID in
            issueScrollCommand(id: targetID, anchor: .bottom, animated: false)
        }
    }

    var body: some View {
        ChatTimelineCollectionHost(
            configuration: .init(
                items: Array(visibleItems),
                hiddenCount: hiddenCount,
                hasOlderServerPage: sessionManager.hasOlderTracePage,
                renderWindowStep: Self.renderWindowStep,
                isBusy: isBusy,
                showsWorkingIndicator: showsWorkingIndicator,
                streamingAssistantID: reducer.streamingAssistantID,
                sessionId: sessionId,
                workspaceId: workspaceId,
                routeScope: routeScope,
                onFork: onFork,
                onBackSwipe: onBackSwipe,
                onShowEarlier: {
                    switch TimelineRenderWindowPolicy.showEarlierAction(
                        currentWindow: renderWindow,
                        totalItems: reducer.items.count,
                        step: Self.renderWindowStep,
                        hasOlderServerPage: sessionManager.hasOlderTracePage
                    ) {
                    case .revealLocal(let newWindow):
                        renderWindow = newWindow
                    case .fetchOlderPage:
                        Task { @MainActor in
                            let didLoadOlder = await sessionManager.loadOlderTracePage(
                                connection: connection,
                                sessionStore: connection.sessionStore
                            )
                            if didLoadOlder {
                                renderWindow = min(reducer.items.count, renderWindow + Self.renderWindowStep)
                            }
                        }
                    case .none:
                        break
                    }
                },
                scrollCommand: pendingScrollCommand,
                scrollController: scrollController,
                reducer: reducer,
                toolOutputStore: reducer.toolOutputStore,
                toolArgsStore: reducer.toolArgsStore,
                toolSegmentStore: reducer.toolSegmentStore,
                toolDetailsStore: reducer.toolDetailsStore,
                connection: connection,
                currentModel: currentModel,
                extensionWorkingState: extensionWorkingState,
                extensionHiddenThinkingLabel: extensionHiddenThinkingLabel,
                audioPlayer: audioPlayer,
                audioLifecycleCoordinator: audioLifecycleCoordinator,
                reviewCommentSelectionRouter: reviewCommentSelectionRouter,
                topOverlap: topOverlap,
                bottomOverlap: bottomOverlap
            )
        )
        .background(Color.themeBg)
        .overlay {
            if reducer.items.isEmpty && !isBusy {
                ChatEmptyState(sessionId: sessionId)
                    .padding(.top, topOverlap)
                    .padding(.bottom, bottomOverlap)
            }
        }
        .onAppear {
            syncRenderWindow()
            Task { @MainActor in
                await Task.yield()
                consumeInitialScrollIfNeeded()
            }
        }
        .onChange(of: reducer.items.count) { _, _ in
            syncRenderWindow()
        }
        // Jump-to-bottom button lives in ChatView (above the footer overlay) to avoid
        // the footer's z-order blocking taps on this overlay.
        .onChange(of: reducer.renderVersion) { _, _ in
            scrollController.itemCount = visibleItems.count
            _ = scrollController.consumeHasNewItems()
            // Ambient streaming follow is handled inside the collection view
            // after layout settles. SwiftUI only issues explicit scroll
            // intents (initial load, jump-to-bottom, navigation) so token/tool
            // streaming does not fight self-sizing layout with repeated
            // scrollToItem calls.
        }
        .onChange(of: sessionManager.needsInitialScroll) { _, needs in
            guard needs else { return }
            consumeInitialScrollIfNeeded()
        }
        .onChange(of: scrollController.scrollTargetID) { _, targetID in
            guard targetID != nil else { return }
            if let targetID, !visibleItems.contains(where: { $0.id == targetID }) {
                renderWindow = reducer.items.count
            }
            scrollController.handleScrollTarget { target in
                issueScrollCommand(id: target, anchor: .top, animated: false)
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
