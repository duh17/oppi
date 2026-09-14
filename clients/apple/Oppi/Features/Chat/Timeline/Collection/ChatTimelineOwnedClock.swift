import Observation
import UIKit

/// Cold SwiftUI chrome for the outline toolbar button. The owned clock writes
/// this only when the timeline becomes empty or nonempty, or a session binds.
@MainActor
@Observable
final class ChatTimelineOutlineAvailability {
    var isAvailable = false
}

/// Presentation state the collection controller owns so SwiftUI is not the
/// streaming clock. `ChatTimelineView` still pushes chrome through
/// `updateUIView`; reducer tokens apply here.
@MainActor
final class ChatTimelineOwnedClockState {
    var isObserving = false
    var didScheduleAttachRetry = false
    var renderWindow = TimelineRenderWindowPolicy.standardWindow
    var expandedQuietTurnIDs: Set<String> = []
    var quietSettledEnds: [String: Date] = [:]
    var pendingScrollCommand: ChatTimelineScrollCommand?
    var scrollCommandNonce = 0
    var lastScrollToBottomNonce: UInt = 0
    var lastConfiguration: ChatTimelineCollectionHost.Configuration?
    var emptyOverlayController: UIViewController?

    func resetPresentationState() {
        renderWindow = TimelineRenderWindowPolicy.standardWindow
        expandedQuietTurnIDs.removeAll()
        quietSettledEnds.removeAll()
        pendingScrollCommand = nil
        scrollCommandNonce = 0
        lastScrollToBottomNonce = 0
        didScheduleAttachRetry = false
    }
}

extension ChatTimelineCollectionHost.Controller {
    func updateHostChrome(
        configuration: ChatTimelineCollectionHost.Configuration,
        to collectionView: UICollectionView
    ) {
        let previous = ownedClock.lastConfiguration
        let sessionChanged = previous.map {
            $0.sessionId != configuration.sessionId
                || $0.serverId != configuration.serverId
                || $0.workspaceId != configuration.workspaceId
                || $0.routeScope != configuration.routeScope
                || $0.reducer !== configuration.reducer
        } ?? true
        if sessionChanged {
            ownedClock.resetPresentationState()
        }
        if previous?.quietModeEnabled == true, !configuration.quietModeEnabled {
            ownedClock.expandedQuietTurnIDs.removeAll()
        }

        ownedClock.lastConfiguration = configuration
        self.collectionView = collectionView

        if sessionChanged, ownedClock.isObserving {
            trackOwnedTimelineSources()
        }

        let chromeChanged = ownedProjectionChromeChanged(from: previous, to: configuration)
        if previous == nil || sessionChanged || chromeChanged {
            applyOwnedProjection(to: collectionView)
        }

        startOwnedTimelineObservationIfNeeded()
    }

    func stopOwnedTimelineObservation() {
        ownedClock.isObserving = false
        ownedClock.didScheduleAttachRetry = false
        collectionView?.backgroundView = nil
        ownedClock.emptyOverlayController = nil
    }

    func applyOwnedProjection(to collectionView: UICollectionView? = nil) {
        guard let collectionView = collectionView ?? self.collectionView else { return }
        guard var config = ownedClock.lastConfiguration else { return }
        let reducer = config.reducer

        ChatTimelinePerf.recordControllerOwnedApply()

        ownedClock.renderWindow = TimelineRenderWindowPolicy.syncedWindow(
            currentWindow: ownedClock.renderWindow,
            totalItems: reducer.items.count
        )

        var projection = makeOwnedProjection(reducer: reducer, configuration: config)
        consumeOwnedScrollTargetIfNeeded(
            reducer: reducer,
            projection: projection
        )
        projection = makeOwnedProjection(reducer: reducer, configuration: config)

        var window = ownedClock.renderWindow
        if let command = ownedClock.pendingScrollCommand, command.anchor == .top,
           let index = reducer.items.firstIndex(where: { $0.id == command.id }) {
            window = max(window, reducer.items.count - index)
        }
        ownedClock.renderWindow = TimelineRenderWindowPolicy.syncedWindow(
            currentWindow: window,
            totalItems: reducer.items.count
        )

        let renderedItemIDs = Set(reducer.items.suffix(ownedClock.renderWindow).map(\.id))
        var visibleRows = projection.rows(forRenderedItemIDs: renderedItemIDs)
        let bottomItemID: String? = {
            if config.showsWorkingIndicator {
                return ChatTimelineCollectionHost.workingIndicatorID
            }
            return visibleRows.last?.id
        }()

        consumeOwnedInitialScrollIfNeeded(
            reducer: reducer,
            sessionManager: config.sessionManager,
            projection: projection,
            bottomItemID: bottomItemID
        )
        consumeOwnedScrollToBottomIfNeeded(bottomItemID: bottomItemID)

        if ownedClock.renderWindow != window || ownedClock.pendingScrollCommand != nil {
            projection = makeOwnedProjection(reducer: reducer, configuration: config)
            let nextRenderedIDs = Set(reducer.items.suffix(ownedClock.renderWindow).map(\.id))
            visibleRows = projection.rows(forRenderedItemIDs: nextRenderedIDs)
        }

        let nextSettled = projection.settledEnds
        if nextSettled != ownedClock.quietSettledEnds {
            ownedClock.quietSettledEnds = nextSettled
        }

        let items = visibleRows.compactMap { row -> ChatItem? in
            if case .item(let item) = row { return item }
            return nil
        }
        let workLineByID = Dictionary(uniqueKeysWithValues: visibleRows.compactMap { row -> (String, QuietTimelineWorkLine)? in
            guard case .quietWork(let workLine) = row else { return nil }
            return (workLine.id, workLine)
        })
        let hiddenCount = max(0, reducer.items.count - min(ownedClock.renderWindow, reducer.items.count))

        config.items = items
        config.displayRows = visibleRows
        config.workLineByID = workLineByID
        config.fullTimelineItemIDs = projection.fullTimelineItemIDs
        config.hiddenCount = hiddenCount
        config.hasOlderServerPage = config.sessionManager?.hasOlderTracePage ?? config.hasOlderServerPage
        config.streamingAssistantID = reducer.streamingAssistantID
        config.scrollCommand = ownedClock.pendingScrollCommand
        config.onQuietWorkLineToggle = { [weak self] turnID in
            self?.handleOwnedQuietToggle(turnID)
        }
        config.onShowEarlier = { [weak self] in
            self?.handleOwnedShowEarlier()
        }

        apply(configuration: config, to: collectionView)
        config.scrollController.itemCount = visibleRows.count
        _ = config.scrollController.consumeHasNewItems()
        updateOwnedEmptyOverlay(
            isEmpty: reducer.items.isEmpty,
            configuration: config,
            collectionView: collectionView
        )
        publishOwnedOutlineAvailability(isEmpty: reducer.items.isEmpty)
    }

