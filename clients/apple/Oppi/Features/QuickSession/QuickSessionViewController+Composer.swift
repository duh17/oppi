import UIKit

/// Quick Session feeds the chat's composer owner the way the chat does: its
/// draft and launch state, the Agent, model, and thinking pills (in the action
/// row unless the accessibility-size panel holds them), and the expanded
/// composer. It has no turn to stop and no Ask to answer.
extension QuickSessionViewController: ChatComposerSource {
    var composerContent: ComposerBarContent {
        let colors = colors
        return ComposerBarContent(
            text: model.text,
            textBeforeRecording: model.textBeforeRecording,
            pendingAttachments: model.pendingAttachments,
            pendingRepoPointers: model.pendingRepoPointers,
            isBusy: false,
            busyStreamingBehavior: model.busyStreamingBehavior,
            isSending: model.isCreating,
            pendingReviewCommentCount: 0,
            placeholderOverride: nil,
            allowsEmptySubmit: model.allowsEmptySubmit,
            sendProgressText: nil,
            isStopping: false,
            voiceInputManager: model.voiceInputManager,
            onLiveVoiceSelected: model.liveVoiceEntry,
            showForceStop: false,
            isForceStopInFlight: false,
            askRequest: nil,
            slashCommands: model.slashCommands,
            fileSuggestions: model.selectedChatState.fileSuggestions,
            appliesOuterPadding: true,
            alwaysShowActionRow: true,
            allowsExpansion: true,
            allowsAttachments: true,
            attachmentButtonPlacement: .leading,
            actionRowMinimumHeight: 0,
            showsAccessoryRow: true,
            autocorrectionEnabled: true,
            inputAccessibilityIdentifier: "chat.input",
            sendAccessibilityIdentifier: "chat.send",
            actionRow: stacksActionControls ? ComposerActionRow() : composerActionRow(colors: colors),
            colors: colors,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            // The owner replaces these with its own.
            suppressKeyboard: false,
            focusRequestID: 0,
            keyboardLanguage: nil,
            keyStripHeight: 0,
            mediaImportEpoch: 0
        )
    }

    private func composerActionRow(colors: ComposerThemeColors) -> ComposerActionRow {
        let presentation = model.modelPresentation
        composerIcons.prepare(agents: model.availableAgents, themeID: root.themeStore.activeThemeID)
        let toolbar = ComposerActionRow.sessionToolbar(
            modelTitle: shortModelName(model.effectiveModelId ?? presentation.pillText),
            modelProvider: presentation.pillProvider,
            thinkingLevel: model.effectiveThinkingLevel,
            thinkingTint: thinkingTint,
            supportedThinkingLevels: model.supportedThinkingLevels,
            colors: colors,
            onModelTap: { [weak self] in self?.model.showModelPicker = true },
            onThinkingSelect: { [weak self] in self?.model.selectThinkingLevel($0) },
            onSaveThinkingAsDefault: nil
        )
        let agent = model.selectedAgent
        let agentAction = ComposerAction.agent(
            title: agent?.name ?? "Pi",
            icon: agent.map { composerIcons.icon(for: $0, size: 12) } ?? composerIcons.piAvatar(size: 16),
            colors: colors,
            rows: agentPickerRows,
            isLoading: model.isLoadingAgents,
            onSelect: { [weak self] in self?.model.selectAgent($0) }
        )
        return ComposerActionRow(leading: [agentAction], trailing: toolbar.trailing)
    }

    /// The action row's Agent list: Pi, then the server's saved Agents.
    private var agentPickerRows: [ComposerOptionRow] {
        var rows: [ComposerOptionRow] = [
            ComposerOptionRow(
                id: Self.piRowID,
                title: "Pi",
                subtitle: nil,
                icon: composerIcons.piAvatar(size: 22),
                isSelected: model.selectedAgentId == nil,
                accessibilityIdentifier: "quickSession.agent.pi",
                accessibilityLabel: "Pi"
            ),
        ]
        for agent in model.availableAgents {
            rows.append(
                ComposerOptionRow(
                    id: agent.id,
                    title: agent.name,
                    subtitle: agent.description,
                    icon: composerIcons.icon(for: agent, size: 16),
                    isSelected: model.selectedAgentId == agent.id,
                    accessibilityIdentifier: "quickSession.agent.\(agent.id)",
                    accessibilityLabel: agent.name
                )
            )
        }
        return rows
    }

    var composerDraftStore: ComposerDraftStore? { model.composerDraftStore }
    var composerMediaImportGate: ComposerMediaImportGate? { nil }

    // Every draft edit, dictation's transcript included, arrives here and saves.
    func composerSetText(_ text: String) { model.editText(text) }
    func composerSetTextBeforeRecording(_ value: String?) { model.textBeforeRecording = value }
    func composerSetPendingAttachments(_ value: [PendingAttachment]) { model.editAttachments(value) }
    func composerSetPendingRepoPointers(_ value: [PendingFileReference]) { model.editRepoPointers(value) }
    func composerSetBusyStreamingBehavior(_ value: StreamingBehavior) { model.busyStreamingBehavior = value }

