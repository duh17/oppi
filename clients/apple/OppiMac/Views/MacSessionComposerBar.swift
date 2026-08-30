import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacComposerSubmissionGate {
    private(set) var activeID: UUID?

    var isActive: Bool { activeID != nil }

    mutating func begin() -> UUID? {
        guard activeID == nil else { return nil }
        let id = UUID()
        activeID = id
        return id
    }

    mutating func finish(_ id: UUID) {
        guard activeID == id else { return }
        activeID = nil
    }

    mutating func reset() {
        activeID = nil
    }
}

/// Docked session composer: queue, ask, attachments, and the send field.
///
/// Layout matches iOS ChatInputBar control placement:
/// full-width glass capsule with send/stop inside; + , steering, model, and
/// thinking on the action row below the text field.
struct MacSessionComposerBar: View {
    let store: MacSessionTraceStore
    var sessionFocus: FocusState<KeybindingFocus?>.Binding
    @Environment(\.theme) private var theme
    /// Compact vs iOS 44pt HIG target; fill/stroke/glyph still match ChatInputBar.
    private let actionVisualDiameter: CGFloat = 32
    @State private var draft = ""
    @State private var pendingAttachments: [MacPendingAttachment] = []
    @State private var pastedFileLifetime = MacPastedAttachmentLifetime()
    @State private var composerLocalError: String?
    @State private var isAttachmentDropTarget = false
    @State private var isModelPickerPresented = false
    @State private var showReviewCommentStash = false
    @State private var dictation = MacComposerDictationController()
    @State private var submissionGate = MacComposerSubmissionGate()

    init(
        store: MacSessionTraceStore,
        sessionFocus: FocusState<KeybindingFocus?>.Binding,
        initialDraft: String = "",
        initialAttachments: [MacPendingAttachment] = []
    ) {
        self.store = store
        self.sessionFocus = sessionFocus
        _draft = State(initialValue: initialDraft)
        _pendingAttachments = State(initialValue: initialAttachments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if MacSessionWindowChrome.showsComposerStateBar(
                surface: composerSurface,
                hasTimelineItems: !store.items.isEmpty
            ) {
                sessionStateBar
            } else if composerSurface.acceptsInput {
                if hasAboveComposerAuxiliaryContent {
                    VStack(alignment: .leading, spacing: 10) {
                        if hasEditorAuxiliaryContent {
                            ScrollView(.vertical) {
                                editorAuxiliaryContent
                            }
                            .scrollBounceBehavior(.basedOnSize)
                        }

                        if hasAboveEditorExtensionSurface {
                            // Extension surfaces already own their vertical
                            // scrolling; do not wrap them in another scroller.
                            MacExtensionSurfacePanel(
                                surface: store.extensionSurface,
                                placement: .aboveEditor
                            )
                        }
                    }
                    .frame(maxHeight: composerAuxiliaryRegionMaximumHeight)
                    .accessibilityIdentifier("mac.composer.auxiliary")
                }

                composerCapsule

                if hasBelowEditorExtensionSurface {
                    MacExtensionSurfacePanel(
                        surface: store.extensionSurface,
                        placement: .belowEditor
                    )
                    .frame(maxHeight: composerAuxiliaryRegionMaximumHeight)
                }
            }
        }
        .onChange(of: draft) { _, _ in
            loadFileIndexIfNeeded()
            loadSlashCommandsIfNeeded()
        }
        .onChange(of: dictation.composedDraft) { _, composed in
            if dictation.isLive {
                draft = composed
            }
        }
        .onChange(of: store.selectedTarget?.sessionId) { previousSessionID, currentSessionID in
            guard MacSessionWindowChrome.shouldResetComposer(
                previousSessionID: previousSessionID,
                currentSessionID: currentSessionID
            ) else { return }
            composerLocalError = nil
            draft = ""
            pendingAttachments = []
            isAttachmentDropTarget = false
            submissionGate.reset()
            dictation.resetForSessionChange()
            loadSlashCommandsIfNeeded()
        }
        .onChange(of: pendingAttachments) { previous, next in
            MacPastedAttachmentFileStore.removeOwned(in: previous, notIn: next)
            pastedFileLifetime.replace(with: next)
        }
        .onDisappear {
            Task { await dictation.cancel() }
        }
        .sheet(isPresented: $isModelPickerPresented) {
            MacModelPickerSheet(
                models: store.availableModels,
                currentModel: store.session?.model,
                isLoading: store.isLoadingModels,
                error: store.modelLoadError,
                refresh: { await store.loadAvailableModelsFromLocalConfig() },
                selectModel: { model in
                    Task { await store.setModelFromLocalConfig(model) }
                },
                setDefaultModel: store.session?.supportsPersistingDefaults == false
                    ? nil
                    : { model in
                        Task { await store.setModelFromLocalConfig(model, persist: true) }
                    }
            )
        }
        .sheet(item: Binding(
            get: { store.pendingReviewCommentDraft.map(IdentifiableReviewCommentDraft.init) },
            set: { if $0 == nil { store.cancelReviewCommentDraft() } }
        )) { wrapper in
            MacReviewCommentComposerSheet(
                draft: wrapper.draft,
                onSave: { body in
                    store.saveReviewComment(body: body, draft: wrapper.draft)
                },
                onCancel: store.cancelReviewCommentDraft
            )
        }
        .sheet(isPresented: $showReviewCommentStash) {
            MacReviewCommentStashSheet(
                comments: store.stagedReviewComments,
                onEdit: { comment, body in
                    store.updateReviewComment(comment, body: body)
                },
                onDelete: store.deleteReviewComment,
                onClose: { showReviewCommentStash = false }
            )
        }
    }

    private var composerSurface: MacSessionComposerSurface {
        MacSessionWindowChrome.composerSurface(
            for: store.session?.status,
            isLoading: store.isLoading
        )
    }

