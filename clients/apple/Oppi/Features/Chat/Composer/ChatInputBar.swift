import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ChatInputPrimaryActionKind: Equatable {
    case send
    case ignoreAsk
    case stop
}

/// Chat input bar with full-width composer and action row.
///
/// **Layout**:
/// ```
/// ┌──────────────────────────────────────┐
/// │ [image strip]                        │
/// │ text input area…            [⬆/×/■] │
/// └──────────────────────────────────────┘
/// [+]  [action row content…]
/// ```
///
/// - Composer capsule spans full width; send/ignore/stop button lives inside it.
/// - `+` and any additional controls (model/thinking pills) sit in a
///   dedicated action row below the capsule.
/// - Expand stays on the trailing side without taking text width.
struct ChatInputBar<ActionRow: View>: View {
    @Binding var text: String
    @Binding var textBeforeRecording: String?
    @Binding var pendingAttachments: [PendingAttachment]
    @Binding var pendingRepoPointers: [PendingFileReference]

    let isBusy: Bool
    @Binding var busyStreamingBehavior: StreamingBehavior
    let isSending: Bool
    var pendingReviewCommentCount: Int = 0
    var onReviewCommentsTap: (() -> Void)? = nil
    var placeholderOverride: String? = nil
    let sendProgressText: String?
    let isStopping: Bool
    var voiceInputManager: VoiceInputManager?
    var onPrepareVoiceInput: ((VoiceInputManager) async throws -> Void)? = nil
    let showForceStop: Bool
    let isForceStopInFlight: Bool
    var askRequest: AskRequest?
    var onAskSubmit: (([String: AskAnswer]) -> Void)?
    var onAskIgnoreAll: (() -> Void)?

    let slashCommands: [SlashCommand]
    let fileSuggestions: [FileSuggestion]
    let onFileSuggestionQuery: ((String?) -> Void)?
    let onSend: () -> Void
    let onStop: () -> Void
    let onForceStop: () -> Void
    let onExpand: () -> Void
    let externalFocusRequestID: Int
    let appliesOuterPadding: Bool
    var alwaysShowActionRow: Bool = false
    @ViewBuilder let actionRow: () -> ActionRow

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var inlineVisualLineCount = 1
    @State private var askCurrentPage = 0
    @State private var askDraftAnswers: [String: AskAnswer] = [:]
    @State private var keepComposerClearedForSubmittedAskRequestID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bumped to programmatically focus the text field.
    @State private var focusRequestID = 0

    /// When true, the keyboard is hidden while the cursor remains visible.
    /// Used during voice recording to show cursor without keyboard.
    @State private var suppressKeyboard = false

    /// Prevents double-submit while final dictation text is being committed.
    @State private var isFinishingVoiceBeforeSend = false

    /// BCP 47 language of the active keyboard (e.g. "zh-Hans", "en-US").
    /// Updated by PastableTextView when the keyboard input mode changes.
    /// Read at mic-tap time to select the correct speech model.
    @State private var keyboardLanguage: String?

    /// Tracks text view focus to reveal composer controls on demand.
    @State private var isInputFocused = false

    private let inlineMaxLines = ComposerInputMetrics.inlineMaxLines
    private let inlineMaxLinesWithImages = ComposerInputMetrics.inlineMaxLinesWithAttachments
    private let expandVisibilityLineThreshold = 5
    /// Apple HIG uses 44×44 pt as the practical minimum touch target.
    /// Keep visible controls at that floor so composer actions are easier to hit.
    private let actionVisualDiameter = ComposerInputMetrics.controlDiameter
    private let expandVisualDiameter = ComposerInputMetrics.controlDiameter
    private let composerHorizontalPadding: CGFloat = 12

    private var composerInputFont: UIFont {
        .preferredFont(forTextStyle: .body)
    }

    private var composerPlaceholderFont: Font { .body }
    private var composerAutocorrectionEnabled: Bool { true }

    private var composerDisplayText: String {
        ComposerShared.currentComposerText(
            storedText: text,
            textBeforeRecording: textBeforeRecording,
            manager: voiceInputManager,
            owner: .inlineComposer
        )
    }

    private var ownsVoiceInput: Bool {
        ComposerShared.ownsVoiceInput(voiceInputManager, owner: .inlineComposer)
    }

    private var canSend: Bool {
        if askRequest != nil {
            return pendingAskSendTransition != nil
        }

        let hasImages = pendingAttachments.contains { $0.source == .image }
        let hasFiles = pendingAttachments.contains { $0.source != .image } || !pendingRepoPointers.isEmpty
        let hasText = !composerDisplayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReviewComments = pendingReviewCommentCount > 0
        return hasText || hasImages || hasFiles || hasReviewComments
    }