    #if DEBUG
        var isObservingOwnedTimelineForTesting: Bool { ownedClock.isObserving }
        var ownedTimelineRenderWindowForTesting: Int { ownedClock.renderWindow }
        var ownedQuietSettledEndsForTesting: [String: Date] { ownedClock.quietSettledEnds }
    #endif
}

extension ChatTimelineCollectionHost.Controller {
    private func startOwnedTimelineObservationIfNeeded() {
        guard ownedClock.lastConfiguration?.ownsTimelineProjection == true else { return }
        if !ownedClock.isObserving {
            ownedClock.isObserving = true
            trackOwnedTimelineSources()
            scheduleOwnedAttachRetryIfNeeded()
        }
    }

    private func trackOwnedTimelineSources() {
        guard ownedClock.isObserving else { return }
        let configuration = ownedClock.lastConfiguration
        withObservationTracking {
            if let reducer = configuration?.reducer {
                _ = reducer.renderVersion
                _ = reducer.streamingAssistantID
            }
            if let scrollController = configuration?.scrollController {
                _ = scrollController.scrollTargetID
                _ = scrollController.scrollToBottomNonce
                _ = scrollController.needsInitialScroll
            }
            if let sessionManager = configuration?.sessionManager {
                _ = sessionManager.needsInitialScroll
                _ = sessionManager.hasOlderTracePage
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleOwnedTimelineSourceChange()
            }
        }
    }

    private func handleOwnedTimelineSourceChange() {
        guard ownedClock.isObserving else { return }
        trackOwnedTimelineSources()
        applyOwnedProjection()
    }