    private var visibleEditorError: String? {
        let error = composerLocalError
            ?? dictation.lastError
            ?? (store.items.isEmpty ? nil : store.lastError)
        guard let error, !error.isEmpty else { return nil }
        return error
    }

    private var showsMessageQueueEditor: Bool {
        !store.messageQueue.steering.isEmpty
            || !store.messageQueue.followUp.isEmpty
            || store.isRefreshingQueue
            || store.isUpdatingQueue
            || !(store.messageQueueError?.isEmpty ?? true)
    }

    private var hasEditorAuxiliaryContent: Bool {
        showsMessageQueueEditor
            || store.currentAskRequest != nil
            || store.attachmentPreparationText != nil
            || visibleEditorError != nil
            || !slashSuggestions.isEmpty
            || activeFileMentionQuery != nil
            || store.stagedReviewCommentCount > 0
    }

    private var hasAboveEditorExtensionSurface: Bool {
        store.currentAskRequest == nil
            && store.extensionSurface.hasVisibleContent(in: .aboveEditor)
    }

    private var hasBelowEditorExtensionSurface: Bool {
        store.currentAskRequest == nil
            && store.extensionSurface.hasVisibleContent(in: .belowEditor)
    }

    private var hasAboveComposerAuxiliaryContent: Bool {
        hasEditorAuxiliaryContent || hasAboveEditorExtensionSurface
    }

    private var composerAuxiliaryRegionMaximumHeight: CGFloat {
        MacSessionWindowChrome.composerAuxiliaryRegionMaximumHeight(
            hasAboveEditorContent: hasAboveComposerAuxiliaryContent,
            hasBelowEditorContent: hasBelowEditorExtensionSurface
        )
    }

    @ViewBuilder
    private var editorAuxiliaryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsMessageQueueEditor {
                MacMessageQueueCard(
                    queue: store.messageQueue,
                    busyStreamingBehavior: Binding(
                        get: { store.busyStreamingBehavior },
                        set: { store.busyStreamingBehavior = $0 }
                    ),
                    isRefreshing: store.isRefreshingQueue,
                    isUpdating: store.isUpdatingQueue,
                    error: store.messageQueueError,
                    refresh: { await store.refreshQueueFromLocalConfig() },
                    apply: { request in try await store.applyQueueMutationFromLocalConfig(request) }
                )
            }

            if let ask = store.currentAskRequest {
                MacAskRequestCard(
                    request: ask,
                    submit: { draft in
                        await store.submitAskResponseFromLocalConfig(request: ask, draft: draft)
                    },
                    ignore: {
                        await store.ignoreAskRequestFromLocalConfig(ask)
                    }
                )
                .id(ask.id)
            }

            if let progress = store.attachmentPreparationText {
                Label(progress, systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(theme.text.secondary)
            }

            if let error = visibleEditorError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(theme.accent.red)
            }

            if !slashSuggestions.isEmpty {
                MacSlashCommandSuggestionList(
                    suggestions: slashSuggestions,
                    isLoading: store.isLoadingSlashCommands,
                    error: store.slashCommandsError,
                    insert: insertSlashCommand
                )
            } else if activeFileMentionQuery != nil {
                MacFileMentionSuggestionList(
                    suggestions: fileMentionSuggestions,
                    isLoading: store.isLoadingFileIndex,
                    error: store.fileIndexError,
                    insert: insertFileSuggestion
                )
            }