    private var activeAskQuestionID: String? {
        guard let askRequest,
              askCurrentPage >= 0,
              askCurrentPage < askRequest.questions.count else {
            return nil
        }
        return askRequest.questions[askCurrentPage].id
    }

    private var pendingAskSendTransition: AskComposerSendTransition? {
        Self.askComposerSendTransition(
            request: askRequest,
            currentPage: askCurrentPage,
            draftAnswers: askDraftAnswers,
            text: composerDisplayText
        )
    }

    private var accentColor: Color { .themeBlue }

    private var composerPlaceholder: String {
        placeholderOverride ?? Self.composerPlaceholder(
            askRequest: askRequest,
            pendingReviewCommentCount: pendingReviewCommentCount,
            isBusy: isBusy,
            busyStreamingBehavior: busyStreamingBehavior
        )
    }

    private var sendActionFillColor: Color {
        if isSendInFlight {
            return isBusy ? .themePurple : accentColor
        }
        return canSend ? (isBusy ? .themePurple : accentColor) : .themeBgHighlight
    }

    private var isSendInFlight: Bool {
        isSending || isFinishingVoiceBeforeSend
    }

    private var sendActionStrokeColor: Color {
        if isSendInFlight {
            return sendActionFillColor.opacity(0.9)
        }
        return canSend ? sendActionFillColor.opacity(0.9) : .themeComment.opacity(0.35)
    }

    private var sendActionForegroundColor: Color {
        guard canSend || isSendInFlight else { return .themeComment }
        return ThemeColorContrast.foreground(for: sendActionFillColor)
    }

    private var primaryActionKind: ChatInputPrimaryActionKind {
        Self.primaryActionKind(
            isBusy: isBusy,
            canSend: canSend,
            isSending: isSendInFlight,
            hasAskRequest: askRequest != nil
        )
    }

    private var autocompleteContext: ComposerAutocompleteContext {
        ComposerAutocomplete.context(for: text, isBusy: isBusy)
    }

    private var slashSuggestions: [SlashCommand] {
        guard case .slash(let query) = autocompleteContext else {
            return []
        }
        return ComposerAutocomplete.slashSuggestions(query: query, commands: slashCommands)
    }

    /// Effective max lines — reduced when images or files are present to prevent the
    /// capsule from growing tall enough to push the send button off-screen.
    private var effectiveMaxLines: Int {
        (pendingAttachments.isEmpty && pendingRepoPointers.isEmpty) ? inlineMaxLines : inlineMaxLinesWithImages
    }

    /// Show manual expand only when input is getting long.
    private var showsExpandButton: Bool {
        inlineVisualLineCount >= expandVisibilityLineThreshold
            || (!(pendingAttachments.isEmpty && pendingRepoPointers.isEmpty) && inlineVisualLineCount >= inlineMaxLinesWithImages)
    }

    /// Slack-style inline controls row: hidden until composer is active.
    private var showsComposerActionRow: Bool {
        Self.shouldShowComposerActionRow(
            alwaysShowActionRow: alwaysShowActionRow,
            isBusy: isBusy,
            isInputFocused: isInputFocused,
            isKeyboardSuppressed: suppressKeyboard,
            hasAttachments: !pendingAttachments.isEmpty,
            hasRepoPointers: !pendingRepoPointers.isEmpty
        )
    }

    private var showsBusyModeSelector: Bool {
        Self.showsBusyModeSelector(isBusy: isBusy, hasAskRequest: askRequest != nil)
    }

    /// Tapping the input while voice is active should switch back to typing:
    /// restore the keyboard immediately and stop/cancel voice automatically.
    private var allowKeyboardRestoreOnTap: Bool {
        guard let manager = voiceInputManager else { return true }
        return Self.allowKeyboardRestoreOnTap(voiceState: manager.state)
    }

    /// Text binding for the input field.
    private var textFieldBinding: Binding<String> {
        ComposerShared.textFieldBinding(text: $text) { composerDisplayText }
    }

