import UIKit

// The chat's composer: the draft modes (message, Ask answer, review comment),
// voice and Live Voice, review comments, and the send path.

extension ChatViewController {
    static func resolvedComposerMode(
        hasReviewComment: Bool,
        hasAskRequest: Bool
    ) -> ChatComposerDraftController.Mode {
        if hasReviewComment { return .reviewComment }
        if hasAskRequest { return .ask }
        return .message
    }

    /// Shared by the viewer destination and composer callback.
    /// Accept only if the message-mode draft actually stored the attachment.
    @discardableResult
    static func deliverCanvasToComposer(
        attachment: PendingAttachment,
        recognizedText _: String,
        draftController: ChatComposerDraftController
    ) -> Bool {
        var nextAttachments = draftController.pendingAttachments
        if !nextAttachments.contains(where: { $0.id == attachment.id }) {
            nextAttachments.append(attachment)
        }
        return draftController.setPendingAttachments(nextAttachments)
            && draftController.pendingAttachments.contains(where: { $0.id == attachment.id })
    }

    static func resolvedComposerAskRequest(
        _ askRequest: AskRequest?,
        hasReviewComment: Bool
    ) -> AskRequest? {
        hasReviewComment ? nil : askRequest
    }

    static func localSlashCommand(for text: String) -> LocalSlashCommand? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.caseInsensitiveCompare("/compact") == .orderedSame ? .compact : nil
    }

    static func availableSlashCommands(from serverCommands: [SlashCommand]) -> [SlashCommand] {
        guard !serverCommands.contains(where: {
            $0.name.caseInsensitiveCompare("compact") == .orderedSame
        }) else {
            return serverCommands
        }

        return serverCommands + [SlashCommand(
            name: "compact",
            description: "Compact context",
            source: .builtin
        )]
    }

    /// The composer writes its text here; the mode decides which draft it edits.
    func setComposerText(_ newText: String) {
        let mode = Self.resolvedComposerMode(
            hasReviewComment: model.activeReviewCommentRequest != nil,
            hasAskRequest: activeComposerAskRequest != nil
        )
        composerDraftController.updateVisibleText(newText, for: mode)
    }

    /// Message mode stores an attachment-bar update; a refused non-message
    /// update discards any unreferenced draft files.
    func setComposerPendingAttachments(_ newAttachments: [PendingAttachment]) {
        composerDraftController.setPendingAttachments(newAttachments)
    }

    /// The bar shows the message draft's attachments; an Ask answer or a
    /// review comment carries none.
    var composerVisibleAttachments: [PendingAttachment] {
        composerDraftController.mode == .message ? composerDraftController.pendingAttachments : []
    }

    var availableSlashCommands: [SlashCommand] {
        Self.availableSlashCommands(from: chatState.slashCommands)
    }

    private var messageQueueState: MessageQueueState {
        connection.messageQueueStore.queue(for: sessionId)
    }

    var hasQueuedMessages: Bool {
        !messageQueueState.steering.isEmpty || !messageQueueState.followUp.isEmpty
    }

    var showsMessageQueue: Bool {
        hasQueuedMessages || model.messageQueueError != nil
    }

    var messageQueueSurfaceConfiguration: MessageQueueSurfaceConfiguration {
        MessageQueueSurfaceConfiguration(
            queue: messageQueueState,
            onRemove: { [weak self] itemId in
                guard let self else { return }
                self.model.messageQueueError = nil
                try await self.connection.removeQueuedMessage(itemId: itemId, sessionIdOverride: self.sessionId)
            },
            onEditInComposer: { [weak self] in try await self?.restoreQueuedMessagesToComposer() },
            error: model.messageQueueError
        )
    }

    /// The session's extension surfaces without the working text. The working
    /// row observes that text itself; reading it here would rerun this screen's
    /// `updateProperties()` on every elapsed-time tick.

    var activeComposerAskRequest: AskRequest? {
        connection.askRequestStore.pending(for: sessionId)
    }

    var composerAskRequest: AskRequest? {
        Self.resolvedComposerAskRequest(
            activeComposerAskRequest,
            hasReviewComment: model.activeReviewCommentRequest != nil
        )
    }

    var hasBlockingExtensionInput: Bool {
        activeComposerAskRequest != nil || connection.hasPendingExtensionDialog(for: sessionId)
    }

    /// The router review-comment selections reach this chat through. Rebuilt
    /// only when the quick-comment templates change, so the canvas anchor and
    /// the panels keep one router.
    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter {
        let templates = QuickCommentTemplate.quickCommentTemplates(root?.quickCommentTemplateStore.templates ?? [])
        let ids = templates.map(\.id)
        if let cached = cachedReviewCommentRouter, cached.templates == ids {
            return cached.router
        }
        let router = ReviewCommentSelectionRouter(
            dispatchWithPresentation: { [weak self] request, _ in
                self?.handleReviewCommentSelection(request)
            },
            inlineSave: { [weak self] body, request in
                self?.saveReviewComment(body: body, request: request) ?? false
            },
            inlineQuickComments: templates,
            voiceInputManager: voiceInputManager,
            stash: reviewComments
        )
        cachedReviewCommentRouter = (ids, router)
        return router
    }

    // MARK: - View lifecycle

    // MARK: - Composer actions

    func updateFileSuggestions(query: String?) {
        if let query {
            connection.fetchFileSuggestions(query: query)
        } else {
            connection.clearFileSuggestions()
        }
    }

    private func handleReviewCommentSelection(_ request: ReviewCommentSelectionRequest) {
        model.activeReviewCommentRequest = request
        composerDraftController.setMode(.reviewComment, resetTransientInput: true)
        model.composerTextBeforeRecording = nil
        composer.requestFocus()
        if request.startsDictation { composer.requestDictation(owner: .reviewCommentMenu) }
        model.contextBarCollapseToken &+= 1
    }

    func applyQuickCommentTemplate(_ template: QuickCommentTemplate) {
        let text = template.quickCommentText
        guard !text.isEmpty else { return }
        let trimmed = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            composerDraftController.text = text
        } else if composerDraftController.text.hasSuffix("\n") {
            composerDraftController.text += text
        } else {
            composerDraftController.text += "\n" + text
        }
        composer.requestFocus()
    }

    func cancelReviewCommentInput() {
        model.activeReviewCommentRequest = nil
        synchronizeComposerMode()
        model.composerTextBeforeRecording = nil
    }

    func sendComposerAction(
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance = .afterSuccess
    ) {
        if model.activeReviewCommentRequest != nil {
            sendActiveReviewComment()
        } else {
            sendPrompt(draftClearance: draftClearance)
        }
    }

    func stopTurn() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let abort: @MainActor () async -> Void = { [weak self] in
                guard let self, self.connection.isFocusedSession(self.sessionId) else { return }
                self.actionHandler.stop(
                    connection: self.connection, reducer: self.reducer, sessionStore: self.sessionStore,
                    sessionManager: self.sessionManager, sessionId: self.sessionId
                )
            }
            // Nothing queued: send a plain Stop. take_queue only exists on newer
            // servers, so requiring it here would leave Stop dead on an older one.
            guard self.hasQueuedMessages else {
                await abort()
                return
            }
            await MessageQueueComposerRestore.stopAfterRestoring(
                restore: { [weak self] in try await self?.restoreQueuedMessagesToComposer() },
                abort: abort,
                onError: { [weak self] error in self?.model.messageQueueError = error.localizedDescription }
            )
        }
    }

    func forceStopTurn() {
        actionHandler.forceStop(
            connection: connection, reducer: reducer,
            sessionStore: sessionStore, sessionId: sessionId
        )
    }

    private func restoreQueuedMessagesToComposer() async throws {
        guard connection.isFocusedSession(sessionId) else { return }
        model.messageQueueError = nil
        let withdrawn = try await connection.takeMessageQueue(sessionIdOverride: sessionId)
        guard let plan = MessageQueueComposerRestore.plan(
            queue: withdrawn,
            currentText: composerDraftController.text,
            currentPendingAttachments: composerDraftController.pendingAttachments
        ) else { return }
        composerDraftController.replaceMessage(text: plan.text, pendingAttachments: plan.pendingAttachments)
        model.composerTextBeforeRecording = nil
        if !model.showComposer { composer.requestFocus() }
    }

    private func sendActiveReviewComment() {
        guard let request = model.activeReviewCommentRequest else { return }
        let body = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let didSave = saveReviewComment(body: body, request: request)
        if didSave {
            model.activeReviewCommentRequest = nil
            synchronizeComposerMode()
            model.composerTextBeforeRecording = nil
            loadReviewCommentsIfPossible()
        }
    }

    func presentComposer() {
        guard activeComposerAskRequest == nil else { return }
        AppHaptics.toolbarExpansion()
        model.showComposer = true
    }

    func stageWorkspaceReviewInCurrentSession(prompt: String, files: [PendingFileReference]) {
        composerDraftController.mutateMessage { text, repoPointers in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = prompt
            } else if text.hasSuffix("\n\n") {
                text += prompt
            } else if text.hasSuffix("\n") {
                text += "\n" + prompt
            } else {
                text += "\n\n" + prompt
            }

            for file in files where !repoPointers.contains(where: { $0.id == file.id }) {
                repoPointers.append(file)
            }
        }

        revealComposer()
    }

    func applyExtensionEditorText(_ text: String) {
        composerDraftController.replaceMessage(text: text)
        revealComposer()
    }

    /// Shows the expanded composer for a stopped session, else focuses the
    /// inline one.
    private func revealComposer() {
        if isStopped {
            model.showComposer = true
        } else if !model.showComposer {
            composer.requestFocus()
        }
    }

    func loadReviewCommentsIfPossible() {
        reviewComments.load(localScopeId: reviewCommentLocalScopeId, sessionId: sessionId)
    }

    @discardableResult
    func saveReviewComment(body: String, request: ReviewCommentSelectionRequest) -> Bool {
        if let error = reviewComments.save(
            body: body,
            request: request,
            localScopeId: reviewCommentLocalScopeId,
            sessionId: sessionId
        ) {
            connection.extensionToast = error
            return false
        }
        AppHaptics.success()
        return true
    }

    func deleteReviewComment(_ comment: ReviewComment) {
        reviewComments.delete(comment)
    }

    private func clearSentReviewComments(ids: [String]) {
        reviewComments.clearSent(ids: ids)
    }

    func attachComposerDraftIfPossible() {
        guard let composerDraftStore = root?.composerDraftStore, let composerDraftKey else { return }
        composerDraftController.attach(
            store: composerDraftStore,
            key: composerDraftKey,
            isEphemeral: composerDraftIsMemoryOnly
        )
        synchronizeComposerMode()
    }

    func synchronizeComposerMode() {
        let mode = Self.resolvedComposerMode(
            hasReviewComment: model.activeReviewCommentRequest != nil,
            hasAskRequest: activeComposerAskRequest != nil
        )
        if mode == .ask {
            model.showComposer = false
        }
        composerDraftController.setMode(mode)
    }

    private var chatDictationServerId: String? {
        if let id = connection.currentServerId, !id.isEmpty { return id }
        if let credentials = connection.credentials {
            return "\(credentials.host):\(credentials.port)"
        }
        return nil
    }

    func prepareChatVoiceInput(_ manager: VoiceInputManager) async throws {
        ComposerShared.prepareConversationVoiceInput(
            manager: manager,
            serverId: chatDictationServerId,
            sessionId: sessionId,
            credentials: connection.credentials,
            connection: connection,
            playbackInterrupter: audioPlayer,
            workspaceId: session?.workspaceId ?? workspaceIdHint
        )
    }

    func activateChatVoiceComposer(_ manager: VoiceInputManager) {
        guard let serverId = chatDictationServerId else { return }
        _ = manager.activateConversationComposer(
            serverId: serverId,
            sessionId: sessionId,
            credentials: connection.credentials,
            connection: connection,
            workspaceId: session?.workspaceId ?? workspaceIdHint
        )
        manager.setPlaybackInterrupter(audioPlayer)
    }

    var liveVoiceCallOwnsMic: Bool { liveVoiceController.isLive }

    /// The composer's Live Voice entry: none while the Live Voice experiment is off, during a
    /// call, for a terminal Pi mirror, which cannot answer out loud, or when the server's voice
    /// backend is not set up.
    var liveVoiceEntry: (() -> Void)? {
        guard AppPreferences.Experiments.liveVoiceEnabled, connection.liveVoiceAvailable,
              !liveVoiceCallOwnsMic, session?.runtime != .piTui else {
            return nil
        }
        return { [weak self] in self?.startLiveVoice() }
    }

    /// Live Voice talks to this chat's session: its agent hears the caller and answers out loud.
    func startLiveVoice() {
        guard let routeScope = focusedRouteScope else { return }
        // The call starts with an empty field, now rather than on the next pass, so a
        // message placed in the composer right after (a Quick Session's first) is the
        // call's own and sends, not a draft set aside.
        composerDraftController.setAsideMessage()
        model.composerTextBeforeRecording = nil
        synchronizeComposerMode()
        let liveVoiceController = liveVoiceController
        let sessionId = sessionId
        let connection = connection
        Task {
            await liveVoiceController.start(
                sessionId: sessionId,
                routeScope: routeScope,
                using: connection
            )
        }
    }

    func dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle() {
        // A send that settles after the chat left must not dismiss another screen's keyboard.
        guard !actionHandler.hasLeftChat,
              composerDraftController.mode == .message,
              composerDraftController.text.isEmpty,
              composerDraftController.repoPointers.isEmpty,
              composerDraftController.pendingAttachments.isEmpty,
              model.composerTextBeforeRecording == nil else {
            return
        }
        dismissKeyboard()
    }

    private func uploadPendingLocalAttachments(
        _ sourceAttachments: [PendingAttachment]
    ) async throws -> [ChatAttachmentRef] {
        guard let api = connection.apiClient else {
            throw APIError.server(status: 503, message: "No server connection available")
        }
        guard let routeScope = focusedRouteScope else {
            throw TreeNavigationError.sessionNotReady
        }
        return try await PendingAttachmentUploader.upload(
            sourceAttachments,
            api: api,
            scope: routeScope,
            sessionId: sessionId,
            onProgress: { [weak self] in self?.model.attachmentPreparationText = $0 }
        )
    }

    private func uploadPreparationErrorMessage(_ error: Error) -> String {
        if case let APIError.server(status, message) = error {
            if status == 404 {
                return "This server does not support attachment uploads yet."
            }
            return message
        }
        return error.localizedDescription
    }

    func handleComposerAskSubmit(
        _ ask: AskRequest,
        _ answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) {
        guard let payload = ask.responsePayload(from: answers) else {
            connection.extensionToast = "Couldn't prepare this response. Try again."
            completion(.retryableFailure)
            return
        }
        deliverComposerAskResponse(ask, payload: payload, completion: completion)
    }

    func handleComposerAskIgnoreAll(
        _ ask: AskRequest,
        completion: @escaping AskResponseSubmission.Completion
    ) {
        deliverComposerAskResponse(ask, payload: .cancelled, completion: completion)
    }

    private func deliverComposerAskResponse(
        _ ask: AskRequest,
        payload: ExtensionUIResponsePayload,
        completion: @escaping AskResponseSubmission.Completion
    ) {
        guard activeComposerAskRequest?.id == ask.id else {
            completion(.completed)
            return
        }
        composerDraftController.clearSubmittedAskAnswer()
        let connection = connection
        Task {
            let result = await Self.deliverAskResponse(
                send: {
                    try await connection.respondToExtensionUI(
                        id: ask.id, sessionId: ask.sessionId, payload: payload
                    )
                },
                reconcile: { await connection.hydrateSessionDialogs(sessionId: ask.sessionId) },
                isPending: { connection.askRequestStore.pending(for: ask.sessionId)?.id == ask.id },
                showFailure: { connection.extensionToast = "Couldn't confirm response: \($0.localizedDescription). Try again." }
            )
            completion(result)
        }
    }

    /// A failed transport can have delivered before its acknowledgement was
    /// lost. Repair the existing dialog projection first. If still pending (or
    /// repair is unavailable), retry the same Ask ID: the server's first-wins
    /// response handling ignores IDs already settled, never answers twice.
    static func deliverAskResponse(
        send: () async throws -> Void,
        reconcile: () async -> Void,
        isPending: () -> Bool,
        showFailure: (Error) -> Void
    ) async -> AskResponseSubmission.Result {
        do {
            try await send()
            return .completed
        } catch {
            // Do not start a stale request's repair after live settlement or
            // replacement. Hydration also fences store writes during its await.
            guard isPending() else { return .completed }
            await reconcile()
            guard isPending() else { return .completed }
            showFailure(error)
            return .retryableFailure
        }
    }

    var composerIsSending: Bool {
        Self.composerSendIsInFlight(
            isPreparingAttachments: model.isPreparingAttachments,
            actionIsSending: actionHandler.isSending,
            draftSubmissionIsInFlight: composerDraftController.isSubmissionInFlight
        )
    }

    static func composerSendIsInFlight(
        isPreparingAttachments: Bool,
        actionIsSending: Bool,
        draftSubmissionIsInFlight: Bool
    ) -> Bool {
        isPreparingAttachments || actionIsSending || draftSubmissionIsInFlight
    }

    static func beginComposerSubmission(
        draftController: ChatComposerDraftController,
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance,
        isPreparingAttachments: Bool,
        actionIsSending: Bool
    ) -> ChatComposerDraftController.SubmissionSnapshot? {
        guard !composerSendIsInFlight(
            isPreparingAttachments: isPreparingAttachments,
            actionIsSending: actionIsSending,
            draftSubmissionIsInFlight: draftController.isSubmissionInFlight
        ) else { return nil }
        return draftController.beginSubmission(draftClearance: draftClearance)
    }

    enum ComposerPromptSendOutcome {
        case ignored
        case uploaded(
            submission: ChatComposerDraftController.SubmissionSnapshot,
            attachments: [ChatAttachmentRef],
            sourceAttachments: [PendingAttachment]
        )
        case failed(Error)
    }

    /// Production send path for inline and expanded composers. Uploads the
    /// captured submission's Class B draft files, then the caller dispatches.
    struct ComposerPromptSendState {
        var isPreparingAttachments: Bool
    }

    static func sendPrompt(
        draftController: ChatComposerDraftController,
        state: ComposerPromptSendState,
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance,
        actionIsSending: Bool,
        upload: ([PendingAttachment]) async throws -> [ChatAttachmentRef]
    ) async -> (ComposerPromptSendOutcome, ComposerPromptSendState) {
        var state = state
        guard let submission = beginComposerSubmission(
            draftController: draftController,
            draftClearance: draftClearance,
            isPreparingAttachments: state.isPreparingAttachments,
            actionIsSending: actionIsSending
        ) else {
            return (.ignored, state)
        }

        let sourceAttachments = submission.pendingAttachments
        state.isPreparingAttachments = true
        do {
            let attachments = try await upload(sourceAttachments)
            state.isPreparingAttachments = false
            return (
                .uploaded(
                    submission: submission,
                    attachments: attachments,
                    sourceAttachments: sourceAttachments
                ),
                state
            )
        } catch {
            state.isPreparingAttachments = false
            draftController.failSubmission(submission)
            return (.failed(error), state)
        }
    }

    func beginComposerSubmission(
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance
    ) -> ChatComposerDraftController.SubmissionSnapshot? {
        Self.beginComposerSubmission(
            draftController: composerDraftController,
            draftClearance: draftClearance,
            isPreparingAttachments: model.isPreparingAttachments,
            actionIsSending: actionHandler.isSending
        )
    }


    // swiftlint:disable:next function_body_length
    func sendPrompt(
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance = .afterSuccess
    ) {
        guard !composerIsSending else { return }

        let rawTrimmedInput = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.localSlashCommand(for: rawTrimmedInput) == .compact {
            guard let submission = beginComposerSubmission(draftClearance: draftClearance) else { return }
            model.composerTextBeforeRecording = nil
            actionHandler.compact(
                connection: connection,
                reducer: reducer,
                sessionId: sessionId,
                onSendSucceeded: { [weak self] in
                    self?.composerDraftController.completeSubmission(submission)
                    self?.dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                },
                onAsyncFailure: { [weak self] in
                    self?.composerDraftController.failSubmission(submission)
                }
            )
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/reload") == .orderedSame {
            guard let submission = beginComposerSubmission(draftClearance: draftClearance) else { return }
            model.composerTextBeforeRecording = nil
            actionHandler.reloadResources(
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                sessionId: sessionId,
                onSendSucceeded: { [weak self] in
                    self?.composerDraftController.completeSubmission(submission)
                    self?.dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                },
                onAsyncFailure: { [weak self] in
                    self?.composerDraftController.failSubmission(submission)
                }
            )
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/share") == .orderedSame {
            sendShareSlashCommand(clearComposer: true, draftClearance: draftClearance)
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/review-comments") == .orderedSame {
            composerDraftController.clearMessage()
            model.composerTextBeforeRecording = nil
            connection.extensionToast = "Review comments use compact inline selection now."
            dismissKeyboard()
            return
        }

        let originalInputText = composerDraftController.text
        let originalPendingRepoPointers = composerDraftController.repoPointers
        let timelineItems = reducer.items
        let reviewText = reviewComments.appendReviewBlock(
            to: originalInputText,
            pathFormatting: reviewCommentPathFormatting,
            currentSourceRevision: { comment in
                SemanticCommentFreshness.currentRevision(for: comment, timelineItems: timelineItems)
            }
        )
        let text = PendingFileReference.appendReferenceBlock(to: reviewText, files: originalPendingRepoPointers)
        let stagedReviewCommentIds = reviewComments.stagedCommentIds
        let sessionManagerRef = sessionManager
        let scrollRef = scrollController

        Task { @MainActor [weak self] in
            guard let self else { return }
            let (outcome, nextState) = await Self.sendPrompt(
                draftController: self.composerDraftController,
                state: ComposerPromptSendState(isPreparingAttachments: self.model.isPreparingAttachments),
                draftClearance: draftClearance,
                actionIsSending: self.actionHandler.isSending,
                upload: { [weak self] sourceAttachments in
                    guard let self else { return [] }
                    let pendingLocalAttachments = sourceAttachments.filter {
                        $0.source == .image || $0.source == .localFile
                    }
                    self.model.attachmentPreparationText = pendingLocalAttachments.isEmpty ? nil : "Uploading attachments…"
                    return try await self.uploadPendingLocalAttachments(sourceAttachments)
                }
            )
            self.model.isPreparingAttachments = nextState.isPreparingAttachments
            self.model.attachmentPreparationText = nil
            switch outcome {
            case .ignored:
                return
            case .failed(let error):
                self.reducer.process(.error(sessionId: self.sessionId, message: self.uploadPreparationErrorMessage(error)))
            case .uploaded(let submission, let attachments, let sourceAttachments):
                let optimisticDisplayText = UserMessageAttachmentPresentation.makeDisplayText(
                    text: reviewText,
                    pendingAttachments: sourceAttachments,
                    pendingRepoPointers: originalPendingRepoPointers,
                    uploadedAttachments: attachments
                )
                let optimisticImages = sourceAttachments.compactMap(\.imageAttachment)
                let dispatchIsBusy = self.isBusy
                let sendBehavior = ComposerAutocomplete.streamingBehavior(
                    for: rawTrimmedInput,
                    isBusy: dispatchIsBusy,
                    selected: self.model.busyStreamingBehavior,
                    commands: self.availableSlashCommands
                )
                let restored = self.actionHandler.sendPrompt(
                    text: text,
                    attachments: attachments,
                    optimisticDisplayText: optimisticDisplayText,
                    optimisticImages: optimisticImages,
                    isBusy: dispatchIsBusy,
                    busyStreamingBehavior: sendBehavior,
                    connection: self.connection,
                    reducer: self.reducer,
                    sessionId: self.sessionId,
                    sessionStore: self.sessionStore,
                    sessionManager: self.sessionManager,
                    onDispatchStarted: { [weak self] in
                        guard let self else { return }
                        // The timeline row or queue item is the send confirmation.
                        // Waiting for ack left this draft in the field while the
                        // agent was already working on it.
                        self.composerDraftController.clearVisibleDraftForDispatchedSubmission(submission)
                        self.model.composerTextBeforeRecording = nil

                        // Scroll after the optimistic row is in the collection.
                        // The draft clear above must not wait for that turn.
                        DispatchQueue.main.async {
                            scrollRef.requestScrollToBottom()
                        }
                    },
                    onSendSucceeded: { [weak self] in
                        self?.composerDraftController.completeSubmission(submission)
                        self?.clearSentReviewComments(ids: stagedReviewCommentIds)
                        self?.dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                    },
                    onAsyncFailure: { [weak self] _, _ in
                        self?.composerDraftController.failSubmission(submission)
                    },
                    onNeedsReconnect: {
                        sessionManagerRef.reconnect()
                    }
                )
                if !restored.isEmpty {
                    self.composerDraftController.failSubmission(submission)
                }
            }
        }
    }
}