            if store.stagedReviewCommentCount > 0 {
                reviewCommentStashButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sessionStateBar: some View {
        HStack(spacing: 12) {
            switch composerSurface {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                stateText("Loading session…", detail: "Fetching the latest timeline and controls.")
            case .resume:
                Image(systemName: store.resumeError == nil
                    ? "checkmark.circle"
                    : "exclamationmark.triangle")
                    .foregroundStyle(store.resumeError == nil ? theme.text.secondary : theme.accent.red)
                stateText(
                    store.resumeError == nil ? "Session ended" : "Couldn’t resume",
                    detail: store.resumeError ?? "Resume to continue this conversation.",
                    detailIsError: store.resumeError != nil
                )
                Spacer(minLength: 12)
                Button {
                    Task { await store.resumeSessionFromLocalConfig() }
                } label: {
                    if store.isResumingSession {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Resuming…")
                        }
                    } else {
                        Label("Resume", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isResumingSession)
                .accessibilityIdentifier("mac.composer.resume")
                .accessibilityLabel(store.isResumingSession ? "Resuming…" : "Resume")
            case .stopping:
                ProgressView()
                    .controlSize(.small)
                stateText("Stopping session…", detail: "The timeline will remain available.")
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.accent.red)
                stateText(
                    "Session unavailable",
                    detail: store.lastError ?? "Reload the session to try again."
                )
                Spacer(minLength: 12)
                Button("Retry") {
                    Task { await store.loadSelectedFromLocalConfig() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("mac.composer.retry")
            case .editor:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .themedSurface(
            .elevatedPanel,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private func stateText(
        _ title: String,
        detail: String,
        detailIsError: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(theme.text.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(detailIsError ? theme.accent.red : theme.text.secondary)
                .lineLimit(2)
        }
    }

    private var composerCapsule: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !pendingAttachments.isEmpty {
                MacPendingAttachmentStrip(
                    attachments: pendingAttachments,
                    remove: { id in pendingAttachments.removeAll { $0.id == id } }
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            if isAttachmentDropTarget {
                Label("Drop files to attach", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(theme.text.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, pendingAttachments.isEmpty ? 8 : 2)
            }

            HStack(alignment: .bottom, spacing: 8) {
                dictationButton

                ZStack(alignment: .leading) {
                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(composerPlaceholder)
                            .foregroundStyle(placeholderStyle)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    MacComposerInputView(
                        text: $draft,
                        isEnabled: store.canSendMessage,
                        accessibilityLabel: composerPlaceholder,
                        textColor: NSColor(theme.text.primary),
                        onFocusChange: { focused in
                            if focused {
                                sessionFocus.wrappedValue = .composer
                            }
                        },
                        onPasteAttachments: stagePasteboardPayload
                    )
                    .frame(
                        minHeight: MacComposerInputMetrics.minimumHeight,
                        maxHeight: MacComposerInputMetrics.maximumHeight
                    )
                    .focused(sessionFocus, equals: .composer)
                    .accessibilityIdentifier("mac.composer.input")
                    .accessibilityLabel(composerPlaceholder)
                }

                primaryActionButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            composerActionRow
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurface(
            .elevatedPanel,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session composer")
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isAttachmentDropTarget,
            perform: handleAttachmentProviders
        )
    }

    private var actionRowItems: [MacSessionChromeItem] {
        MacSessionWindowChrome.composerActionRowItems(
            isBusy: isBusy,
            hasAskRequest: hasAskRequest
        )
    }

    private var composerActionRow: some View {
        ViewThatFits(in: .horizontal) {
            fullComposerActionRow
            compactComposerActionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fullComposerActionRow: some View {
        composerActionRow(compact: false)
    }

    private var compactComposerActionRow: some View {
        composerActionRow(compact: true)
    }

    private func composerActionRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            attachButton

            if actionRowItems.contains(.steering) {
                busyModeSelector(compact: compact)
            }

            Spacer(minLength: compact ? 4 : 8)

            if actionRowItems.contains(.model) {
                modelPickerButton(compact: compact)
            }
            if actionRowItems.contains(.thinking) {
                thinkingLevelMenu(compact: compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var autocompleteContext: ComposerAutocompleteContext {
        ComposerAutocomplete.context(for: draft, isBusy: isBusy)
    }

    private var slashSuggestions: [SlashCommand] {
        guard case .slash(let query) = autocompleteContext else {
            return []
        }
        return ComposerAutocomplete.slashSuggestions(
            query: query,
            commands: ComposerAutocomplete.availableCommands(from: store.slashCommands)
        )
    }

    private var activeFileMentionQuery: String? {
        guard case .atFile(let query) = ComposerAutocomplete.context(for: draft) else {
            return nil
        }
        return query
    }

    private var fileMentionSuggestions: [FileSuggestion] {
        guard let query = activeFileMentionQuery else { return [] }
        return FileSuggestion.ranked(query: query, paths: store.fileIndexPaths)
    }

    private var hasComposerContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingAttachments.isEmpty
            || store.hasStagedReviewComments
    }

    /// Content + connection, matching iOS ChatInputBar `canSend` for paint.
    private var canSend: Bool {
        store.canSendMessage && hasComposerContent
    }

    private var canSubmitComposer: Bool {
        canSend && !isSendInFlight
    }

    private var isBusy: Bool {
        store.session?.status.isRunning == true
    }

    private var hasAskRequest: Bool {
        store.currentAskRequest != nil
    }

    private var isSendInFlight: Bool {
        submissionGate.isActive || store.isSending || store.isPreparingAttachments
    }

    private var accentColor: Color { theme.accent.blue }

    private var sendFillToken: MacComposerActionPaint.SendFill {
        MacComposerActionPaint.sendFill(
            isSendInFlight: isSendInFlight,
            canSend: canSend,
            isBusy: isBusy
        )
    }

    private var sendActionFillColor: Color {
        switch sendFillToken {
        case .accent: accentColor
        case .purple: theme.accent.purple
        case .disabled: theme.bg.highlight
        }
    }

    private var sendActionStrokeColor: Color {
        switch sendFillToken {
        case .disabled: theme.text.tertiary.opacity(0.35)
        case .accent, .purple: sendActionFillColor.opacity(0.9)
        }
    }

    private var sendActionForegroundColor: Color {
        switch sendFillToken {
        case .disabled: theme.text.tertiary
        case .accent, .purple:
            ThemeColorContrast.contrastingForeground(
                on: sendActionFillColor,
                candidates: [theme.text.primary, theme.bg.primary]
            )
        }
    }

    private var stopActionFillColor: Color {
        switch MacComposerActionPaint.stopFill(isStoppingTurn: store.isStoppingTurn) {
        case .orange: theme.accent.orange
        case .red: theme.accent.red
        }
    }

    private var stopActionStrokeColor: Color {
        stopActionFillColor.opacity(0.9)
    }

    private var stopActionForegroundColor: Color {
        ThemeColorContrast.foreground(for: stopActionFillColor)
    }

    private var primaryAction: MacSessionComposerPrimaryAction {
        MacSessionWindowChrome.composerPrimaryAction(
            isBusy: isBusy,
            canSend: canSend,
            isSending: isSendInFlight,
            hasAskRequest: hasAskRequest
        )
    }

    private var composerPlaceholder: String {
        if store.session?.status == .stopped {
            return "Session stopped"
        }
        if store.stagedReviewCommentCount > 0 {
            return MacReviewCommentComposerPaint.sendPlaceholder(count: store.stagedReviewCommentCount)
        }
        guard isBusy, !hasAskRequest else { return "Message this session" }
        return store.busyStreamingBehavior == .steer ? "Steer agent…" : "Queue follow-up…"
    }

    private var reviewCommentStashButton: some View {
        Button {
            showReviewCommentStash = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                Text(MacReviewCommentComposerPaint.stashTitle(count: store.stagedReviewCommentCount))
                Spacer(minLength: 8)
                Text("Review")
                    .foregroundStyle(theme.text.secondary)
                Image(systemName: "chevron.up")
                    .foregroundStyle(theme.text.secondary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.bg.highlight, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mac.composer.reviewComments.stash")
        .accessibilityLabel(MacReviewCommentComposerPaint.stashTitle(count: store.stagedReviewCommentCount))
        .help("Staged review comments")
    }

    private var placeholderStyle: ThemeShapeStyle {
        MacComposerFieldPaint.shapeStyle(for: MacComposerFieldPaint.placeholderRole)
    }

    private var supportedThinkingLevels: [ThinkingLevel] {
        ThinkingLevelMenuSource.levels(
            for: store.session?.model,
            in: store.availableModels
        )
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch primaryAction {
        case .send:
            sendActionButton
        case .stop:
            stopActionButton
        }
    }

    private var sendActionButton: some View {
        Button {
            guard let submissionID = submissionGate.begin() else { return }
            let originatingSessionID = store.selectedTarget?.sessionId
            Task {
                defer { submissionGate.finish(submissionID) }
                composerLocalError = nil
                if dictation.isLive {
                    await dictation.stop()
                    guard MacSessionWindowChrome.shouldApplyComposerCompletion(
                        originatingSessionID: originatingSessionID,
                        currentSessionID: store.selectedTarget?.sessionId
                    ) else { return }
                    draft = dictation.composedDraft
                }
                guard MacSessionWindowChrome.shouldApplyComposerCompletion(
                    originatingSessionID: originatingSessionID,
                    currentSessionID: store.selectedTarget?.sessionId
                ) else { return }
                let message = draft
                let attachments = pendingAttachments
                let didSend = await store.sendPromptFromLocalConfig(message, attachments: attachments)
                if didSend, MacSessionWindowChrome.shouldApplyComposerCompletion(
                    originatingSessionID: originatingSessionID,
                    currentSessionID: store.selectedTarget?.sessionId
                ) {
                    // Upload and send can take long enough for the user to
                    // keep editing. Clear only the snapshot that was sent.
                    if draft == message {
                        draft = ""
                    }
                    let sentAttachmentIDs = Set(attachments.map(\.id))
                    pendingAttachments.removeAll { sentAttachmentIDs.contains($0.id) }
                }
            }
        } label: {
            ZStack {
                Circle().fill(sendActionFillColor)
                Circle().stroke(sendActionStrokeColor, lineWidth: 1)

                if isSendInFlight {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(sendActionForegroundColor)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(sendActionForegroundColor)
                }
            }
            .frame(width: actionVisualDiameter, height: actionVisualDiameter)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmitComposer)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityIdentifier("mac.composer.send")
        .accessibilityLabel(isSendInFlight ? "Sending" : "Send")
        .help("Send")
    }

    /// Same control as Send. Busy + empty morphs it to Stop, matching iOS.
    /// Sends `ClientMessage.stop` (abort turn). Session-process kill stays
    /// on the session list.
    private var stopActionButton: some View {
        Button {
            Task { await store.stopTurnFromLocalConfig() }
        } label: {
            ZStack {
                Circle().fill(stopActionFillColor)
                Circle().stroke(stopActionStrokeColor, lineWidth: 1)

                if store.isStoppingTurn {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(stopActionForegroundColor)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(stopActionForegroundColor)
                }
            }
            .frame(width: actionVisualDiameter, height: actionVisualDiameter)
        }
        .buttonStyle(.plain)
        .disabled(store.isStoppingTurn)
        .accessibilityIdentifier("mac.composer.stop")
        .accessibilityLabel(store.isStoppingTurn ? "Stopping" : "Stop")
        .help("Stop")
    }

    private var canControlDictation: Bool {
        store.canSendMessage || dictation.isLive
    }

    private func dictationIndicatorColor(
        for indicator: MacComposerDictationPaint.Indicator
    ) -> Color {
        switch indicator {
        case .comment: theme.text.tertiary
        case .cyan: theme.accent.cyan
        }
    }

    private var dictationButton: some View {
        let paint = MacComposerDictationPaint.presentation(for: dictation.state)
        let indicatorColor = dictationIndicatorColor(for: paint.indicator)

        return Button {
            Task { await toggleDictation() }
        } label: {
            ZStack {
                Circle().fill(.themeBgHighlight)
                Circle().stroke(
                    indicatorColor.opacity(paint.ringOpacity),
                    lineWidth: paint.ringLineWidth
                )

                switch paint.content {
                case .progress:
                    ProgressView()
                        .controlSize(.mini)
                        .tint(indicatorColor)
                case .cloud:
                    Image(systemName: "cloud")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(indicatorColor)
                case .microphone:
                    Image(systemName: "mic")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(indicatorColor.opacity(paint.glyphOpacity))
                }
            }
            .frame(width: actionVisualDiameter, height: actionVisualDiameter)
        }
        .buttonStyle(.plain)
        .disabled(isSendInFlight || !canControlDictation || dictation.state == .stopping)
        .accessibilityIdentifier("mac.composer.dictation")
        .accessibilityLabel(dictationActionLabel)
        .help(dictationActionLabel)
    }

    private var dictationActionLabel: String {
        switch dictation.state {
        case .idle, .error:
            "Start dictation"
        case .requestingPermission, .connecting:
            "Cancel dictation setup"
        case .recording:
            "Stop dictation"
        case .stopping:
            "Finishing dictation"
        }
    }

    private func toggleDictation() async {
        let originatingSessionID = store.selectedTarget?.sessionId
        composerLocalError = nil
        switch dictation.state {
        case .recording:
            await dictation.stop()
            guard MacSessionWindowChrome.shouldApplyComposerCompletion(
                originatingSessionID: originatingSessionID,
                currentSessionID: store.selectedTarget?.sessionId
            ) else { return }
            draft = dictation.composedDraft
        case .requestingPermission, .connecting:
            await dictation.cancel()
            guard MacSessionWindowChrome.shouldApplyComposerCompletion(
                originatingSessionID: originatingSessionID,
                currentSessionID: store.selectedTarget?.sessionId
            ) else { return }
            draft = dictation.composedDraft
        case .stopping:
            return
        case .idle, .error:
            guard let endpoint = MacDictationEndpoint.localOwner() else {
                composerLocalError = DictationComposerPolicy.unavailableMessage
                return
            }
            do {
                try await dictation.start(baseText: draft, endpoint: endpoint)
            } catch {
                guard MacSessionWindowChrome.shouldApplyComposerCompletion(
                    originatingSessionID: originatingSessionID,
                    currentSessionID: store.selectedTarget?.sessionId
                ) else { return }
                composerLocalError = error.localizedDescription
            }
        }
    }

    private var attachButton: some View {
        Button {
            chooseAttachments()
        } label: {
            MacComposerChromePill(systemImage: "plus", text: nil)
        }
        .buttonStyle(.plain)
        .disabled(!store.canSendMessage || isSendInFlight)
        .accessibilityIdentifier("mac.composer.attach")
        .accessibilityLabel("Add attachment")
        .help("Attach files")
    }

    private func busyModeSelector(compact: Bool) -> some View {
        Menu {
            Picker("Busy send mode", selection: Binding(
                get: { store.busyStreamingBehavior },
                set: { store.busyStreamingBehavior = $0 }
            )) {
                Text("Steering").tag(StreamingBehavior.steer)
                Text("Follow-up").tag(StreamingBehavior.followUp)
            }
        } label: {
            MacComposerChromePill(
                systemImage: compact
                    ? (store.busyStreamingBehavior == .steer
                        ? "bolt.fill"
                        : "clock.arrow.circlepath")
                    : nil,
                text: compact
                    ? nil
                    : (store.busyStreamingBehavior == .steer ? "Steering" : "Follow-up")
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("mac.composer.busyMode")
        .accessibilityLabel("Busy send mode")
        .accessibilityValue(store.busyStreamingBehavior == .steer ? "Steering" : "Follow-up")
        .help("Send while busy")
    }

    private func modelPickerButton(compact: Bool) -> some View {
        Button {
            isModelPickerPresented = true
        } label: {
            if store.isUpdatingModel {
                MacComposerChromePill(text: compact ? nil : "Updating…") {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                MacComposerChromePill(
                    systemImage: compact ? "cpu" : nil,
                    text: compact
                        ? nil
                        : (MacModelSelection.shortDisplayName(for: store.session?.model) ?? "Model"),
                    showChevron: !compact,
                    chevronSystemImage: MacComposerActionPaint.modelChevronSystemImage
                ) {
                    if !compact, let provider = MacComposerActionPaint.modelPillProviderKey(
                        for: store.session?.model
                    ) {
                        ProviderGlyph(provider: provider, size: 11, color: theme.text.primary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!store.canSendMessage || store.isUpdatingModel)
        .accessibilityIdentifier("mac.composer.model")
        .accessibilityLabel("Model")
        .accessibilityValue(
            MacModelSelection.shortDisplayName(for: store.session?.model) ?? "Model"
        )
        .help("Choose model")
    }

    private func thinkingLevelMenu(compact: Bool) -> some View {
        Menu {
            Picker("Thinking", selection: Binding(
                get: { store.thinkingLevel },
                set: { level in
                    Task { await store.setThinkingLevelFromLocalConfig(level) }
                }
            )) {
                ForEach(supportedThinkingLevels) { level in
                    Text(level.displayTitle).tag(level)
                }
            }
            if store.session?.supportsPersistingDefaults != false {
                Divider()
                Button("Save as Default") {
                    Task { await store.setThinkingLevelFromLocalConfig(store.thinkingLevel, persist: true) }
                }
            }
        } label: {
            if store.isUpdatingThinkingLevel {
                MacComposerChromePill(text: compact ? nil : "Updating…") {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                MacComposerChromePill(
                    systemImage: "sparkle",
                    text: compact ? nil : store.thinkingLevel.compactTitle,
                    tint: theme.thinking.color(for: store.thinkingLevel)
                )
            }
        }
        .menuStyle(.borderlessButton)
        .disabled(!store.canSendMessage || store.isUpdatingThinkingLevel)
        .accessibilityIdentifier("mac.composer.thinking")
        .accessibilityLabel("Thinking level")
        .accessibilityValue(store.thinkingLevel.displayTitle)
        .help("Thinking level")
    }

    private func insertSlashCommand(_ command: SlashCommand) {
        draft = ComposerAutocomplete.insertSlashCommand(command, into: draft)
        composerLocalError = nil
    }

    private func insertFileSuggestion(_ suggestion: FileSuggestion) {
        draft = ComposerAutocomplete.insertFileMention(
            path: suggestion.path,
            isDirectory: suggestion.isDirectory,
            into: draft
        )
        composerLocalError = nil
    }

    private func loadFileIndexIfNeeded() {
        guard activeFileMentionQuery != nil,
              store.fileIndexPaths.isEmpty,
              !store.isLoadingFileIndex else { return }
        Task { await store.loadFileIndexFromLocalConfig() }
    }

    private func loadSlashCommandsIfNeeded() {
        guard case .slash = autocompleteContext else { return }
        Task { await store.loadSlashCommandsFromLocalConfig() }
    }

    private func chooseAttachments() {
        let originatingSessionID = store.selectedTarget?.sessionId
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK,
                  MacSessionWindowChrome.shouldApplyAttachmentCompletion(
                    originatingSessionID: originatingSessionID,
                    currentSessionID: store.selectedTarget?.sessionId,
                    surface: composerSurface
                  ) else { return }
            addAttachmentURLs(panel.urls)
        }
    }

    private func handleAttachmentProviders(_ providers: [NSItemProvider]) -> Bool {
        guard composerSurface.acceptsInput else { return false }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let originatingSessionID = store.selectedTarget?.sessionId

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    DispatchQueue.main.async {
                        guard MacSessionWindowChrome.shouldApplyAttachmentCompletion(
                            originatingSessionID: originatingSessionID,
                            currentSessionID: store.selectedTarget?.sessionId,
                            surface: composerSurface
                        ) else { return }
                        composerLocalError = error.localizedDescription
                    }
                    return
                }
                guard let url = Self.fileURL(from: item) else { return }
                DispatchQueue.main.async {
                    guard MacSessionWindowChrome.shouldApplyAttachmentCompletion(
                        originatingSessionID: originatingSessionID,
                        currentSessionID: store.selectedTarget?.sessionId,
                        surface: composerSurface
                    ) else { return }
                    addAttachmentURLs([url])
                }
            }
        }
        return true
    }

    private func addAttachmentURLs(_ urls: [URL]) {
        stagePasteboardPayload(MacComposerPasteboardPayload(fileURLs: urls, images: []))
    }

    private func stagePasteboardPayload(_ payload: MacComposerPasteboardPayload) {
        let result = MacComposerPasteboardParser.adding(payload, to: pendingAttachments)
        pendingAttachments = result.attachments
        composerLocalError = result.rejectedMessages.isEmpty
            ? nil
            : result.rejectedMessages.joined(separator: "\n")
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }
        return nil
    }
}

/// Idle composer field paint. Placeholder matches iOS theme-comment text;
/// typed text uses primary.
enum MacComposerFieldPaint {
    enum Role: String, Equatable {
        case primary
        case secondary
        case tertiary
    }

    static var placeholderRole: Role { .tertiary }
    static var valueRole: Role { .primary }

    static func shapeStyle(for role: Role) -> ThemeShapeStyle {
        switch role {
        case .primary: .themeFg
        case .secondary: .themeFgDim
        case .tertiary: .themeComment
        }
    }
}

/// Small semantic state map for the Mac remote-dictation button. The fill is
/// always the neutral themed highlight; only its ring and content communicate
/// state, matching the iOS mic button without importing its UIKit owner.
enum MacComposerDictationPaint {
    enum Indicator: Equatable {
        case comment
        case cyan
    }

    enum Content: Equatable {
        case microphone
        case cloud
        case progress
    }

    struct Presentation: Equatable {
        let indicator: Indicator
        let content: Content
        let ringOpacity: Double
        let ringLineWidth: CGFloat
        let glyphOpacity: Double
    }

    static func presentation(
        for state: MacComposerDictationController.State
    ) -> Presentation {
        switch state {
        case .idle, .error:
            Presentation(
                indicator: .comment,
                content: .microphone,
                ringOpacity: 0.35,
                ringLineWidth: 1,
                glyphOpacity: 0.75
            )
        case .requestingPermission, .connecting, .stopping:
            Presentation(
                indicator: .comment,
                content: .progress,
                ringOpacity: 0.6,
                ringLineWidth: 1,
                glyphOpacity: 1
            )
        case .recording:
            Presentation(
                indicator: .cyan,
                content: .cloud,
                ringOpacity: 1,
                ringLineWidth: 1.5,
                glyphOpacity: 1
            )
        }
    }
}

/// Token mapping for composer send/stop/model paint. Mirrors iOS ChatInputBar
/// colors without rendering SwiftUI in tests.
enum MacComposerActionPaint {
    enum SendFill: String, Equatable {
        case accent
        case purple
        case disabled
    }

    enum StopFill: String, Equatable {
        case red
        case orange
    }

    static let modelChevronSystemImage = "chevron.down"

    static func sendFill(
        isSendInFlight: Bool,
        canSend: Bool,
        isBusy: Bool
    ) -> SendFill {
        if isSendInFlight || canSend {
            return isBusy ? .purple : .accent
        }
        return .disabled
    }

    static func stopFill(isStoppingTurn: Bool) -> StopFill {
        isStoppingTurn ? .orange : .red
    }

    static func modelPillProviderKey(for modelID: String?) -> String? {
        modelProviderKey(modelID)
    }
}

private struct MacComposerChromePill<Leading: View>: View {
    var systemImage: String?
    var text: String?
    var tint: Color?
    var showChevron = false
    var chevronSystemImage = "chevron.up.chevron.down"
    let leading: Leading
    @Environment(\.theme) private var theme

    init(
        systemImage: String? = nil,
        text: String? = nil,
        tint: Color? = nil,
        showChevron: Bool = false,
        chevronSystemImage: String = "chevron.up.chevron.down",
        @ViewBuilder leading: () -> Leading
    ) {
        self.systemImage = systemImage
        self.text = text
        self.tint = tint
        self.showChevron = showChevron
        self.chevronSystemImage = chevronSystemImage
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: 4) {
            if Leading.self != EmptyView.self {
                leading
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            if let text {
                Text(text)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            if showChevron {
                Image(systemName: chevronSystemImage)
                    .font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(tint ?? theme.text.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.bg.highlight.opacity(0.72), in: Capsule())
        .contentShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension MacComposerChromePill where Leading == EmptyView {
    init(
        systemImage: String? = nil,
        text: String? = nil,
        tint: Color? = nil,
        showChevron: Bool = false,
        chevronSystemImage: String = "chevron.up.chevron.down"
    ) {
        self.init(
            systemImage: systemImage,
            text: text,
            tint: tint,
            showChevron: showChevron,
            chevronSystemImage: chevronSystemImage
        ) {
            EmptyView()
        }
    }
}

private struct MacSlashCommandSuggestionList: View {
    let suggestions: [SlashCommand]
    let isLoading: Bool
    let error: String?
    let insert: (SlashCommand) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Slash commands", systemImage: "list.bullet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.text.primary)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }

            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(theme.accent.red)
            }

            ForEach(suggestions) { command in
                Button {
                    insert(command)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: command.source.iconName)
                            .foregroundStyle(sourceColor(for: command.source))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(command.invocation)
                                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                                    .foregroundStyle(theme.accent.blue)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(command.source.label)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(theme.text.secondary)
                            }
                            if let description = command.description {
                                Text(description)
                                    .font(.caption2)
                                    .foregroundStyle(theme.text.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mac.composer.slash.suggestion.\(command.name)")
                .accessibilityLabel(command.invocation)
            }
        }
        .padding(10)
        .background(theme.bg.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.text.tertiary.opacity(0.2), lineWidth: 1)
        )
        .accessibilityIdentifier("mac.composer.slash.list")
    }

    private func sourceColor(for source: SlashCommand.Source) -> Color {
        switch source {
        case .builtin: theme.accent.blue
        case .extension: theme.accent.purple
        case .prompt: theme.accent.green
        case .skill: theme.accent.yellow
        }
    }
}

private struct MacFileMentionSuggestionList: View {
    let suggestions: [FileSuggestion]
    let isLoading: Bool
    let error: String?
    let insert: (FileSuggestion) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("File mentions", systemImage: "at")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.text.primary)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }

            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(theme.accent.red)
            } else if suggestions.isEmpty, !isLoading {
                Text("No matching workspace files")
                    .font(.caption)
                    .foregroundStyle(theme.text.secondary)
            } else {
                ForEach(suggestions) { suggestion in
                    Button {
                        insert(suggestion)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(theme.text.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.displayName)
                                    .foregroundStyle(theme.text.primary)
                                    .lineLimit(1)
                                if let parent = suggestion.parentPath {
                                    Text(parent)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(theme.text.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(theme.bg.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.text.tertiary.opacity(0.2), lineWidth: 1)
        )
    }
}

private struct MacPendingAttachmentStrip: View {
    let attachments: [MacPendingAttachment]
    let remove: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        MacPendingAttachmentPreviewView(attachment: attachment)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.displayName)
                                .foregroundStyle(theme.text.primary)
                                .lineLimit(1)
                            Text(Self.formattedSize(attachment.sizeBytes))
                                .font(.caption2)
                                .foregroundStyle(theme.text.secondary)
                        }
                        Button {
                            remove(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(minWidth: 28, minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove attachment: \(attachment.displayName)")
                        .help("Remove attachment")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(theme.bg.highlight, in: Capsule())
                }
            }
        }
    }

    private static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct MacPendingAttachmentPreviewView: View {
    let attachment: MacPendingAttachment
    @Environment(\.theme) private var theme

    var body: some View {
        let preview = MacPendingAttachmentPreview.forAttachment(attachment)
        if preview == .image, let thumbnail = MacPendingAttachmentThumbnail.image(for: attachment) {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: preview.systemImageFallback)
                .foregroundStyle(theme.text.secondary)
        }
    }
}

private struct MacComposerAuxiliaryFieldSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                .themeRecessedInset,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }
}

private extension View {
    func macComposerAuxiliaryFieldSurface() -> some View {
        modifier(MacComposerAuxiliaryFieldSurface())
    }
}

private struct MacMessageQueueCard: View {
    let queue: MessageQueueState
    @Binding var busyStreamingBehavior: StreamingBehavior
    let isRefreshing: Bool
    let isUpdating: Bool
    let error: String?
    let refresh: () async -> Void
    let apply: (MacMessageQueueMutationRequest) async throws -> Void

    @Environment(\.theme) private var theme
    @State private var isExpanded = false
    @State private var editorState: MacMessageQueueEditorState
    @State private var localError: String?

    init(
        queue: MessageQueueState,
        busyStreamingBehavior: Binding<StreamingBehavior>,
        isRefreshing: Bool,
        isUpdating: Bool,
        error: String?,
        refresh: @escaping () async -> Void,
        apply: @escaping (MacMessageQueueMutationRequest) async throws -> Void
    ) {
        self.queue = queue
        _busyStreamingBehavior = busyStreamingBehavior
        self.isRefreshing = isRefreshing
        self.isUpdating = isUpdating
        self.error = error
        self.refresh = refresh
        self.apply = apply
        _editorState = State(initialValue: MacMessageQueueEditorState(queue: queue))
    }

    private var controlsDisabled: Bool { isRefreshing || isUpdating }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Label("Message Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.headline)
                    Text("\(editorState.displayedQueue.steering.count) steering · \(editorState.displayedQueue.followUp.count) follow-up")
                        .font(.caption)
                        .foregroundStyle(theme.text.secondary)
                    Spacer()
                    if controlsDisabled {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(theme.text.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Picker("Send while busy", selection: $busyStreamingBehavior) {
                    Text("Steer").tag(StreamingBehavior.steer)
                    Text("Follow-up").tag(StreamingBehavior.followUp)
                }
                .pickerStyle(.segmented)
                .disabled(controlsDisabled)

                if let visibleError = localError ?? error, !visibleError.isEmpty {
                    Text(visibleError)
                        .font(.caption)
                        .foregroundStyle(theme.accent.red)
                }

                if editorState.isEmpty {
                    Text("Queue is empty. Messages sent while the session is busy will appear here.")
                        .font(.caption)
                        .foregroundStyle(theme.text.secondary)
                } else {
                    queueSection(title: "Steering", kind: .steer, items: editorState.displayedQueue.steering)
                    queueSection(title: "Follow-up", kind: .followUp, items: editorState.displayedQueue.followUp)
                }

                footer
            }
        }
        .padding(12)
        .background(theme.bg.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.text.tertiary.opacity(0.25), lineWidth: 1)
        )
        .onChange(of: queue) { _, latest in
            editorState.receiveServerQueue(latest)
        }
    }

    private func queueSection(title: String, kind: MessageQueueKind, items: [MessageQueueItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.text.secondary)
            ForEach(items, id: \.id) { item in
                queueRow(kind: kind, id: item.id)
            }
        }
    }

    private func queueRow(kind: MessageQueueKind, id: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 6) {
                queueMessageField(kind: kind, id: id)
                    .frame(minWidth: 220)
                queueRowControls(kind: kind, id: id)
            }

            VStack(alignment: .leading, spacing: 6) {
                queueMessageField(kind: kind, id: id)
                queueRowControls(kind: kind, id: id)
            }
        }
        .font(.caption)
    }

    private func queueMessageField(kind: MessageQueueKind, id: String) -> some View {
        TextField("Queued message", text: messageBinding(kind: kind, id: id), axis: .vertical)
            .macComposerAuxiliaryFieldSurface()
            .lineLimit(1...4)
            .disabled(controlsDisabled)
    }

    private func queueRowControls(kind: MessageQueueKind, id: String) -> some View {
        HStack(spacing: 2) {
            Button {
                applyImmediate(editorState.moveItem(kind: kind, id: id, direction: -1))
            } label: {
                Image(systemName: "arrow.up")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(controlsDisabled || !editorState.canMove(kind: kind, id: id, direction: -1))
            .accessibilityLabel("Move queued message earlier")
            .help("Move queued message earlier")

            Button {
                applyImmediate(editorState.moveItem(kind: kind, id: id, direction: 1))
            } label: {
                Image(systemName: "arrow.down")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(controlsDisabled || !editorState.canMove(kind: kind, id: id, direction: 1))
            .accessibilityLabel("Move queued message later")
            .help("Move queued message later")

            Button {
                applyImmediate(editorState.moveBetweenQueues(kind: kind, id: id))
            } label: {
                Image(systemName: kind == .steer ? "arrow.down.right" : "arrow.up.left")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(controlsDisabled)
            .accessibilityLabel(
                "Move queued message to \(kind == .steer ? "Follow-up" : "Steering")"
            )
            .help(kind == .steer ? "Move to Follow-up" : "Move to Steering")

            Button(role: .destructive) {
                applyImmediate(editorState.deleteItem(kind: kind, id: id))
            } label: {
                Image(systemName: "trash")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(controlsDisabled)
            .accessibilityLabel("Delete queued message")
            .help("Delete queued message")
        }
        .buttonStyle(.borderless)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Refresh") {
                Task { await refresh() }
            }
            .disabled(controlsDisabled)

            Spacer()

            if editorState.isDraftMode {
                Button("Discard") {
                    editorState.discardDraft()
                    localError = nil
                }
                .disabled(controlsDisabled)

                Button("Save") {
                    saveDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controlsDisabled)
            }
        }
        .font(.caption)
    }

    private func messageBinding(kind: MessageQueueKind, id: String) -> Binding<String> {
        Binding(
            get: { editorState.item(kind: kind, id: id)?.message ?? "" },
            set: { value in
                if editorState.updateMessage(kind: kind, id: id, message: value) {
                    localError = nil
                }
            }
        )
    }

    private func applyImmediate(_ request: MacMessageQueueMutationRequest?) {
        guard let request else { return }
        Task { await applyRequest(request, rollsBackOnFailure: true) }
    }

    private func saveDraft() {
        guard let request = editorState.draftRequest() else { return }
        Task { await applyRequest(request, rollsBackOnFailure: false) }
    }

    private func applyRequest(
        _ request: MacMessageQueueMutationRequest,
        rollsBackOnFailure: Bool
    ) async {
        localError = nil
        do {
            try await apply(request)
            if !rollsBackOnFailure {
                editorState.acceptDraft(request)
            }
        } catch {
            if rollsBackOnFailure {
                editorState.rollbackRejectedImmediateMutation()
            }
            localError = error.localizedDescription
        }
    }
}

private struct MacAskRequestCard: View {
    let request: AskRequest
    let submit: (MacAskResponseDraft) async -> Void
    let ignore: () async -> Void

    @Environment(\.theme) private var theme
    @State private var draft = MacAskResponseDraft()
    @State private var customAnswers: [String: String] = [:]
    @State private var isSending = false

    private var isSingleQuestionSingleSelect: Bool {
        request.questions.count == 1 && !(request.questions.first?.multiSelect ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Agent question", systemImage: "questionmark.bubble")
                    .font(.headline)
                    .foregroundStyle(theme.text.primary)
                Spacer()
                if request.questions.count > 1 {
                    Text("\(request.questions.count) questions")
                        .font(.caption)
                        .foregroundStyle(theme.text.secondary)
                }
            }

            ForEach(request.questions) { question in
                questionView(question)
            }

            HStack {
                Button("Ignore") {
                    Task { await sendIgnore() }
                }
                .disabled(isSending)

                Spacer()

                Button {
                    Task { await sendSubmit() }
                } label: {
                    if isSending {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Sending answer…")
                        }
                    } else {
                        Text("Send answer")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || draft.isEmpty)
                .accessibilityLabel(isSending ? "Sending answer…" : "Send answer")
            }
        }
        .padding(12)
        .background(theme.bg.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.text.tertiary.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent question")
    }

    private func questionView(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.text.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if question.multiSelect {
                Label("Select multiple", systemImage: "checkmark.square")
                    .font(.caption)
                    .foregroundStyle(theme.text.secondary)
            }

            ForEach(question.options, id: \.value) { option in
                optionButton(option, question: question)
            }

            if request.allowCustom {
                customAnswerField(question)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionButton(_ option: AskOption, question: AskQuestion) -> some View {
        let isSelected = draft.isSelected(option, question: question)
        return Button {
            draft.toggle(option, question: question)
            if isSingleQuestionSingleSelect {
                Task { await sendSubmit() }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: question.multiSelect
                    ? (isSelected ? "checkmark.square.fill" : "square")
                    : (isSelected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(isSelected ? theme.accent.blue : theme.text.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.text.primary)
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(theme.text.secondary)
                    }
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? theme.accent.blue.opacity(0.13) : theme.bg.highlight,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func customAnswerField(_ question: AskQuestion) -> some View {
        TextField(
            request.customPlaceholder ?? "Custom answer",
            text: Binding(
                get: { customAnswers[question.id] ?? "" },
                set: { value in
                    customAnswers[question.id] = value
                    draft.setCustom(value, question: question)
                }
            ),
            axis: .vertical
        )
        .macComposerAuxiliaryFieldSurface()
        .lineLimit(1...4)
    }

    private func sendSubmit() async {
        guard !isSending, !draft.isEmpty else { return }
        isSending = true
        await submit(draft)
        isSending = false
    }

    private func sendIgnore() async {
        guard !isSending else { return }
        isSending = true
        await ignore()
        isSending = false
    }
}