    private var correctionRangesForDisplay: [NSRange] {
        return ComposerShared.correctionRanges(
            manager: voiceInputManager,
            textBeforeRecording: textBeforeRecording,
            owner: .inlineComposer
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            if showForceStop {
                forceStopButton
            }

            if !slashSuggestions.isEmpty {
                SlashCommandSuggestionList(suggestions: slashSuggestions) { command in
                    ComposerShared.insertSlashCommand(command, into: $text)
                }
            }

            if !fileSuggestions.isEmpty, case .atFile = autocompleteContext {
                FileSuggestionList(suggestions: fileSuggestions) { suggestion in
                    ComposerShared.insertFileSuggestion(suggestion, text: $text, pendingRepoPointers: $pendingRepoPointers)
                }
            }

            if let sendProgressText {
                HStack(spacing: 6) {
                    if isSending {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.caption2)
                    }
                    Text(sendProgressText)
                        .font(.caption.monospaced())
                }
                .foregroundStyle(.themeComment)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            composerCapsule
        }
        .padding(.horizontal, appliesOuterPadding ? 16 : 0)
        .padding(.bottom, appliesOuterPadding ? 8 : 0)
        .onChange(of: text) { _, newValue in
            if newValue.isEmpty {
                inlineVisualLineCount = 1
            }
            ComposerShared.notifyFileSuggestionContext(
                for: newValue,
                isBusy: isBusy,
                onFileSuggestionQuery: onFileSuggestionQuery
            )
        }
        .onChange(of: askRequest?.id) { _, _ in
            askCurrentPage = 0
            askDraftAnswers = [:]
            keepComposerClearedForSubmittedAskRequestID = nil
        }
        .onChange(of: askCurrentPage) { _, _ in
            syncComposerTextWithActiveAskQuestion()
        }
        .onChange(of: askDraftAnswers) { _, _ in
            syncComposerTextWithActiveAskQuestion()
        }
        .onChange(of: photoSelection) { _, items in
            ComposerShared.loadSelectedPhotos(items, into: $pendingAttachments)
            photoSelection = []
        }
        .onChange(of: externalFocusRequestID) { _, _ in
            suppressKeyboard = false
            focusRequestID += 1
        }
        .onChange(of: voiceInputManager?.transcriptPresentationRevision) { _, _ in
            guard let prefix = textBeforeRecording, let manager = voiceInputManager else { return }
            guard ComposerShared.ownsVoiceInput(manager, owner: .inlineComposer) else { return }
            text = prefix + manager.currentTranscript
        }
        .onChange(of: keyboardLanguage) { _, newLanguage in
            guard ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager else { return }
            guard AppPreferences.Keyboard.normalize(newLanguage) != nil else { return }
            Task {
                await manager.prewarm(
                    keyboardLanguage: newLanguage,
                    source: "inline_keyboard_change"
                )
            }
        }
        .composerCameraCover(isPresented: $showCamera, pendingAttachments: $pendingAttachments)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            ComposerShared.loadSelectedFiles(result, into: $pendingAttachments)
        }
    }

    // MARK: - Subviews

    private var composerCapsule: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Ask card (inline question from agent)
            if let askRequest {
                AskCard(
                    request: askRequest,
                    currentPage: $askCurrentPage,
                    answers: $askDraftAnswers,
                    onSubmit: { answers in onAskSubmit?(answers) },
                    onIgnoreAll: { onAskIgnoreAll?() },
                    voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil
                )
                .id(askRequest.id)
                .padding(.horizontal, composerHorizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .transition(ThemeMotion.move(edge: .top, reduceMotion: reduceMotion))
            }

            if pendingReviewCommentCount > 0 {
                reviewCommentStashBar
                    .padding(.horizontal, composerHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, pendingAttachments.isEmpty && pendingRepoPointers.isEmpty ? 4 : 2)
            }

            if !pendingAttachments.isEmpty {
                attachmentStrip
                    .padding(.horizontal, composerHorizontalPadding)
                    .padding(.top, pendingReviewCommentCount > 0 ? 2 : 8)
                    .padding(.bottom, 4)
            }

            if !pendingRepoPointers.isEmpty {
                filePillStrip
                    .padding(.horizontal, composerHorizontalPadding)
                    .padding(.top, pendingAttachments.isEmpty ? 8 : 2)
                    .padding(.bottom, 4)
            }

            // Text row with mic + text + send/stop
            HStack(alignment: .bottom, spacing: 8) {
                if ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager {
                    inlineMicButton(manager: manager)
                        .fixedSize()
                }

                ZStack(alignment: .leading) {
                    if ComposerShared.visibleComposerText(composerDisplayText).isEmpty {
                        Text(composerPlaceholder)
                            .font(composerPlaceholderFont)
                            .foregroundStyle(.themeComment)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }

                    PastableTextView(
                        text: textFieldBinding,
                        placeholder: "",
                        font: composerInputFont,
                        textColor: UIColor(Color.themeFg),
                        tintColor: UIColor(isBusy ? Color.themePurple : accentColor),
                        volatileSuffixLength: ComposerShared.volatileSuffixLength(manager: voiceInputManager, owner: .inlineComposer),
                        correctionRanges: correctionRangesForDisplay,
                        maxLines: effectiveMaxLines,
                        autocorrectionEnabled: composerAutocorrectionEnabled,
                        onPasteImages: { ComposerShared.handlePastedImages($0, into: $pendingAttachments) },
                        onCommandEnter: handleSend,
                        onAlternateEnter: handleAlternateSend,
                        onOverflowChange: nil,
                        onLineCountChange: handleInlineLineCountChange,
                        onFocusChange: handleInputFocusChange,
                        onDictationStateChange: nil,
                        focusRequestID: focusRequestID,
                        blurRequestID: 0,
                        dictationRequestID: 0,
                        suppressKeyboard: suppressKeyboard,
                        allowKeyboardRestoreOnTap: allowKeyboardRestoreOnTap,
                        onKeyboardRestoreRequest: {
                            ComposerShared.handleKeyboardRestore(
                                suppressKeyboard: $suppressKeyboard,
                                textBeforeRecording: $textBeforeRecording,
                                voiceInputManager: voiceInputManager,
                                expectedOwner: .inlineComposer
                            )
                        },
                        accessibilityIdentifier: "chat.input",
                        keyboardLanguage: $keyboardLanguage
                    )
                }
                .padding(.trailing, Self.composerTextTrailingPadding(showsExpandButton: showsExpandButton))
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                primaryActionButton
                    .fixedSize()
            }
            .padding(.horizontal, composerHorizontalPadding)
            .padding(.vertical, 10)

            if showsComposerActionRow {
                HStack(spacing: 6) {
                    attachButton

                    if showsBusyModeSelector {
                        busyModeSelector
                    }

                    actionRow()
                }
                .padding(.horizontal, composerHorizontalPadding)
                .padding(.top, 2)
                .padding(.bottom, 7)
                .transition(ThemeMotion.move(edge: .bottom, reduceMotion: reduceMotion))
            }
        }
        .frame(minHeight: 88)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if showsExpandButton {
                expandButton
                    .padding(.top, 6)
                    .padding(.trailing, composerHorizontalPadding)
            }
        }
        .animation(ThemeMotion.easeInOut(duration: 0.18, reduceMotion: reduceMotion), value: showsComposerActionRow)
    }

    private var attachButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

            Button {
                showCamera = true
            } label: {
                Label("Camera", systemImage: "camera")
            }

            Button {
                showFileImporter = true
            } label: {
                Label("Choose File", systemImage: "paperclip")
            }
        } label: {
            Image(systemName: "plus")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeFg)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: 5,
            matching: .images,
            preferredItemEncoding: .current
        )
    }

    private var busyModeSelector: some View {
        Menu {
            Button {
                busyStreamingBehavior = .steer
            } label: {
                HStack {
                    Text("Steering")
                    if busyStreamingBehavior == .steer {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                busyStreamingBehavior = .followUp
            } label: {
                HStack {
                    Text("Follow-up")
                    if busyStreamingBehavior == .followUp {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(busyStreamingBehavior == .steer ? "Steering" : "Follow-up")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.themeFg)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
        }
        .accessibilityIdentifier("chat.busyMode")
        .accessibilityLabel("Busy send mode")
    }

    private var attachmentStrip: some View {
        ComposerShared.attachmentStrip(pendingAttachments: $pendingAttachments)
    }

    private var reviewCommentStashBar: some View {
        Button {
            onReviewCommentsTap?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeCyan)

                Text(Self.reviewCommentStashTitle(count: pendingReviewCommentCount))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("Review")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)

                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.themeComment)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.themeBgHighlight.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.themeCyan.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.reviewComments.stash")
        .accessibilityLabel(Self.reviewCommentStashTitle(count: pendingReviewCommentCount))
        .accessibilityHint("Shows the review comments staged for the next message")
    }

    private var filePillStrip: some View {
        ComposerShared.filePillStrip(pendingRepoPointers: $pendingRepoPointers)
    }

    private var expandButton: some View {
        Button(action: onExpand) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.appCaption)
                .foregroundStyle(.themeComment)
                .frame(width: expandVisualDiameter, height: expandVisualDiameter)
        }
        .accessibilityIdentifier("chat.expand")
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch primaryActionKind {
        case .send:
            sendActionButton
        case .ignoreAsk:
            ignoreAskActionButton
        case .stop:
            stopActionButton
        }
    }

    private var sendActionButton: some View {
        Button(action: handleSend) {
            ZStack {
                Circle().fill(sendActionFillColor)
                Circle().stroke(sendActionStrokeColor, lineWidth: 1)

                if isSendInFlight {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(sendActionForegroundColor)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.appButton)
                        .foregroundStyle(sendActionForegroundColor)
                }
            }
            .frame(width: actionVisualDiameter, height: actionVisualDiameter)
        }
        .buttonStyle(.plain)
        .disabled(!canSend || isSendInFlight)
        .accessibilityIdentifier("chat.send")
        .accessibilityLabel(isSendInFlight ? "Sending" : "Send")
    }

    private var ignoreAskActionButton: some View {
        Button(action: { onAskIgnoreAll?() }) {
            ZStack {
                Circle().fill(Color.themeBgHighlight)
                Circle().stroke(Color.themeComment.opacity(0.35), lineWidth: 1)

                Image(systemName: "xmark")
                    .font(.appActionBold)
                    .foregroundStyle(.themeComment)
            }
            .frame(width: actionVisualDiameter, height: actionVisualDiameter)
        }
        .buttonStyle(.plain)
        .disabled(onAskIgnoreAll == nil)
        .accessibilityIdentifier("chat.askIgnore")
        .accessibilityLabel("Ignore request")
        .accessibilityHint("Responds to the current extension request as ignored")
    }

    /// Compact mic toggle inside the capsule, left of the text field.
    /// Tap to start recording, tap again to stop. Works in any state
    /// (idle or busy) so you can mix typing and dictation freely.
    private func inlineMicButton(manager: VoiceInputManager) -> some View {
        let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .inlineComposer)

        return Button {
            Task {
                guard ComposerShared.canControlVoiceInput(manager, owner: .inlineComposer) else { return }
                switch manager.state {
                case .recording:
                    await ComposerShared.stopVoiceInput(
                        manager: manager,
                        text: $text,
                        textBeforeRecording: $textBeforeRecording
                    )
                    // Keep keyboard suppressed — user tapping the text field
                    // will restore it via handleKeyboardRestore()
                case .preparingModel:
                    await ComposerShared.cancelVoiceInput(
                        manager: manager,
                        textBeforeRecording: $textBeforeRecording,
                        suppressKeyboard: $suppressKeyboard
                    )
                case .idle:
                    do {
                        try await ComposerShared.startVoiceInput(
                            manager: manager,
                            keyboardLanguage: keyboardLanguage,
                            owner: .inlineComposer,
                            baseText: text,
                            textBeforeRecording: $textBeforeRecording,
                            suppressKeyboard: $suppressKeyboard,
                            focusRequestID: $focusRequestID,
                            prepare: {
                                try await onPrepareVoiceInput?(manager)
                            }
                        )
                    } catch {
                    }
                case .processing, .error:
                    break
                }
            }
        } label: {
            MicButtonLabel(
                presentation: presentation,
                accentColor: accentColor,
                diameter: actionVisualDiameter
            )
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isEnabled)
        .accessibilityIdentifier("chat.voiceInput")
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }

    private var stopActionButton: some View {
        let fillColor = isStopping ? Color.themeOrange : Color.themeRed
        let foregroundColor = ThemeColorContrast.foreground(for: fillColor)

        return Button(action: onStop) {
            ZStack {
                Circle().fill(fillColor)
                Circle().stroke(fillColor.opacity(0.9), lineWidth: 1)

                if isStopping {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(foregroundColor)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.appActionBold)
                        .foregroundStyle(foregroundColor)
                }
            }
            .frame(width: actionVisualDiameter + 2, height: actionVisualDiameter + 2)
        }
        .buttonStyle(.plain)
        .disabled(isStopping)
        .accessibilityIdentifier("chat.stop")
        .accessibilityLabel(isStopping ? "Stopping" : "Stop response")
    }

    private var forceStopButton: some View {
        Button(role: .destructive) {
            onForceStop()
        } label: {
            if isForceStopInFlight {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.themeRed)
                    Text("Stopping…")
                }
            } else {
                Text("Force Stop Session")
            }
        }
        .font(.caption)
        .foregroundStyle(.themeRed)
        .disabled(isForceStopInFlight)
    }

    // MARK: - Actions

    private func handleInlineLineCountChange(_ lineCount: Int) {
        inlineVisualLineCount = max(lineCount, 1)
    }

    private func handleInputFocusChange(_ isFocused: Bool) {
        isInputFocused = isFocused
    }

    static func composerTextTrailingPadding(showsExpandButton: Bool) -> CGFloat {
        showsExpandButton ? 10 : 0
    }

    static func allowKeyboardRestoreOnTap(voiceState _: VoiceInputManager.State) -> Bool {
        true
    }

    static func shouldShowComposerActionRow(
        alwaysShowActionRow: Bool,
        isBusy: Bool,
        isInputFocused: Bool,
        isKeyboardSuppressed: Bool,
        hasAttachments: Bool,
        hasRepoPointers: Bool
    ) -> Bool {
        alwaysShowActionRow
            || isBusy
            || (isInputFocused && !isKeyboardSuppressed)
            || hasAttachments
            || hasRepoPointers
    }

    static func suppressKeyboardAfterSend(
        voiceState: VoiceInputManager.State,
        wasSuppressed: Bool
    ) -> Bool {
        switch voiceState {
        case .recording, .preparingModel:
            return wasSuppressed
        case .idle, .processing, .error:
            return wasSuppressed
        }
    }

    /// Ask responses take precedence over normal busy sends while an ask card
    /// is active. That lets the main composer answer the visible custom ask
    /// directly instead of creating a steering/follow-up message.
    static func composerPlaceholder(
        askRequest: AskRequest?,
        pendingReviewCommentCount: Int,
        isBusy: Bool,
        busyStreamingBehavior: StreamingBehavior
    ) -> String {
        if pendingReviewCommentCount > 0 {
            return "Send \(pendingReviewCommentCount) review \(pendingReviewCommentCount == 1 ? "comment" : "comments")…"
        }
        if let askRequest {
            if askRequest.allowCustom {
                if let placeholder = askRequest.customPlaceholder?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !placeholder.isEmpty {
                    return placeholder
                }
                return "Type answer…"
            }
            return "Choose an option…"
        }
        guard isBusy else { return "Message…" }
        return busyStreamingBehavior == .steer ? "Steer agent…" : "Queue follow-up…"
    }

    static func reviewCommentStashTitle(count: Int) -> String {
        "\(count) review \(count == 1 ? "comment" : "comments") staged"
    }

    static func primaryActionKind(
        isBusy: Bool,
        canSend: Bool,
        isSending: Bool,
        hasAskRequest: Bool
    ) -> ChatInputPrimaryActionKind {
        if canSend || isSending {
            return .send
        }
        guard isBusy else { return .send }
        return hasAskRequest ? .ignoreAsk : .stop
    }

    static func showsBusyModeSelector(isBusy: Bool, hasAskRequest: Bool) -> Bool {
        isBusy && !hasAskRequest
    }

    static func customAskAnswers(
        request: AskRequest?,
        activeQuestionID: String? = nil,
        draftAnswers: [String: AskAnswer] = [:],
        text: String
    ) -> [String: AskAnswer]? {
        guard let request,
              request.allowCustom,
              let question = customAskQuestion(request: request, activeQuestionID: activeQuestionID)
        else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var answers = draftAnswers
        answers[question.id] = .custom(trimmed)
        return answers
    }

    private static func customAskQuestion(request: AskRequest, activeQuestionID: String?) -> AskQuestion? {
        if let activeQuestionID,
           let question = request.questions.first(where: { $0.id == activeQuestionID }) {
            return question
        }
        return request.questions.first
    }

    static func shouldSubmitAskResponseImmediately(request: AskRequest?, currentPage: Int) -> Bool {
        guard let request else { return false }
        guard request.questions.count > 1 else { return true }
        return currentPage >= request.questions.count - 1
    }

    static func customAskText(answers: [String: AskAnswer], questionID: String?) -> String {
        guard let questionID, case .custom(let text) = answers[questionID] else {
            return ""
        }
        return text
    }

    static func composerTextForActiveAskQuestion(
        request: AskRequest?,
        activeQuestionID: String?,
        draftAnswers: [String: AskAnswer],
        keepComposerClearedForSubmittedRequestID: String?
    ) -> String {
        guard let request, request.allowCustom else { return "" }
        if keepComposerClearedForSubmittedRequestID == request.id {
            return ""
        }
        return customAskText(answers: draftAnswers, questionID: activeQuestionID)
    }

    struct AskComposerSendTransition: Equatable {
        let nextPage: Int
        let answers: [String: AskAnswer]
        let nextComposerText: String
        let shouldSubmit: Bool
    }

    static func askComposerSendTransition(
        request: AskRequest?,
        currentPage: Int,
        draftAnswers: [String: AskAnswer],
        text: String
    ) -> AskComposerSendTransition? {
        guard let request,
              request.questions.indices.contains(currentPage) else {
            return nil
        }

        let activeQuestionID = request.questions[currentPage].id
        let answers: [String: AskAnswer]
        if let customAnswers = customAskAnswers(
            request: request,
            activeQuestionID: activeQuestionID,
            draftAnswers: draftAnswers,
            text: text
        ) {
            answers = customAnswers
        } else {
            guard draftAnswers[activeQuestionID] != nil else { return nil }
            answers = draftAnswers
        }

        if shouldSubmitAskResponseImmediately(request: request, currentPage: currentPage) {
            return AskComposerSendTransition(
                nextPage: currentPage,
                answers: answers,
                nextComposerText: "",
                shouldSubmit: true
            )
        }

        let nextPage = min(currentPage + 1, request.questions.count - 1)
        let nextQuestionID = request.questions[nextPage].id
        return AskComposerSendTransition(
            nextPage: nextPage,
            answers: answers,
            nextComposerText: customAskText(answers: answers, questionID: nextQuestionID),
            shouldSubmit: false
        )
    }

    private func syncComposerTextWithActiveAskQuestion() {
        let desiredText = Self.composerTextForActiveAskQuestion(
            request: askRequest,
            activeQuestionID: activeAskQuestionID,
            draftAnswers: askDraftAnswers,
            keepComposerClearedForSubmittedRequestID: keepComposerClearedForSubmittedAskRequestID
        )
        guard text != desiredText || textBeforeRecording != nil else { return }
        text = desiredText
        textBeforeRecording = nil
    }

    private func handleSend() {
        guard !isSendInFlight else { return }

        if let manager = voiceInputManager,
           ComposerShared.ownsVoiceInput(manager, owner: .inlineComposer),
           manager.isRecording || manager.isPreparing {
            isFinishingVoiceBeforeSend = true
            Task { @MainActor in
                await ComposerShared.finishOwnedVoiceInputBeforeSubmit(
                    manager: manager,
                    owner: .inlineComposer,
                    text: $text,
                    textBeforeRecording: $textBeforeRecording,
                    suppressKeyboard: $suppressKeyboard
                )
                isFinishingVoiceBeforeSend = false
                submitCurrentComposerAction()
            }
            return
        }

        submitCurrentComposerAction()
    }

    private func submitCurrentComposerAction() {
        if handleAskComposerSendIfNeeded() {
            return
        }
        if askRequest != nil {
            onAskIgnoreAll?()
            return
        }
        onSend()
    }

    private func handleAskComposerSendIfNeeded() -> Bool {
        guard let transition = Self.askComposerSendTransition(
            request: askRequest,
            currentPage: askCurrentPage,
            draftAnswers: askDraftAnswers,
            text: composerDisplayText
        ) else {
            return false
        }

        askDraftAnswers = transition.answers
        text = transition.nextComposerText
        textBeforeRecording = nil

        if transition.shouldSubmit {
            keepComposerClearedForSubmittedAskRequestID = askRequest?.id
            onAskSubmit?(transition.answers)
        } else {
            withAnimation(ThemeMotion.easeInOut(duration: 0.25, reduceMotion: reduceMotion)) {
                askCurrentPage = transition.nextPage
            }
        }

        return true
    }

    private func handleAlternateSend() {
        guard !isSendInFlight else { return }

        if isBusy {
            busyStreamingBehavior = .followUp
        }

        handleSend()
    }
}