    func composerSend() { model.handleSend() }
    func composerStop() {}
    func composerForceStop() {}
    func composerExpand() { model.showExpandedComposer = true }
    func composerSubmitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) {
        completion(.completed)
    }
    func composerIgnoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion) {
        completion(.completed)
    }
    func composerFileSuggestionQuery(_ query: String?) { model.updateFileSuggestions(query) }
    func composerPrepareVoiceInput(_ manager: VoiceInputManager) async throws {
        model.configureVoiceInputForSelectedServer(manager)
    }

    var isComposerExpanded: Bool { model.showExpandedComposer }
    func composerExpandedDidClose() { model.showExpandedComposer = false }

    func makeExpandedComposer() -> ExpandedComposerViewController {
        let model = model
        let configuration = ExpandedComposerConfiguration(
            voiceInputManager: model.voiceInputManager,
            onPrepareVoiceInput: { [weak model] in model?.configureVoiceInputForSelectedServer($0) },
            onLiveVoiceSelected: model.liveVoiceEntry,
            onSend: { [weak model] in model?.handleSend() },
            onModelTap: { [weak model] in model?.showModelPicker = true },
            onThinkingSelect: { [weak model] in model?.selectThinkingLevel($0) },
            onFileSuggestionQuery: { [weak model] in model?.updateFileSuggestions($0) },
            onTextChange: { [weak model] in model?.editText($0) },
            onTextBeforeRecordingChange: { [weak model] in model?.textBeforeRecording = $0 },
            onAttachmentsChange: { [weak model] in model?.editAttachments($0) },
            onRepoPointersChange: { [weak model] in model?.editRepoPointers($0) },
            composerDraftStore: model.composerDraftStore
        )
        return ExpandedComposerViewController(configuration: configuration, live: expandedComposerLiveState)
    }

    /// Quick Session's draft, model, and thinking level for the open expanded composer.
    var expandedComposerLiveState: ExpandedComposerLiveState {
        let colors = colors
        let presentation = model.modelPresentation
        return ExpandedComposerLiveState(
            text: model.text,
            textBeforeRecording: model.textBeforeRecording,
            pendingAttachments: model.pendingAttachments,
            pendingRepoPointers: model.pendingRepoPointers,
            isBusy: false,
            busyStreamingBehavior: .followUp,
            slashCommands: model.slashCommands,
            fileSuggestions: model.selectedChatState.fileSuggestions,
            modelOverride: model.effectiveModelId ?? presentation.pillText,
            providerOverride: presentation.pillProvider,
            thinkingLevel: model.effectiveThinkingLevel,
            supportedThinkingLevels: model.supportedThinkingLevels,
            allowsEmptySubmit: model.allowsEmptySubmit,
            colors: colors,
            thinkingTint: thinkingTint
        )
    }
}

/// Rendered Agent and Pi icons for Quick Session's composer, keyed by Agent,
/// icon, and size. The composer rebuilds its action row and Agent list on every
/// update, and each Genmoji or emoji icon is a raster: reuse the pixels until
/// the server's Agent list or the theme changes.
@MainActor
final class QuickSessionComposerIconCache {
    private struct AgentIconKey: Hashable {
        let agentID: String
        let icon: IconChoice
        let size: CGFloat
    }

    private var agents: [AgentDefinitionSummary] = []
    private var themeID: ThemeID?
    private var agentIcons: [AgentIconKey: UIImage] = [:]
    private var piAvatars: [CGFloat: UIImage] = [:]

    /// Drops rasters the new Agent list or theme invalidates. `AgentIconRenderer`
    /// tints with the palette blue and `PiAvatarRenderer` with the palette
    /// foreground, so a theme change repaints both.
    func prepare(agents: [AgentDefinitionSummary], themeID: ThemeID) {
        if agents != self.agents {
            self.agents = agents
            agentIcons.removeAll()
        }
        if themeID != self.themeID {
            self.themeID = themeID
            agentIcons.removeAll()
            piAvatars.removeAll()
        }
    }

    func icon(for agent: AgentDefinitionSummary, size: CGFloat) -> UIImage {
        let key = AgentIconKey(agentID: agent.id, icon: agent.icon, size: size)
        if let cached = agentIcons[key] { return cached }
        let image = AgentIconRenderer.render(value: agent.icon, size: size)
        agentIcons[key] = image
        return image
    }

    /// The one Pi mark, at each size it is shown.
    func piAvatar(size: CGFloat) -> UIImage {
        if let cached = piAvatars[size] { return cached }
        let image = PiAvatarRenderer.render(size: size)
        piAvatars[size] = image
        return image
    }
}
