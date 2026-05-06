import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Chat input bar with full-width composer and action row.
///
/// **Layout**:
/// ```
/// ┌──────────────────────────────────────┐
/// │ [image strip]                        │
/// │ text input area…              [⬆/■]  │
/// └──────────────────────────────────────┘
/// [+]  [action row content…]
/// ```
///
/// - Composer capsule spans full width; send/stop button lives inside it.
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
    let sendProgressText: String?
    let isStopping: Bool
    var voiceInputManager: VoiceInputManager?
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

    /// BCP 47 language of the active keyboard (e.g. "zh-Hans", "en-US").
    /// Updated by PastableTextView when the keyboard input mode changes.
    /// Read at mic-tap time to select the correct speech model.
    @State private var keyboardLanguage: String?

    /// Tracks text view focus to reveal composer controls on demand.
    @State private var isInputFocused = false

    private let inlineMaxLines = 8
    private let inlineMaxLinesWithImages = 4
    private let expandVisibilityLineThreshold = 5
    /// Apple HIG uses 44×44 pt as the practical minimum touch target.
    /// Keep visible controls at that floor so composer actions are easier to hit.
    private let actionVisualDiameter: CGFloat = 44
    private let expandVisualDiameter: CGFloat = 44
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
            liveTranscript: voiceInputManager?.currentTranscript
        )
    }

    private var canSend: Bool {
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

    private var pendingAskCustomAnswers: [String: AskAnswer]? {
        Self.customAskAnswers(
            request: askRequest,
            activeQuestionID: activeAskQuestionID,
            draftAnswers: askDraftAnswers,
            text: composerDisplayText
        )
    }

    private var accentColor: Color { .themeBlue }

    private var composerPlaceholder: String {
        Self.composerPlaceholder(
            askRequest: askRequest,
            pendingReviewCommentCount: pendingReviewCommentCount,
            isBusy: isBusy,
            busyStreamingBehavior: busyStreamingBehavior
        )
    }

    private var sendActionFillColor: Color {
        if isSending {
            return isBusy ? .themePurple : accentColor
        }
        return canSend ? (isBusy ? .themePurple : accentColor) : .themeBgHighlight
    }

    private var sendActionStrokeColor: Color {
        if isSending {
            return sendActionFillColor.opacity(0.9)
        }
        return canSend ? sendActionFillColor.opacity(0.9) : .themeComment.opacity(0.35)
    }

    private var sendActionForegroundColor: Color {
        guard canSend || isSending else { return .themeComment }
        return ThemeColorContrast.foreground(for: sendActionFillColor)
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
        alwaysShowActionRow || isBusy || isInputFocused || !pendingAttachments.isEmpty || !pendingRepoPointers.isEmpty
    }

    /// Tapping the input while voice is active should switch back to typing:
    /// restore the keyboard immediately and stop/cancel voice automatically.
    private var allowKeyboardRestoreOnTap: Bool {
        guard let manager = voiceInputManager else { return true }
        return Self.allowKeyboardRestoreOnTap(voiceState: manager.state)
    }

    /// Text binding for the input field.
    private var textFieldBinding: Binding<String> {
        Binding(
            get: {
                Self.visibleComposerText(composerDisplayText)
            },
            set: { newValue in
                if text.hasPrefix("$ ") {
                    text = newValue.isEmpty ? "" : "$ " + newValue
                } else {
                    text = newValue
                }
            }
        )
    }

    private var correctionRangesForDisplay: [NSRange] {
        guard let manager = voiceInputManager,
              let prefix = textBeforeRecording else { return [] }
        let offset = (Self.visibleComposerText(prefix) as NSString).length
        return manager.currentTranscriptCorrectionRanges.map { range in
            NSRange(location: range.location + offset, length: range.length)
        }
    }

    private static func visibleComposerText(_ text: String) -> String {
        if text.hasPrefix("$ ") {
            return String(text.dropFirst(2))
        }
        return text
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

            if !pendingAttachments.isEmpty {
                attachmentStrip
                    .padding(.horizontal, composerHorizontalPadding)
                    .padding(.top, 8)
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
                    if Self.visibleComposerText(composerDisplayText).isEmpty {
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
                        volatileSuffixLength: voiceInputManager?.currentTranscriptVolatileSuffixLength ?? 0,
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
                                voiceInputManager: voiceInputManager
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

                    if isBusy {
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
            matching: .images
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { attachment in
                    if attachment.source == .image, let thumbnail = attachment.thumbnail {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.themeComment.opacity(0.3), lineWidth: 1)
                                )

                            Button {
                                ComposerShared.removeAttachment(attachment.id, from: $pendingAttachments)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.themeFg)
                                    .background(Circle().fill(.themeScrim))
                            }
                            .offset(x: 4, y: -4)
                        }
                    } else {
                        ComposerAttachmentPill(name: attachment.displayName) {
                            ComposerShared.removeAttachment(attachment.id, from: $pendingAttachments)
                        }
                    }
                }
            }
        }
    }

    private var filePillStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pendingRepoPointers) { file in
                    ComposerFilePill(file: file) {
                        ComposerShared.removeFile(file.id, from: $pendingRepoPointers)
                    }
                }
            }
        }
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
        if isBusy {
            if canSend || isSending {
                sendActionButton
            } else {
                stopActionButton
            }
        } else {
            sendActionButton
        }
    }

    private var sendActionButton: some View {
        Button(action: handleSend) {
            ZStack {
                Circle().fill(sendActionFillColor)
                Circle().stroke(sendActionStrokeColor, lineWidth: 1)

                if isSending {
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
        .disabled(!canSend || isSending)
        .accessibilityIdentifier("chat.send")
    }

    /// Compact mic toggle inside the capsule, left of the text field.
    /// Tap to start recording, tap again to stop. Works in any state
    /// (idle or busy) so you can mix typing and dictation freely.
    private func inlineMicButton(manager: VoiceInputManager) -> some View {
        let isRecording = manager.isRecording
        let isPreparing = manager.isPreparing
        let isProcessing = manager.isProcessing
        let engineBadge = ComposerShared.micEngineBadge(for: manager)

        return Button {
            Task {
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
                            source: "inline_mic_tap",
                            baseText: text,
                            textBeforeRecording: $textBeforeRecording,
                            suppressKeyboard: $suppressKeyboard,
                            focusRequestID: $focusRequestID
                        )
                    } catch {
                    }
                case .processing, .error:
                    break
                }
            }
        } label: {
            MicButtonLabel(
                isRecording: isRecording,
                isProcessing: isPreparing || isProcessing,
                audioLevel: manager.audioLevel,
                languageLabel: manager.activeLanguageLabel,
                accentColor: accentColor,
                engineBadge: engineBadge,
                diameter: actionVisualDiameter
            )
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .accessibilityIdentifier("chat.voiceInput")
        .accessibilityLabel(ComposerShared.accessibilityLabel(isRecording: isRecording, isPreparing: isPreparing))
        .accessibilityValue(ComposerShared.voiceRouteAccessibilityValue(for: manager))
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
            return "Send review comments…"
        }
        if let askRequest, askRequest.allowCustom {
            return "Type answer…"
        }
        guard isBusy else { return "Message…" }
        return busyStreamingBehavior == .steer ? "Steer agent…" : "Queue follow-up…"
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
        guard request.allowCustom else { return false }
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
        guard let answers = customAskAnswers(
            request: request,
            activeQuestionID: activeQuestionID,
            draftAnswers: draftAnswers,
            text: text
        ) else {
            return nil
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
        guard !isSending else { return }

        // Stop voice recording before sending. We await the stop so the final
        // transcript (including any last active tail from dictation_final)
        // updates the text field before onSend() captures it.
        if let manager = voiceInputManager, manager.isRecording || manager.isPreparing {
            textBeforeRecording = nil
            suppressKeyboard = Self.suppressKeyboardAfterSend(
                voiceState: manager.state,
                wasSuppressed: suppressKeyboard
            )
            Task {
                if manager.isRecording {
                    await manager.stopRecording()
                } else {
                    await manager.cancelRecording()
                }
                if !handleAskComposerSendIfNeeded() {
                    onSend()
                }
            }
            return
        }

        if !handleAskComposerSendIfNeeded() {
            onSend()
        }
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
        guard !isSending else { return }

        if isBusy {
            busyStreamingBehavior = .followUp
        }

        handleSend()
    }
}