// MARK: - PendingImage

/// An image queued for sending. Holds a thumbnail for display and
/// full-resolution image data + base64 for upload.
struct PendingImage: Identifiable, Sendable {
    let id: String
    let thumbnail: UIImage
    let attachment: ImageAttachment

    private typealias EncodedImage = (data: Data, mimeType: String)

    private static let autoResizeMaxDimension: CGFloat = 2_000
    private static let autoResizeMaxBase64Bytes = 4_718_592
    private static let autoResizeJPEGQualities: [CGFloat] = [0.8, 0.85, 0.7, 0.55, 0.4]

    var pendingAttachment: PendingAttachment {
        PendingAttachment(
            id: id,
            source: .image,
            displayName: "Image",
            thumbnail: thumbnail,
            imageAttachment: attachment,
            localFileData: nil,
            localMimeType: nil
        )
    }

    /// Create from original picked image data when it is already in a model-friendly format.
    /// Unsupported formats such as HEIC are converted to full-resolution JPEG without downscaling.
    static func from(data: Data, mimeType: String?, image: UIImage) -> Self {
        if let sendableMimeType = sendableOriginalMimeType(data: data, declaredMimeType: mimeType) {
            return Self(
                id: UUID().uuidString,
                thumbnail: downsample(image, maxDimension: 112),
                attachment: ImageAttachment(
                    data: data.base64EncodedString(),
                    mimeType: sendableMimeType
                )
            )
        }

        return from(image)
    }