    private func scheduleOwnedAttachRetryIfNeeded() {
        guard !ownedClock.didScheduleAttachRetry else { return }
        ownedClock.didScheduleAttachRetry = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.ownedClock.isObserving else { return }
            self.applyOwnedProjection()
        }
    }

    private func publishOwnedOutlineAvailability(isEmpty: Bool) {
        guard let availability = ownedClock.lastConfiguration?.outlineAvailability else { return }
        let next = !isEmpty
        guard availability.isAvailable != next else { return }
        availability.isAvailable = next
    }

    private func ownedProjectionChromeChanged(
        from previous: ChatTimelineCollectionHost.Configuration?,
        to next: ChatTimelineCollectionHost.Configuration
    ) -> Bool {
        guard let previous else { return true }
        return previous.isBusy != next.isBusy
            || previous.showsWorkingIndicator != next.showsWorkingIndicator
            || previous.quietModeEnabled != next.quietModeEnabled
            || previous.workStripStyle != next.workStripStyle
            || previous.extensionWorkingState != next.extensionWorkingState
            || previous.extensionHiddenThinkingLabel != next.extensionHiddenThinkingLabel
            || previous.agentId != next.agentId
            || previous.agentIcon != next.agentIcon
            || previous.topOverlap != next.topOverlap
            || previous.bottomOverlap != next.bottomOverlap
    }

    private func makeOwnedProjection(
        reducer: TimelineReducer,
        configuration: ChatTimelineCollectionHost.Configuration
    ) -> QuietTimelineProjection {
        QuietTimelineProjection.make(
            items: reducer.items,
            isQuiet: configuration.quietModeEnabled,
            isBusy: configuration.isBusy,
            expandedTurnIDs: ownedClock.expandedQuietTurnIDs,
            displayStyle: configuration.workStripStyle,
            toolArgs: { reducer.toolArgsStore.args(for: $0) },
            settledEnds: ownedClock.quietSettledEnds
        )
    }

    private func issueOwnedScrollCommand(
        id: String,
        anchor: ChatTimelineScrollCommand.Anchor,
        animated: Bool
    ) {
        ownedClock.scrollCommandNonce &+= 1
        ownedClock.pendingScrollCommand = ChatTimelineScrollCommand(
            id: id,
            anchor: anchor,
            animated: animated,
            nonce: ownedClock.scrollCommandNonce
        )
    }

    private func consumeOwnedScrollTargetIfNeeded(
        reducer: TimelineReducer,
        projection: QuietTimelineProjection
    ) {
        guard let scrollController, scrollController.scrollTargetID != nil else { return }
        let visibleRowIDs = Set(
            projection.rows(
                forRenderedItemIDs: Set(reducer.items.suffix(ownedClock.renderWindow).map(\.id))
            ).map(\.id)
        )
        if let targetID = scrollController.scrollTargetID, !visibleRowIDs.contains(targetID) {
            if let workLine = projection.rows.compactMap({ row -> QuietTimelineWorkLine? in
                guard case .quietWork(let workLine) = row,
                      workLine.sourceItemIDs.contains(targetID) else { return nil }
                return workLine
            }).first {
                ownedClock.expandedQuietTurnIDs.insert(workLine.turnID)
            }
            ownedClock.renderWindow = reducer.items.count
        }
        scrollController.handleScrollTarget { [weak self] target in
            self?.issueOwnedScrollCommand(id: target, anchor: .top, animated: false)
        }
    }

    private func consumeOwnedInitialScrollIfNeeded(
        reducer _: TimelineReducer,
        sessionManager: ChatSessionManager?,
        projection: QuietTimelineProjection,
        bottomItemID: String?
    ) {
        guard let scrollController, scrollController.scrollTargetID == nil else { return }
        if let sessionManager, sessionManager.needsInitialScroll {
            sessionManager.needsInitialScroll = false
            scrollController.needsInitialScroll = true
        }
        guard scrollController.needsInitialScroll else { return }
        guard let bottomItemID else { return }
        guard let placement = scrollController.initialPlacement(
            availableFullTimelineItemIDs: projection.fullTimelineItemIDs,
            bottomItemID: bottomItemID
        ) else {
            return
        }

        switch placement {
        case .bottom(let itemID):
            issueOwnedScrollCommand(id: itemID, anchor: .bottom, animated: false)
        case .viewport(let restoration):
            if let itemIndex = projection.fullTimelineItemIDs.firstIndex(of: restoration.itemID) {
                ownedClock.renderWindow = max(
                    ownedClock.renderWindow,
                    projection.fullTimelineItemIDs.count - itemIndex
                )
            }
            issueOwnedScrollCommand(
                id: restoration.itemID,
                anchor: .viewport(relativeY: restoration.relativeY),
                animated: false
            )
        }
    }

    private func consumeOwnedScrollToBottomIfNeeded(bottomItemID: String?) {
        guard let scrollController else { return }
        let nonce = scrollController.scrollToBottomNonce
        guard nonce != ownedClock.lastScrollToBottomNonce else { return }
        ownedClock.lastScrollToBottomNonce = nonce
        guard let bottomItemID else { return }
        issueOwnedScrollCommand(id: bottomItemID, anchor: .bottom, animated: true)
    }

    private func handleOwnedQuietToggle(_ turnID: String) {
        ownedClock.expandedQuietTurnIDs.formSymmetricDifference([turnID])
        applyOwnedProjection()
    }

    private func handleOwnedShowEarlier() {
        guard let config = ownedClock.lastConfiguration else { return }
        let reducer = config.reducer
        switch TimelineRenderWindowPolicy.showEarlierAction(
            currentWindow: ownedClock.renderWindow,
            totalItems: reducer.items.count,
            step: config.renderWindowStep,
            hasOlderServerPage: config.sessionManager?.hasOlderTracePage ?? config.hasOlderServerPage
        ) {
        case .revealLocal(let newWindow):
            ownedClock.renderWindow = newWindow
            applyOwnedProjection()
        case .fetchOlderPage:
            let sessionManager = config.sessionManager
            let connection = config.connection
            let step = config.renderWindowStep
            Task { @MainActor [weak self] in
                guard let self, let sessionManager else { return }
                let didLoad = await sessionManager.loadOlderTracePage(
                    connection: connection,
                    sessionStore: connection.sessionStore
                )
                if didLoad {
                    self.ownedClock.renderWindow = min(
                        reducer.items.count,
                        self.ownedClock.renderWindow + step
                    )
                    self.applyOwnedProjection()
                }
            }
        case .none:
            break
        }
    }
}
