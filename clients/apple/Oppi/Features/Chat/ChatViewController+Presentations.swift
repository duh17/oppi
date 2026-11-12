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

extension ChatViewController: PaneKeyboardFollowing {}

extension ChatViewController {
    /// A chat panel modal, in a router navigation controller for its bar and
    /// its pushes, at the one width where it presents as a modal at all:
    /// Files and Context push with `Router.push`; the outline is a UIKit
    /// screen that owns its bar and search; Git presents its reviews over
    /// itself. Every slot uses this same id, so a size-class change that
    /// opens or replaces one never races the id of another.
    private var chatAuxiliaryModalID: AnyHashable { AnyHashable("chat.auxiliary") }

    /// Outline, Files, Git, Context, and Share all sit in this one sheet style
    /// at compact width; regular width mounts every one of them in the
    /// attached leaf instead (`updateSidePanels`), Share included, so none
    /// of them needs a second, full-screen presentation of its own.
    private var auxiliaryPresentation: ModalPresentation {
        .sheet.detents([.medium(), .large()], grabber: true, selected: .large).inNavigation()
    }

    /// Every chat modal is a router modal.
    func updateModals() {
        guard let root else { return }
        let sidePanel = opensPanelsBeside
        let auxiliary = auxiliaryPresentation

        modals.outline.update(
            id: !sidePanel && model.showOutline ? chatAuxiliaryModalID : nil,
            presentation: auxiliary,
            root: root,
            clear: { [weak self] in self?.model.showOutline = false },
            screen: outlineScreen
        )
        modals.files.update(
            id: !sidePanel && model.isFilePanelVisible ? chatAuxiliaryModalID : nil,
            presentation: auxiliary,
            root: root,
            clear: { [weak self] in self?.model.isFilePanelVisible = false },
            screen: filePanelScreen
        )
        modals.git.update(
            id: !sidePanel && model.showGit ? chatAuxiliaryModalID : nil,
            presentation: auxiliary,
            root: root,
            clear: { [weak self] in self?.model.showGit = false },
            screen: gitPanelScreen
        )
        modals.context.update(
            id: !sidePanel && model.showContextInspector ? chatAuxiliaryModalID : nil,
            presentation: auxiliary,
            root: root,
            clear: { [weak self] in self?.model.showContextInspector = false },
            screen: contextScreen
        )
        modals.share.update(
            id: !sidePanel && model.showShareRedactionSheet ? chatAuxiliaryModalID : nil,
            presentation: auxiliary,
            root: root,
            onDismiss: { [weak self] in self?.cancelSharePreflight() },
            clear: { [weak self] in self?.model.showShareRedactionSheet = false },
            screen: shareRedactionScreen
        )
        modals.modelPicker.update(
            id: model.showModelPicker ? AnyHashable("model-picker") : nil,
            presentation: .popoverOrSheet(selected: .large).inNavigation(),
            source: model.modelPickerSource,
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

    /// The panel the attached leaf shows, or nil where they present as
    /// sheets or when none is open.
    var activeSidePanel: ChatSidePanel? {
        guard opensPanelsBeside else { return nil }
        // Share wins: it is a deliberate action from the title menu, not
        // a toggle, and used to draw over every other panel full screen.
        if model.showShareRedactionSheet { return .share }
        if let target = model.sidePanelReaderTarget { return .reader(target) }
        if let target = model.sidePanelTimelineTarget { return .timeline(target) }
        if model.isFilePanelVisible { return .files }
        if model.showOutline { return .outline }
        if model.showGit { return .git }
        if model.showContextInspector { return .context }
        return nil
    }

    /// Side panels slide in as the chat's attached leaf, beside it in its
    /// pane host, in regular width (iPad, the Duo's inner display) and are
    /// sheets in compact width. A size-class change while a panel is open
    /// moves it between the leaf and the sheet; its pushed pages close. A
    /// reader moves to the pushed reader route, and a timeline file or commit
    /// to the modal it opens as there.
    func updateSidePanels() {
        guard let root else { return }
        if !AdaptiveWidth.isWide(traitCollection), let target = model.sidePanelReaderTarget {
            // Narrow width reads the reader as the pushed route it opens as
            // there. Pushed first, so the panel reader leaving keeps the
            // payload the route still names.
            model.sidePanelReaderTarget = nil
            appNavigation.openChatReader(target)
        }
        if !AdaptiveWidth.isWide(traitCollection), let target = model.sidePanelTimelineTarget {
            model.sidePanelTimelineTarget = nil
            ChatTimelineDestinationPresenter(connection: connection)
                .open(target.request(sourceView: view, presenter: self))
        }
        let panel = activeSidePanel
        attachedLeaf.show(
            panel.map { panel in
                let width = panelWidth(panel)
                return AttachedLeafController.Panel(
                    id: AnyHashable(panel),
                    minWidth: width.minimum,
                    idealWidth: width.ideal,
                    maxWidth: width.maximum,
                    makeScreen: sidePanelController(panel)
                )
            },
            root: panel == nil ? nil : root
        )
    }

    /// Outline, Git, Context, and Files are UIKit screens; the reader is a
    /// `ChatReaderViewController` hosted as the panel's root instead of
    /// pushed onto the shell's stack.
    private func sidePanelController(_ panel: ChatSidePanel) -> () -> UIViewController {
        switch panel {
        case .files: filePanelController()
        case .outline: outlineController()
        case .git: gitPanelController(hostedInPanel: true)
        case .context: contextController()
        case .share: shareRedactionController()
        case .reader(let target): readerPanelController(target)
        case .timeline(let target): timelinePanelController(target)
        }
    }

    /// A document, image, or the share redaction review reads comfortably
    /// wider than Files, Git, Outline, and Context, which are mostly lists.
    private func panelWidth(_ panel: ChatSidePanel) -> (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) {
        switch panel {
        case .files, .outline, .git, .context: (320, 400, 640)
        case .reader, .share, .timeline: (360, 520, 820)
        }
    }

    /// A file or commit pill's destination as the column's root, built by
    /// the same presenter the narrow-width modal uses.
    private func timelinePanelController(_ target: ChatTimelineSidePanelTarget) -> () -> UIViewController {
        { [weak self] in
            guard let self else {
                preconditionFailure("The timeline panel presents only while its chat is alive")
            }
            let closePanel: () -> Void = { [weak self] in self?.showSidePanel(nil) }
            // A comment started in the pane closes it first, as in Git's.
            var target = target
            target.reviewCommentSelectionScope = SessionFilePages.closingPanelScope(
                target.reviewCommentSelectionScope,
                closePanel: closePanel
            )
            return ChatTimelineDestinationPresenter(connection: connection).panelScreen(
                for: target,
                navigation: appNavigation,
                pushChat: { [weak self] chat in self?.closeSidePanelThenPush(chat) },
                onClose: closePanel
            )
        }
    }

    private func readerPanelController(_ target: ChatReaderNavTarget) -> () -> UIViewController {
        { [weak self] in
            guard let self, let root else {
                preconditionFailure("The reader panel presents only while its chat is alive")
            }
            return ChatReaderViewController(
                target: target,
                store: root.chatReaderPayloadStore,
                navigation: self.appNavigation,
                onClose: { [weak self] in self?.closeSidePanelReader() }
            )
        }
    }

    /// A panel controller built on demand; it presents only while its chat is up.
    private func panelController(
        _ missingMessage: String,
        _ make: @escaping (ChatViewController) -> UIViewController
    ) -> () -> UIViewController {
        { [weak self] in
            guard let self else { preconditionFailure(missingMessage) }
            return make(self)
        }
    }

    private func outlineController() -> () -> UIViewController {
        panelController("The outline presents only while its chat is alive") { $0.makeOutlineController() }
    }

    private func contextController() -> () -> UIViewController {
        panelController("The context panel presents only while its chat is alive") { $0.makeContextController() }
    }

    private func outlineScreen() -> RouterScreen {
        .controller(outlineController())
    }

    private func contextScreen() -> RouterScreen {
        .controller(contextController())
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
        // A durable conversation has no in-place tree: the server refuses its tree
        // and tree navigation, and forking a message is how it branches. Without a
        // tree, the outline is the timeline alone, with no Timeline/Tree switch.
        let offersTree = session?.engine != .durable
        let navigateTree: ((SessionTreeNavigationRequest) async throws -> Void)? = offersTree
            ? { [weak self] request in try await self?.navigateFromTree(request) }
            : nil
        let loadTree: ((SessionTreeFilterMode) async throws -> SessionTreeSnapshot)? = offersTree
            ? { filterMode in try await connection.getSessionTree(filterMode: filterMode) }
            : nil
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
                    let loaded = await sessionManager.loadOlderHistory(
                        through: targetID,
                        connection: connection,
                        sessionStore: sessionStore
                    )
                    Self.reportOlderHistoryFailure(
                        loaded: loaded,
                        sessionManager: sessionManager,
                        connection: connection
                    )
                    return loaded
                }
            },
            onFork: { [weak self] in self?.forkFromMessage($0) },
            onNavigateTreeNode: navigateTree,
            allowsBranchSummary: { [weak self] in await self?.requestAISharing() ?? false },
            loadTree: loadTree,
            loadOutline: { [weak self] in
                guard let self, let routeScope = self.focusedRouteScope else {
                    throw TreeNavigationError.sessionNotReady
                }
                return try await connection.getSessionTraceOutline(
                    routeScope: routeScope,
                    sessionId: self.sessionId
                )
            },
            onClose: { [weak self] in self?.closeOutline() }
        )
    }

    /// A row picked in the outline jumps first, then the outline closes.
    /// Beside the chat that close ends the outline's search and slides the
    /// leaf out, which replaces the landed row's cell, so the jump's arrival
    /// waits until the leaf is gone. A sheet's close already holds it
    /// (the timeline waits while a presentation covers the chat).
    private func closeOutline() {
        model.showOutline = false
        guard opensPanelsBeside else { return }
        timeline.holdsNavigationArrival = true
        updateSidePanels()
        attachedLeaf.whenClosed { [weak self] in
            self?.timeline.holdsNavigationArrival = false
        }
    }

    /// The Context panel. It reads this chat's session row live, so its window
    /// totals follow the conversation while it is open.
    func makeContextController() -> UIViewController {
        let sessionStore = sessionStore
        let sessionId = sessionId
        let connection = connection
        let reducer = reducer
        let actionHandler = actionHandler
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
            reloadSession: {
                // This panel covers the chat, so the success toast presented from the
                // app root would never show: the panel prints the outcome itself.
                await actionHandler.performReload(
                    connection: connection,
                    reducer: reducer,
                    sessionStore: sessionStore,
                    sessionId: sessionId,
                    announcesSuccess: false
                )
            },
            onClose: { [weak self] in self?.model.showContextInspector = false }
        )
    }
}
