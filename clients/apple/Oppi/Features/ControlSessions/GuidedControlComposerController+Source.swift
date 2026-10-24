import UIKit

/// The guided composer feeds the chat's composer owner the way the chat does:
/// its draft, launch state, and the workspace (Agents and Schedules only),
/// model, and thinking pills (in the action row unless the accessibility-size
/// panel holds them). It has no
/// turn to stop, no Ask to answer, no attachments, and no expanded composer.
extension GuidedControlComposerController: ChatComposerSource {
    var composerContent: ComposerBarContent {
        let colors = colors
        let stacks = stacksActionControls
        return ComposerBarContent(
            text: model.request,
            textBeforeRecording: model.textBeforeRecording,
            pendingAttachments: [],
            pendingRepoPointers: [],
            isBusy: false,
            busyStreamingBehavior: model.streamingBehavior,
            isSending: model.isCreating,
            pendingReviewCommentCount: model.reviewCommentPresentation.pendingCount,
            placeholderOverride: model.placeholder,
            allowsEmptySubmit: model.configuration.allowsEmptyRequest,
            sendProgressText: nil,
            isStopping: false,
            voiceInputManager: model.voiceInputManager,
            onLiveVoiceSelected: nil,
            showForceStop: false,
            isForceStopInFlight: false,
            askRequest: nil,
            slashCommands: [],
            fileSuggestions: [],
            appliesOuterPadding: true,
            alwaysShowActionRow: !stacks,
            allowsExpansion: false,
            allowsAttachments: false,
            attachmentButtonPlacement: .leading,
            actionRowMinimumHeight: 0,
            showsAccessoryRow: !stacks,
            autocorrectionEnabled: true,
            inputAccessibilityIdentifier: "chat.input",
            sendAccessibilityIdentifier: "chat.send",
            actionRow: stacks ? ComposerActionRow() : composerActionRow(colors: colors),
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
        let toolbar = ComposerActionRow.sessionToolbar(
            modelTitle: shortModelName(model.effectiveModelId ?? presentation.pillText),
            modelProvider: presentation.pillProvider,
            thinkingLevel: model.thinkingLevel,
            thinkingTint: thinkingTint,
            supportedThinkingLevels: model.supportedThinkingLevels,
            colors: colors,
            onModelTap: { [weak self] in self?.model.showModelPicker = true },
            onThinkingSelect: { [weak self] in self?.model.selectThinkingLevel($0) },
            onSaveThinkingAsDefault: nil
        )
        guard model.showsWorkspacePicker else {
            return ComposerActionRow(trailing: toolbar.trailing)
        }
        let workspace = ComposerAction.workspace(
            title: model.selectedWorkspace?.name ?? "Workspace",
            icon: workspaceIcon(colors: colors),
            identifier: "\(model.identifierPrefix).workspacePicker",
            menu: workspaceMenu(),
            colors: colors
        )
        return ComposerActionRow(leading: [workspace], trailing: toolbar.trailing)
    }

    var composerDraftStore: ComposerDraftStore? { nil }
    var composerMediaImportGate: ComposerMediaImportGate? { nil }

    func composerSetText(_ text: String) { model.request = text }
    func composerSetTextBeforeRecording(_ value: String?) { model.textBeforeRecording = value }
    // Attachments are off (`allowsAttachments: false`): the bar offers none.
    func composerSetPendingAttachments(_ value: [PendingAttachment]) {}
    func composerSetPendingRepoPointers(_ value: [PendingFileReference]) {}
    func composerSetBusyStreamingBehavior(_ value: StreamingBehavior) { model.streamingBehavior = value }

    func composerSend() { model.send() }
    func composerStop() {}
    func composerForceStop() {}
    func composerExpand() {}
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
    func composerFileSuggestionQuery(_ query: String?) {}
    func composerPrepareVoiceInput(_ manager: VoiceInputManager) async throws {
        model.configureVoiceInput(manager)
    }

    // Expansion is off (`allowsExpansion: false`): the owner never asks for
    // the expanded composer while `isComposerExpanded` stays false.
    var isComposerExpanded: Bool { false }
    func composerExpandedDidClose() {}
    func makeExpandedComposer() -> ExpandedComposerViewController {
        preconditionFailure("The guided composer does not expand")
    }
    var expandedComposerLiveState: ExpandedComposerLiveState {
        preconditionFailure("The guided composer does not expand")
    }
}