// MARK: - PendingImage

/// An image queued for sending. Holds the thumbnail for display and
/// the compressed JPEG data + base64 for the wire protocol.
struct PendingImage: Identifiable, Sendable {
    let id: String
    let thumbnail: UIImage
    let attachment: ImageAttachment

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

    /// Anthropic API limit for base64 image content (bytes).
    private static let maxBase64Bytes = 5_242_880

    /// Max raw JPEG bytes that will stay under 5MB after base64 encoding (~33% inflation).
    private static let maxRawBytes = maxBase64Bytes * 3 / 4  // ~3.93MB

    /// Create from a UIImage. Resizes large images and compresses to JPEG.
    /// Progressively reduces quality if the result exceeds the 5MB API limit.
    static func from(_ image: UIImage) -> Self {
        let resized = downsample(image, maxDimension: 1568)
        let thumb = downsample(image, maxDimension: 112)

        // Start at high quality, step down if base64 would exceed 5MB
        var quality: CGFloat = 0.85
        var jpegData = resized.jpegData(compressionQuality: quality) ?? Data()

        while jpegData.count > maxRawBytes, quality > 0.2 {
            quality -= 0.1
            jpegData = resized.jpegData(compressionQuality: quality) ?? Data()
        }

        // If still too large after quality reduction, downsample further
        if jpegData.count > maxRawBytes {
            let smaller = downsample(image, maxDimension: 1024)
            jpegData = smaller.jpegData(compressionQuality: 0.7) ?? Data()
        }

        let base64 = jpegData.base64EncodedString()

        return Self(
            id: UUID().uuidString,
            thumbnail: thumb,
            attachment: ImageAttachment(data: base64, mimeType: "image/jpeg")
        )
    }

    /// Downsample to fit within maxDimension, preserving aspect ratio.
    private static func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(maxDimension / size.width, maxDimension / size.height)
        if scale >= 1.0 { return image }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