    /// Create from a UIImage without reducing dimensions. Uses maximum JPEG quality for upload.
    static func from(_ image: UIImage) -> Self {
        let thumb = downsample(image, maxDimension: 112)
        let imageData = image.jpegData(compressionQuality: 1.0) ?? image.pngData() ?? Data()
        let mimeType = sniffedMimeType(data: imageData) ?? "image/jpeg"

        return Self(
            id: UUID().uuidString,
            thumbnail: thumb,
            attachment: ImageAttachment(
                data: imageData.base64EncodedString(),
                mimeType: mimeType
            )
        )
    }

    /// Apply server-configured Pi-style upload resizing when requested.
    /// Keeps the pending/original attachment untouched when resizing is disabled.
    static func uploadAttachment(from attachment: ImageAttachment, autoResize: Bool) -> ImageAttachment {
        guard autoResize,
              let originalData = Data(base64Encoded: attachment.data, options: .ignoreUnknownCharacters),
              let image = UIImage(data: originalData) else {
            return attachment
        }

        let originalFitsDimensions = maxPixelDimension(for: image) <= autoResizeMaxDimension
        if originalFitsDimensions && base64ByteCount(for: originalData) <= autoResizeMaxBase64Bytes {
            return attachment
        }

        var workingImage = originalFitsDimensions
            ? image
            : downsample(image, maxDimension: autoResizeMaxDimension)
        var bestCandidate: EncodedImage?

        while true {
            for candidate in encodedCandidates(for: workingImage) {
                if let best = bestCandidate {
                    if candidate.data.count < best.data.count {
                        bestCandidate = candidate
                    }
                } else {
                    bestCandidate = candidate
                }
                if base64ByteCount(for: candidate.data) <= autoResizeMaxBase64Bytes {
                    return ImageAttachment(
                        data: candidate.data.base64EncodedString(),
                        mimeType: candidate.mimeType
                    )
                }
            }

            let currentSize = pixelSize(for: workingImage)
            let nextSize = CGSize(
                width: max(1, floor(currentSize.width * 0.75)),
                height: max(1, floor(currentSize.height * 0.75))
            )
            guard nextSize.width < currentSize.width || nextSize.height < currentSize.height else {
                break
            }
            workingImage = render(workingImage, size: nextSize)
        }

        guard let bestCandidate else { return attachment }
        return ImageAttachment(
            data: bestCandidate.data.base64EncodedString(),
            mimeType: bestCandidate.mimeType
        )
    }

