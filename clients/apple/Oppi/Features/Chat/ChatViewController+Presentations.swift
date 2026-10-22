import UIKit

/// The chat's router modals, one presentation slot each. The chat sets each
/// slot's request in `updateProperties()` from its model; the slot presents,
/// replaces, and dismisses like a SwiftUI `.sheet(item:)`, and clears the
/// model flag after a swipe-down or the modal's own `finish()`.
@MainActor
final class ChatModalSlots {
    let outline = RouterModalPresenter()
    let files = RouterModalPresenter()
    let git = RouterModalPresenter()
    let context = RouterModalPresenter()
    let share = RouterModalPresenter()
    let modelPicker = RouterModalPresenter()
    let reviewCommentStash = RouterModalPresenter()

    private var all: [RouterModalPresenter] {
        [outline, files, git, context, share, modelPicker, reviewCommentStash]
    }

    weak var anchor: UIViewController? {
        didSet {
            for slot in all { slot.anchor = anchor }
        }
    }

    /// Presents requests made while the chat was off screen.
    func sync() {
        for slot in all { slot.sync() }
    }
}

/// A chat panel modal; the id is whether it is full screen, so a new style
/// is a new modal.
private struct ChatAuxiliaryModalID: Hashable {
    let fullScreen: Bool
}

extension ChatViewController: TrailingColumnKeyboardScreen {}

extension ChatViewController {
    /// A regular-width window (iPad, the iPhone Duo inner display, a large
    /// iPhone in landscape) shows Share full screen. The side panels are in
    /// the column there, so they present only as sheets.
    private var prefersFullScreenAuxiliaryPresentation: Bool {
        traitCollection.horizontalSizeClass == .regular
    }

    /// A chat panel as a router modal in a router navigation controller, for
    /// its bar and its pushes: a sheet with medium and large detents in
    /// compact width, full screen in regular width. The style is part of the
    /// id, so a size-class change (rotation, a fold, iPad multitasking)
    /// replaces an open sheet with the full-screen modal and back. Full screen
    /// is `.overFullScreen`: the chat stays in the window and keeps rendering,
    /// so the panel's chat values stay live.
    private func auxiliaryPresentation(fullScreen: Bool) -> ModalPresentation {
        (fullScreen
            ? ModalPresentation(style: .overFullScreen)
            : .sheet.detents([.medium(), .large()], grabber: true, selected: .large)
        ).inNavigation()
    }

