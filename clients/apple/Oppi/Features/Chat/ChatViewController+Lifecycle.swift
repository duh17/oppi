import UIKit

// The chat's lifecycle: view installation, the store changes it reacts to,
// appearance and disappearance, and the incognito session a left chat ends.

extension ChatViewController {
    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let collectionView = timeline.makeCollectionView(
            configuration: makeTimelineConfiguration(),
            contentRoot: root
        )
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        timelineView = collectionView

        view.addLayoutGuide(contentBottomGuide)
        let followsKeyboard = contentBottomGuide.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        bottomFollowsKeyboard = followsKeyboard
        bottomAtSafeArea = contentBottomGuide.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)

        // Dismiss scrim: dims the timeline so content doesn't bleed through
        // the context bar's glass, and collapses the bar on tap. A
        // semi-opaque fill instead of clear prevents the visual overlap
        // between expanded bar content and the timeline behind.
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.isHidden = true
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))
        view.addSubview(scrim)

        footerStack.axis = .vertical
        footerStack.alignment = .fill
        footerStack.spacing = 0
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerStack)

        NSLayoutConstraint.activate([
            contentBottomGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentBottomGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentBottomGuide.topAnchor.constraint(equalTo: view.topAnchor),
            followsKeyboard,
            // The timeline reaches up under the navigation bar so rows scroll
            // under its glass; `topOverlap` keeps the first row below the bar
            // and the context bar.
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: contentBottomGuide.bottomAnchor),
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footerStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            footerStack.bottomAnchor.constraint(equalTo: contentBottomGuide.bottomAnchor),
        ])

        composer.source = self
        addChild(composer)
        composer.didMove(toParent: self)

        addChild(canvasAnchor)
        canvasAnchor.view.frame = .zero
        canvasAnchor.view.isHidden = true
        view.addSubview(canvasAnchor.view)
        canvasAnchor.didMove(toParent: self)

        addChild(trailingColumn)
        trailingColumn.view.frame = .zero
        view.addSubview(trailingColumn.view)
        trailingColumn.didMove(toParent: self)

        modals.anchor = self
        barItems.chat = self
        installNotificationObservers()
        installLeavesIfNeeded()
        registerForTraitChanges(
            [UITraitHorizontalSizeClass.self, UITraitPreferredContentSizeCategory.self]
        ) { (self: Self, _) in
            self.setNeedsUpdateProperties()
        }
        if #available(iOS 27.1, *) {
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (self: Self, _) in
                self.setNeedsUpdateProperties()
            }
        }
    }

    /// The chrome follows the app root's theme, which a controller finds once
    /// it is in its stack.
    private func installLeavesIfNeeded() {
        guard footerAbove == nil, root != nil else { return }

        let contextBar = makeContextBar()
        contextBar.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(contextBar, aboveSubview: scrim)
        self.contextBar = contextBar

        let above = ChatFooterAboveView(chat: self)
        footerStack.addArrangedSubview(above)
        footerStack.addArrangedSubview(composer.view)
        footerStack.addArrangedSubview(ChatFooterBelowView(chat: self))
        footerStack.addArrangedSubview(ChatStoppedFooterView(chat: self))
        footerAbove = above

        barItems.titleControl.install(ChatTitleView(chat: self))

        let jump = ChatJumpToBottomView(chat: self)
        jump.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(jump)

        NSLayoutConstraint.activate([
            contextBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contextBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            contextBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            jump.widthAnchor.constraint(equalToConstant: Self.jumpToBottomSlotSize),
            jump.heightAnchor.constraint(equalToConstant: Self.jumpToBottomSlotSize),
            jump.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -27),
            jump.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -10),
        ])
        contextBar.onHeightChange = { [weak self] _ in self?.view.setNeedsLayout() }
    }

    /// The jump-to-bottom hint's slot; the button sits at its bottom trailing corner.
    static let jumpToBottomSlotSize: CGFloat = 44

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appearIfNeeded(animated: animated)
        // Bar items come back after a pop that was cancelled (`viewWillDisappear`).
        barItems.isSuspended = false
        setNeedsUpdateProperties()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving the stack: take the chat's items off the bar now. UIKit
        // otherwise fades them out after the pop, and for that moment the
        // chat's Back, Files, and context still answer on the screen below.
        if screen.isMovingFromParent || screen.isBeingDismissed {
            barItems.clear()
        }
    }

    /// Runs once per appearance, from the first of `viewWillAppear` and
    /// `viewDidAppear`. A child added while its parent is mid-transition (the
    /// shell route builds the chat in its first `updateProperties()`, during
    /// the push) gets only `viewDidAppear`; skipping the work there left the
    /// chat unfocused and its session stream unopened.
    private func appearIfNeeded(animated: Bool) {
        guard !hasAppeared else { return }
        hasAppeared = true
        installLeavesIfNeeded()
        // The chat never shows the stack's bottom toolbar.
        screen.navigationController?.setToolbarHidden(true, animated: animated)
        handleAppear()
#if DEBUG
        seedE2EChatImageAttachmentIfRequested()
#endif
        applyExtensionToolsExpandedState()
        startSessionEntryTasks()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appearIfNeeded(animated: animated)
        // Modals asked for while the chat was off screen present now.
        modals.sync()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A sheet over the chat keeps it in the window; only leaving the
        // window (a push, a full-screen cover, a pop) is a disappearance.
        guard viewIfLoaded?.window == nil || isMovingFromParent || screen.isMovingFromParent else { return }
        handleDisappear()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let timelineView else { return }
        // Measured in window coordinates from the two frames, never from an
        // inset: it covers the bar and the context bar below it.
        let header: UIView = contextBar ?? view
        let headerFrame = contextBar == nil
            ? CGRect(x: 0, y: view.safeAreaInsets.top, width: view.bounds.width, height: 0)
            : header.bounds
        let top = ChatTimelineChromeOverlap.topInset(
            timelineFrame: timelineView.convert(timelineView.bounds, to: nil),
            headerFrame: header.convert(headerFrame, to: nil)
        )
        let bottom = footerStack.frame.height
        let width = timelineView.bounds.width
        if abs(top - timelineTopOverlap) > 0.5 || abs(bottom - footerHeight) > 0.5 || abs(width - timelineWidth) > 0.5 {
            timelineTopOverlap = top
            footerHeight = bottom
            timelineWidth = width
            setNeedsUpdateProperties()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        installLeavesIfNeeded()
        let root = root
        view.backgroundColor = root?.themeStore.backgroundColor
        let palette = root?.themeStore.activeThemeID.palette ?? ThemeRuntimeState.currentPalette()
        scrim.backgroundColor = ComposerThemeColors(palette: palette).bg.withAlphaComponent(0.5)
        timeline.contentRoot = root
        _ = model.chatDisplayRefresh
        _ = model.topBarRefresh

        observeChanges()
        updateTitleMaxWidth()
        updateTimelineChrome()
        contextBar?.context = contextBarContext
        updateFooter()
        barItems.update()
        updateSidePanels()
        updateModals()
        canvasAnchor.destination = canvasDestination
        canvasAnchor.reviewCommentSelectionRouter = reviewCommentSelectionRouter
    }

    // MARK: - Observed changes

    /// The chat's reactions to store changes (the SwiftUI screen's
    /// `onChange`s): each fires when its value changes, not on the first pass.
    private func observeChanges() {
        let session = session
        let next = ChatObservedValues(
            sessionTitle: session?.displayTitle,
            sessionModel: session?.model,
            sessionStatus: session?.status,
            entryState: sessionManager.entryState,
            askRequestID: activeComposerAskRequest?.id,
            toolsExpanded: extensionSurfaceState.toolsExpanded,
            editorTextRevision: chatState.extensionEditorTextUpdate?.revision,
            jumpToBottomVisible: scrollController.isJumpToBottomHintVisible,
            showsNowPlayingPill: showsNowPlayingPill,
            showsReviewCommentPill: showsReviewCommentPill,
            liveVoiceHoldsComposer: liveVoiceController.holdsComposer,
            draftKey: ChatDraftAttachmentKey(key: composerDraftKey, isEphemeral: composerDraftIsMemoryOnly),
            reviewCommentLoadKey: ReviewCommentLoadKey(localScopeId: reviewCommentLocalScopeId, sessionId: sessionId),
            scenePhaseIsActive: AppScenePhase.shared.isActive,
            scenePhasePausesTimeline: AppScenePhase.shared.pausesTimelinePresentation
        )
        let previous = observed
        observed = next
        guard previous.isInitialized else {
            // First pass: the keyed tasks run once, as `.task(id:)` did.
            attachComposerDraftIfPossible()
            loadReviewCommentsIfPossible()
            return
        }
        if previous.sessionTitle != next.sessionTitle || previous.sessionModel != next.sessionModel {
            audioPlayer.setSessionContext(session)
        }
        if previous.draftKey != next.draftKey {
            attachComposerDraftIfPossible()
        }
        if previous.reviewCommentLoadKey != next.reviewCommentLoadKey {
            loadReviewCommentsIfPossible()
        }
        if previous.editorTextRevision != next.editorTextRevision {
            handleExtensionEditorTextUpdate()
        }
        if previous.askRequestID != next.askRequestID {
            synchronizeComposerMode()
        }
        if previous.toolsExpanded != next.toolsExpanded {
            applyExtensionToolsExpandedState()
        }
        if previous.sessionStatus != next.sessionStatus {
            handleSessionStatusChange(next.sessionStatus)
        }
        if previous.entryState != next.entryState, let entryState = next.entryState {
            handleEntryStateChange(entryState)
        }
        if previous.scenePhaseIsActive != next.scenePhaseIsActive
            || previous.scenePhasePausesTimeline != next.scenePhasePausesTimeline {
            handleScenePhaseChange()
        }
        if !previous.jumpToBottomVisible, next.jumpToBottomVisible {
            model.contextBarCollapseToken &+= 1
        }
        if previous.showsNowPlayingPill, !next.showsNowPlayingPill {
            model.nowPlayingDrawerExpanded = false
        }
        if previous.showsReviewCommentPill, !next.showsReviewCommentPill {
            model.reviewCommentDrawerExpanded = false
        }
        if previous.liveVoiceHoldsComposer, !next.liveVoiceHoldsComposer {
            // The draft set aside when the call started returns when it ends.
            composerDraftController.restoreSetAsideMessage()
            synchronizeComposerMode()
        }
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: AppPreferences.ChatDisplay.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.chatDisplayRefresh += 1 }
            },
            center.addObserver(
                forName: AppPreferences.ChatTopBar.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.topBarRefresh += 1 }
            },
            // SSH Terminal turning on or off changes whether Terminal can be a
            // quick action, and the flag writes no notification of its own.
            // Every defaults write posts this, so it passes only on a change.
            center.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let enabled = AppPreferences.Experiments.sshTerminalEnabled
                    guard enabled != self.model.observedTerminalExperiment else { return }
                    self.model.observedTerminalExperiment = enabled
                    self.model.topBarRefresh += 1
                }
            },
            center.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.viewIfLoaded?.window != nil else { return }
                    self.model.contextBarCollapseToken &+= 1
                }
            },
            center.addObserver(
                forName: AudioPlayerService.stateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let objectID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
                let playing = notification.userInfo?[AudioPlayerService.playingItemIDUserInfoKey] as? String
                let loading = notification.userInfo?[AudioPlayerService.loadingItemIDUserInfoKey] as? String
                MainActor.assumeIsolated {
                    self?.handleAudioPlayerStateChange(objectID: objectID, playing: playing, loading: loading)
                }
            },
            center.addObserver(
                forName: .workspaceLinkedFileWillOpen,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let sessionId = notification.object as? String
                let sourceServerID = notification.userInfo?[Notification.Name.workspaceLinkedFileSourceServerIDKey] as? String
                MainActor.assumeIsolated {
                    guard let self, sessionId == self.sessionId,
                          let sourceServerID, sourceServerID == self.connection.currentServerId else { return }
                    // Capture while the source timeline still owns its live geometry;
                    // a push or pop can report tail geometry before the chat disappears.
                    self.scrollController.suspendForNavigation()
                }
            },
        ]
    }

    @objc private func scrimTapped() {
        model.contextBarCollapseToken &+= 1
    }

    // MARK: - Footer

    private func updateFooter() {
        let stopped = isStopped
        composer.view.isHidden = stopped
        scrim.isHidden = !model.contextBarExpanded
    }

    // MARK: - Keyboard

    func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    // MARK: - Lifecycle actions

    private func handleAppear() {
        // A stack/split shell swap remounts this chat: pick up the reading
        // position the same chat had in the other shell before history lands.
        mountedPresentation = appNavigation.workspaceNavigationPresentation
        isRouteManaged = appNavigation.routeContainsSession(sessionId)
        incognitoRouteWatch?.cancel()
        incognitoRouteWatch = nil
        let shellSwapRemount = ChatScrollShellSwapHandoff.shared.chatDidAppear(
            sessionId: sessionId,
            controller: scrollController,
            presentation: mountedPresentation
        )
        logMountTelemetry(
            "Chat appeared",
            metadata: ChatMountTelemetry.appearMetadata(
                sessionId: sessionId,
                shellSwapRemount: shellSwapRemount,
                presentation: mountedPresentation.telemetryLabel
            )
        )

        // Re-establish command routing immediately on re-entry.
        // The async sessionManager.connect() task starts shortly after appear,
        // but users can tap toolbar controls before that task has a chance to
        // refocus the connection on this session.
        connection.prepareForSessionReentry(
            sessionId,
            workspaceIdHint: workspaceIdHint,
            routeScope: focusedRouteScope
        )

        sessionManager.markAppeared()
        sessionManager.claimFocusOnAppear(connection: connection, sessionStore: sessionStore)
        if AppScenePhase.shared.pausesTimelinePresentation {
            sessionManager.coalescer.pause()
        } else if AppScenePhase.shared.isActive,
                  sessionManager.coalescer.resume() {
            sessionManager.reloadTimelineAfterPresentationOverflow(
                connection: connection,
                sessionStore: sessionStore
            )
        }
        voiceInputManager.loadPreferences()
        attachComposerDraftIfPossible()
        if let wsId = session?.workspaceId, let api = connection.apiClient {
            let ws = connection.workspaceStore.workspaces.first { $0.id == wsId }
            connection.gitStatusStore.loadInitial(
                workspaceId: wsId,
                worktreeId: session?.worktreeId,
                apiClient: api,
                gitStatusEnabled: ws?.gitStatusEnabled ?? true
            )
            // Pre-load file index for @file fuzzy search
            connection.fileIndexStore.ensureLoaded(workspaceId: wsId, apiClient: api)
        }
    }

    /// What runs each time the chat appears: bind the session, prewarm voice,
    /// then start a pending quick-voice call and send a pending quick-session
    /// message. Cancelled when the chat leaves the window.
    private func startSessionEntryTasks() {
        audioPlayer.setSessionContext(session)
        activateChatVoiceComposer(voiceInputManager)
        audioLifecycleCoordinator.setPlaybackInterrupter(audioPlayer)
        // Dictation must use the concrete player as the hardware source of truth.
        // The lifecycle coordinator owns presentation state and can be stale across
        // direct-speak/reconnect edges; using it here can make the mic appear wedged.
        voiceInputManager.setPlaybackInterrupter(audioPlayer)
        // Manager owns loop restarts. Leaving the chat must not cancel the
        // connect loop; this only binds the session identity.
        sessionManager.ensureConnected(
            connection: connection,
            sessionStore: sessionStore
        )
        loadReviewCommentsIfPossible()

        sessionEntryTask?.cancel()
        sessionEntryTask = Task { [weak self] in
            await self?.runSessionEntry()
        }
    }

    private func runSessionEntry() async {
        Task { [voiceInputManager] in
            // Pre-warm voice input pipeline in background (model check + transcriber creation)
            await voiceInputManager.prewarm(source: "chat_view_task")
        }

        // A quick voice session opens straight into its call. The call takes the
        // composer first, so the quick message below lands in it and sends during
        // the call instead of being set aside as a draft.
        if appNavigation.pendingLiveVoiceSessionId == sessionId {
            appNavigation.pendingLiveVoiceSessionId = nil
            startLiveVoice()
        }

        // Auto-send pending message from Quick Session.
        guard let message = appNavigation.pendingQuickSessionMessage else { return }
        let attachments = appNavigation.pendingQuickSessionAttachments ?? []
        // Consume immediately so it doesn't re-fire
        appNavigation.pendingQuickSessionMessage = nil
        appNavigation.pendingQuickSessionAttachments = nil

        // Pre-fill the composer so the user sees their message while connecting.
        composerDraftController.replaceMessage(
            text: message,
            pendingAttachments: attachments
        )

        // Wait for the session stream to be established AND the WebSocket
        // to be connected. The stream can briefly reach .streaming then
        // drop during app launch; retry the wait if it bounces.
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            if Task.isCancelled { return }
            if ContinuousClock.now >= deadline { return } // Timeout — user can send manually
            if isReadyForQuickSend { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Brief settle for UI
        try? await Task.sleep(for: .milliseconds(150))
        if Task.isCancelled { return }

        // Auto-send through the normal WebSocket flow
        sendPrompt()
    }

    private func handleDisappear() {
        hasAppeared = false
        sessionEntryTask?.cancel()
        sessionEntryTask = nil
        let shellSwapRemount = mountedPresentation != appNavigation.workspaceNavigationPresentation
        logMountTelemetry(
            "Chat disappeared",
            metadata: ChatMountTelemetry.disappearMetadata(
                sessionId: sessionId,
                shellSwapRemount: shellSwapRemount,
                presentation: mountedPresentation.telemetryLabel
            )
        )
        // Freeze the viewport before cleanup can publish an empty timeline
        // and make collection geometry look tail-attached during the push.
        scrollController.suspendForNavigation()
        ChatScrollShellSwapHandoff.shared.chatDidDisappear(
            sessionId: sessionId,
            controller: scrollController,
            mountedPresentation: mountedPresentation,
            currentPresentation: appNavigation.workspaceNavigationPresentation
        )
        let incognitoEnd = isRouteManaged && session?.ephemeral == true
            ? IncognitoSessionEnd(
                sessionId: sessionId,
                serverId: resolvedServerId,
                scope: focusedRouteScope,
                apiClient: apiClient,
                sessionStore: sessionStore,
                navigation: appNavigation
            )
            : nil
        let incognitoRouteWatch = incognitoEnd.map { _ in IncognitoRouteWatch() }
        self.incognitoRouteWatch?.cancel()
        self.incognitoRouteWatch = incognitoRouteWatch
        guard !appNavigation.isCoveringChat(sessionId: sessionId) else {
            if let incognitoEnd, let incognitoRouteWatch {
                incognitoEnd.endWhenRouteDrops(incognitoRouteWatch)
            }
            return
        }
        connection.extensionNotifyChipStore.collapseForHiddenChat(sessionId: sessionId)
        actionHandler.cleanup()
        // Releases this runtime's focus claim only; a newer chat for the
        // same session keeps its stream (late or repeated cleanup is a no-op).
        sessionManager.cleanup()
        let liveVoiceController = liveVoiceController
        let composerDraftStore = root?.composerDraftStore
        let sessionManager = sessionManager
        let connection = connection
        Task {
            // Runs once this navigation change settles: a pop reaches
            // AppNavigation in the stack's `didShow`, after this disappearance.
            // A chat still in the route (another tab, a page pushed above it)
            // ends when a later route change drops it.
            let endedIncognito = incognitoEnd.flatMap { $0.chatWasLeft() ? $0 : nil }
            endedIncognito?.forgetLocally()
            if endedIncognito == nil, let incognitoEnd, let incognitoRouteWatch {
                incognitoEnd.endWhenRouteDrops(incognitoRouteWatch)
            }
            await liveVoiceController.leave()
            if let composerDraftStore {
                await composerDraftStore.flush()
            }
            await sessionManager.flushSnapshotIfNeeded(connection: connection, force: true)
            await endedIncognito?.deleteSession()
        }
    }

    /// Appearance and disappearance telemetry, with the footprint both report.
    private func logMountTelemetry(_ event: String, metadata: [String: String]) {
        var metadata = metadata
        metadata["footprintMB"] =
            AppDiagnosticsService.currentFootprintMB().map(String.init) ?? "n/a"
        ClientLog.info("Navigation", event, metadata: metadata, flush: true)
    }

    private func handleScenePhaseChange() {
        if AppScenePhase.shared.pausesTimelinePresentation {
            // The timeline stays mounted while the scene cannot present a
            // frame. Keep transport and shared session status alive, but make
            // timeline publication a hard presentation boundary.
            sessionManager.coalescer.pause()
            return
        }

        guard AppScenePhase.shared.isActive else { return }
        if sessionManager.coalescer.resume() {
            sessionManager.reloadTimelineAfterPresentationOverflow(
                connection: connection,
                sessionStore: sessionStore
            )
        }
    }

    private func handleAudioPlayerStateChange(objectID: ObjectIdentifier?, playing: String?, loading: String?) {
        guard objectID == ObjectIdentifier(audioPlayer) else { return }
        audioLifecycleCoordinator.syncPlaybackState(
            playingItemID: playing?.isEmpty == false ? playing : nil,
            loadingItemID: loading?.isEmpty == false ? loading : nil
        )
    }

    private func handleSessionStatusChange(_ newStatus: SessionStatus?) {
        if newStatus != .stopping {
            actionHandler.resetStopState()
            sessionManager.cancelReconciliation()
        }

        let shouldReconnectStoppedSession: Bool
        if let newStatus, newStatus != .stopped,
           case .stopped = sessionManager.entryState {
            shouldReconnectStoppedSession = true
        } else {
            shouldReconnectStoppedSession = false
        }

        if shouldReconnectStoppedSession {
            // A visible session can enter as stopped, then become busy when a
            // external session link resumes the current turn. The stopped entry
            // path intentionally avoided WSS; restart the connect task now so
            // live parent output is subscribed. Queue sync runs after the
            // stream reconnects, so skip the pre-reconnect get_queue request.
            sessionManager.reconnect()
            return
        }

        // An attached durable session's queue is its replica's `pi.inbox`.
        guard newStatus == .busy, !connection.messageQueueStore.isConversationQueue(sessionId) else { return }
        let connection = connection
        let sessionId = sessionId
        Task {
            try? await connection.requestMessageQueue(sessionIdOverride: sessionId)
        }
    }

    private func handleEntryStateChange(_ newState: ChatSessionManager.SessionEntryState) {
        if newState == .streaming {
            actionHandler.clearReconnectFailure()
        }
    }

    private var isReadyForQuickSend: Bool {
        guard sessionManager.entryState == .streaming else { return false }
        return connection.wsClient?.status == .connected
    }

    private func handleExtensionEditorTextUpdate() {
        guard let update = chatState.extensionEditorTextUpdate,
              update.sessionId == sessionId else {
            return
        }
        applyExtensionEditorText(update.text)
    }

    private func applyExtensionToolsExpandedState() {
        guard let toolsExpanded = extensionSurfaceState.toolsExpanded else { return }
        reducer.applyExtensionToolsExpanded(toolsExpanded)
    }

#if DEBUG
    private func seedE2EChatImageAttachmentIfRequested() {
        guard !hasSeededE2EChatImageAttachment else { return }
        guard let rawBase64 = ProcessInfo.processInfo.environment["OPPI_E2E_CHAT_PENDING_IMAGE_BASE64"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBase64.isEmpty else {
            return
        }

        hasSeededE2EChatImageAttachment = true
        let compactBase64 = rawBase64.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compactBase64, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else {
            return
        }

        let configuredMimeType = ProcessInfo.processInfo.environment["OPPI_E2E_CHAT_PENDING_IMAGE_MIME_TYPE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let mimeType = configuredMimeType.isEmpty ? "image/png" : configuredMimeType
        let attachment = PendingAttachment(
            id: "e2e-chat-image",
            source: .image,
            displayName: Self.e2eImageDisplayName(mimeType: mimeType),
            thumbnail: image,
            imageAttachment: ImageAttachment(data: compactBase64, mimeType: mimeType),
            localFileData: nil,
            localMimeType: nil
        )
        let current = composerDraftController.pendingAttachments
        if !current.contains(where: { $0.id == attachment.id }) {
            composerDraftController.setPendingAttachments(current + [attachment])
        }
    }

    private static func e2eImageDisplayName(mimeType: String) -> String {
        switch mimeType.split(separator: ";", maxSplits: 1).first?.lowercased() {
        case "image/jpeg", "image/jpg":
            return "e2e-image.jpg"
        case "image/gif":
            return "e2e-image.gif"
        case "image/webp":
            return "e2e-image.webp"
        default:
            return "e2e-image.png"
        }
    }
#endif
}

// MARK: - Observed values

/// The values the chat reacts to when they change; the first pass records them.
struct ChatObservedValues: Equatable {
    var isInitialized = false
    var sessionTitle: String?
    var sessionModel: String?
    var sessionStatus: SessionStatus?
    var entryState: ChatSessionManager.SessionEntryState?
    var askRequestID: String?
    var toolsExpanded: Bool?
    var editorTextRevision: Int?
    var jumpToBottomVisible = false
    var showsNowPlayingPill = false
    var showsReviewCommentPill = false
    var liveVoiceHoldsComposer = false
    var draftKey: ChatDraftAttachmentKey?
    var reviewCommentLoadKey: ReviewCommentLoadKey?
    var scenePhaseIsActive = false
    var scenePhasePausesTimeline = false

    init() {}

    init(
        sessionTitle: String?,
        sessionModel: String?,
        sessionStatus: SessionStatus?,
        entryState: ChatSessionManager.SessionEntryState,
        askRequestID: String?,
        toolsExpanded: Bool?,
        editorTextRevision: Int?,
        jumpToBottomVisible: Bool,
        showsNowPlayingPill: Bool,
        showsReviewCommentPill: Bool,
        liveVoiceHoldsComposer: Bool,
        draftKey: ChatDraftAttachmentKey,
        reviewCommentLoadKey: ReviewCommentLoadKey,
        scenePhaseIsActive: Bool,
        scenePhasePausesTimeline: Bool
    ) {
        isInitialized = true
        self.sessionTitle = sessionTitle
        self.sessionModel = sessionModel
        self.sessionStatus = sessionStatus
        self.entryState = entryState
        self.askRequestID = askRequestID
        self.toolsExpanded = toolsExpanded
        self.editorTextRevision = editorTextRevision
        self.jumpToBottomVisible = jumpToBottomVisible
        self.showsNowPlayingPill = showsNowPlayingPill
        self.showsReviewCommentPill = showsReviewCommentPill
        self.liveVoiceHoldsComposer = liveVoiceHoldsComposer
        self.draftKey = draftKey
        self.reviewCommentLoadKey = reviewCommentLoadKey
        self.scenePhaseIsActive = scenePhaseIsActive
        self.scenePhasePausesTimeline = scenePhasePausesTimeline
    }
}

struct ChatDraftAttachmentKey: Equatable {
    let key: ComposerDraftKey?
    let isEphemeral: Bool
}

/// Cancelled when the chat that started it shows again, so the session it
/// watches stays. A stack/split swap remounts the chat in a new controller and
/// leaves the old controller's watch running; when the session is later left,
/// both end it, and the second delete's 404 counts as done.
@MainActor
final class IncognitoRouteWatch {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

/// Ends an incognito session whose chat was left: the server stops and
/// deletes it, and this device drops its row, cached trace, and lock, so it
/// shows in no list. A failed delete leaves it on the server, and the next
/// list sync shows it again.
@MainActor
struct IncognitoSessionEnd: Sendable {
    let sessionId: String
    let serverId: String?
    let scope: SessionRouteScope?
    let apiClient: APIClient?
    let sessionStore: SessionStore
    let navigation: AppNavigation

    /// Popped or replaced in the workspace route. A push above the chat, a tab
    /// switch, a lock cover, a stack/split swap, or reopening the same session
    /// all keep it in the route.
    func chatWasLeft() -> Bool {
        !navigation.routeContainsSession(sessionId)
    }

    func forgetLocally() {
        sessionStore.remove(id: sessionId)
    }

    /// The chat is hidden but its session is still in the route. The chat
    /// may never show again (a sidebar pick or a notification replaces the
    /// whole stack without appearance callbacks), so the route decides.
    func endWhenRouteDrops(_ watch: IncognitoRouteWatch) {
        guard !watch.isCancelled else { return }
        if chatWasLeft() {
            forgetLocally()
            Task { await deleteSession() }
            return
        }
        withObservationTracking {
            _ = chatWasLeft()
        } onChange: {
            // `onChange` runs before the change lands; check on the next turn.
            Task { @MainActor in endWhenRouteDrops(watch) }
        }
    }

    func deleteSession() async {
        if let serverId {
            await TimelineCache.shared.removeTrace(sessionId, serverId: serverId)
        } else {
            await TimelineCache.shared.removeTrace(sessionId)
        }
        guard let apiClient, let scope else {
            ClientLog.warning("Navigation", "Incognito session not deleted: no server route", metadata: ["sessionId": sessionId])
            return
        }
        do {
            try await apiClient.deleteSession(scope: scope, sessionId: sessionId)
        } catch let error as APIError {
            // Already gone on the server: the same outcome as a delete.
            guard case .server(let status, _) = error, status == 404 else {
                logDeleteFailure(error)
                return
            }
        } catch {
            logDeleteFailure(error)
            return
        }
        if let serverId {
            ScopedLockService.shared.forgetSession(serverId: serverId, sessionId: sessionId)
        }
    }

    private func logDeleteFailure(_ error: Error) {
        ClientLog.warning(
            "Navigation",
            "Incognito session delete failed",
            metadata: ["sessionId": sessionId, "error": error.localizedDescription]
        )
    }
}