    private static func sendableOriginalMimeType(data: Data, declaredMimeType: String?) -> String? {
        if let sniffed = sniffedMimeType(data: data) {
            return sniffed
        }

        switch normalizedMimeType(declaredMimeType) {
        case "image/jpeg", "image/jpg": return "image/jpeg"
        case "image/png": return "image/png"
        case "image/gif": return "image/gif"
        case "image/webp": return "image/webp"
        default: return nil
        }
    }

    private static func normalizedMimeType(_ mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        return mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func sniffedMimeType(data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        if data.count >= 12,
           data.prefix(4).elementsEqual(Array("RIFF".utf8)),
           data.dropFirst(8).prefix(4).elementsEqual(Array("WEBP".utf8)) {
            return "image/webp"
        }
        return nil
    }

    private static func encodedCandidates(for image: UIImage) -> [EncodedImage] {
        var candidates: [EncodedImage] = []
        if let pngData = image.pngData() {
            candidates.append((pngData, "image/png"))
        }
        for quality in autoResizeJPEGQualities {
            if let jpegData = image.jpegData(compressionQuality: quality) {
                candidates.append((jpegData, "image/jpeg"))
            }
        }
        return candidates
    }

    private static func base64ByteCount(for data: Data) -> Int {
        ((data.count + 2) / 3) * 4
    }

    private static func maxPixelDimension(for image: UIImage) -> CGFloat {
        let size = pixelSize(for: image)
        return max(size.width, size.height)
    }

    private static func pixelSize(for image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return image.size
    }

    /// Downsample to fit within maxDimension, preserving aspect ratio.
    private static func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = pixelSize(for: image)
        guard size.width > 0, size.height > 0 else { return image }

        let scale = min(maxDimension / size.width, maxDimension / size.height)
        if scale >= 1.0 { return image }

        let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        return render(image, size: newSize)
    }

    private static func render(_ image: UIImage, size: CGSize) -> UIImage {
        let renderSize = CGSize(
            width: max(1, floor(size.width)),
            height: max(1, floor(size.height))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: renderSize))
        }
    }
}