    /// Every chat modal is a router modal. Outline, Files, Git, and Context sit
    /// in a router navigation controller, as a modal here or in the trailing
    /// column (`updateSidePanels`). Files and Context push through their
    /// screen navigator; the outline is a UIKit screen that owns its bar and
    /// search; Git presents its reviews over itself.
    func updateModals() {
        guard let root else { return }
        let sidePanel = usesTrailingSidePanel
        let fullScreen = prefersFullScreenAuxiliaryPresentation
        let auxiliaryID = AnyHashable(ChatAuxiliaryModalID(fullScreen: fullScreen))
        let auxiliary = auxiliaryPresentation(fullScreen: fullScreen)

        modals.outline.update(
            id: !sidePanel && model.showOutline ? auxiliaryID : nil,
            presentation: auxiliary,
            root: root,
            clear: { [weak self] in self?.model.showOutline = false },
            screen: outlineScreen
        )
        modals.files.update(
            id: !sidePanel && model.isFilePanelVisible ? auxiliaryID : nil,
            presentation: auxiliary,
            root: root,
            clear: { [weak self] in self?.model.isFilePanelVisible = false },
            screen: filePanelScreen
        )
        modals.git.update(
            id: !sidePanel && model.showGit ? auxiliaryID : nil,
            presentation: auxiliary,
            root: root,
            clear: { [weak self] in self?.model.showGit = false },
            screen: gitPanelScreen
        )
        modals.context.update(
            id: !sidePanel && model.showContextInspector ? auxiliaryID : nil,
            presentation: auxiliary,
            root: root,
            clear: { [weak self] in self?.model.showContextInspector = false },
            screen: contextScreen
        )
        modals.share.update(
            id: model.showShareRedactionSheet ? auxiliaryID : nil,
            presentation: auxiliary,
            root: root,
            onDismiss: { [weak self] in self?.cancelSharePreflight() },
            clear: { [weak self] in self?.model.showShareRedactionSheet = false },
            screen: shareRedactionScreen
        )
        modals.modelPicker.update(
            id: model.showModelPicker ? AnyHashable("model-picker") : nil,
            presentation: .sheet.detents([.medium(), .large()], selected: .large).inNavigation(),
            root: root,
            clear: { [weak self] in self?.model.showModelPicker = false },
            screen: modelPickerScreen
        )
        let stash = model.reviewCommentStashPresentation
        modals.reviewCommentStash.update(
            id: stash.map { AnyHashable($0.id) },
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.model.reviewCommentStashPresentation = nil },
            screen: {
                guard let stash else { preconditionFailure("The stash sheet presents only with its presentation") }
                return reviewCommentStashScreen(stash)
            }
        )
    }

    /// The model picker (UIKit), given the chat's server explicitly; its
    /// current model follows the session while it is up.
    func modelPickerScreen() -> RouterScreen {
        let current = session?.model
        let agentId = session?.launch?.agentId
        let chatState = chatState
        let apiClient = apiClient
        let onSetDefault: ((ModelInfo) async throws -> Void)? = canPersistSessionDefaults ? { [weak self] model in
            guard let self else { return }
            guard let api = self.connection.apiClient else { throw QuickSessionError.noConnection }
            try await ModelDefaultPersistence.save(model, agentId: self.session?.launch?.agentId, api: api)
            self.applyModelSelection(model)
            if self.session?.launch?.agentId == nil, let models = try? await api.listModels() {
                self.chatState.cachedModels = models
            }
        } : nil
        return .liveController({ [weak self] in
            ModelPickerViewController(
                currentModel: current,
                chatState: chatState,
                apiClient: apiClient,
                defaultAgentId: agentId,
                onSelect: { self?.handleModelSelection($0) },
                onSetDefault: onSetDefault
            )
        }, update: { $0.currentModel = current })
    }

    /// Side panels slide in as a trailing column in regular width (iPad, the
    /// Duo's inner display) and are sheets in compact width. A size-class
    /// change while a panel is open moves it between the column and the
    /// sheet; its pushed pages close. The column sits beside the chat's bar,
    /// timeline, and composer.
    func updateSidePanels() {
        guard let root else { return }
        let panel: ChatSidePanel? = {
            guard usesTrailingSidePanel else { return nil }
            if model.isFilePanelVisible { return .files }
            if model.showOutline { return .outline }
            if model.showGit { return .git }
            if model.showContextInspector { return .context }
            return nil
        }()
        trailingColumn.show(
            panel.map { panel in
                TrailingColumnController.Panel(
                    id: AnyHashable(panel),
                    minWidth: 320,
                    idealWidth: 400,
                    screen: sidePanelScreen(panel)
                )
            },
            root: panel == nil ? nil : root
        )
    }

    /// Outline, Git, Context, and Files are UIKit screens.
    private func sidePanelScreen(_ panel: ChatSidePanel) -> RouterScreen {
        switch panel {
        case .files: filePanelScreen()
        case .outline: outlineScreen()
        case .git: gitPanelScreen()
        case .context: contextScreen()
        }
    }

    /// A panel screen built on demand; it presents only while its chat is up.
    private func panelScreen(
        _ missingMessage: String,
        _ make: @escaping (ChatViewController) -> UIViewController
    ) -> RouterScreen {
        .controller({ [weak self] in
            guard let self else { preconditionFailure(missingMessage) }
            return make(self)
        })
    }

    private func outlineScreen() -> RouterScreen {
        panelScreen("The outline presents only while its chat is alive") { $0.makeOutlineController() }
    }

    private func contextScreen() -> RouterScreen {
        panelScreen("The context panel presents only while its chat is alive") { $0.makeContextController() }
    }

    func closeChatFilePanel() {
        model.isFilePanelVisible = false
    }

    func presentReviewCommentStashSheet(editing comment: ReviewComment? = nil) {
        model.reviewCommentDrawerExpanded = false
        model.reviewCommentStashPresentation = ReviewCommentStripChrome.StashPresentation(editing: comment)
        dismissKeyboard()
    }

    /// Session Outline, built when it opens: it lists the timeline loaded
    /// at that moment, then the server's full outline.
    func makeOutlineController() -> UIViewController {
        let reducer = reducer
        let scrollController = scrollController
        let sessionManager = sessionManager
        let connection = connection
        let sessionStore = sessionStore
        return SessionOutlineViewController(
            items: reducer.items,
            toolArgsStore: reducer.toolArgsStore,
            toolDetails: { reducer.toolDetailsStore.details(for: $0) },
            onSelect: { targetID in
                // A landed durable answer keeps its live row id.
                Self.selectOutlineTimelineEntry(
                    reducer.timelineItemID(for: targetID),
                    items: reducer.items,
                    scrollController: scrollController
                ) {
                    await sessionManager.loadOlderHistory(
                        through: targetID,
                        connection: connection,
                        sessionStore: sessionStore
                    )
                }
            },
            onFork: { [weak self] in self?.forkFromMessage($0) },
            onNavigateTreeNode: { [weak self] request in
                try await self?.navigateFromTree(request)
            },
            loadTree: { filterMode in
                try await connection.getSessionTree(filterMode: filterMode)
            },
            loadOutline: { [weak self] in
                guard let self, let routeScope = self.focusedRouteScope else {
                    throw TreeNavigationError.sessionNotReady
                }
                return try await connection.getSessionTraceOutline(
                    routeScope: routeScope,
                    sessionId: self.sessionId
                )
            },
            onClose: { [weak self] in self?.model.showOutline = false }
        )
    }

    /// The Context panel. It reads this chat's session row live, so its window
    /// totals follow the conversation while it is open.
    func makeContextController() -> UIViewController {
        let sessionStore = sessionStore
        let sessionId = sessionId
        let connection = connection
        let session = { sessionStore.sessions.first { $0.id == sessionId } }
        return ContextInspectorViewController(
            session: session,
            workspace: {
                guard let workspaceId = session()?.workspaceId else { return nil }
                return connection.workspaceStore.workspaces.first { $0.id == workspaceId }
            },
            connection: connection,
            reviewCommentSelectionScope: .activeSession(reviewCommentSelectionRouter),
            loadSessionStats: { try await connection.getSessionStats() },
            onClose: { [weak self] in self?.model.showContextInspector = false }
        )
    }
}
