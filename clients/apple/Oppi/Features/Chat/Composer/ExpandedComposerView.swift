import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Full-screen composer for long-form text input.
///
/// Opens as a sheet from `ChatInputBar` when the user taps the expand button.
/// Shares text/image bindings with the inline input so edits carry over in both
/// directions. Supports bash mode ($ prefix), image attachments, and paste.
///
/// Layout:
/// ```
/// ┌─────────────────────────────┐
/// │ Cancel    Compose     Send  │  toolbar
/// ├─────────────────────────────┤
/// │ [bash mode banner]          │  conditional
/// ├─────────────────────────────┤
/// │                             │
/// │  Full-height text editor    │
/// │  (scrollable)               │
/// │                             │
/// ├─────────────────────────────┤
/// │ [image strip]               │  conditional
/// │ [+]             42w · 256c  │  attach + stats
/// └─────────────────────────────┘
/// ```
struct ExpandedComposerView: View {
    @Binding var text: String
    @Binding var textBeforeRecording: String?
    @Binding var pendingAttachments: [PendingAttachment]
    @Binding var pendingRepoPointers: [PendingFileReference]
    let isBusy: Bool
    let busyStreamingBehavior: StreamingBehavior
    let slashCommands: [SlashCommand]
    let fileSuggestions: [FileSuggestion]
    let onFileSuggestionQuery: ((String?) -> Void)?
    let session: Session?
    var modelOverride: String? = nil
    let thinkingLevel: ThinkingLevel
    var voiceInputManager: VoiceInputManager?
    var onPrepareVoiceInput: ((VoiceInputManager) async throws -> Void)? = nil
    let onSend: () -> Void
    let onModelTap: () -> Void
    let onThinkingSelect: (ThinkingLevel) -> Void
    var onSaveThinkingAsDefault: (() -> Void)? = nil
    var supportedThinkingLevels: [ThinkingLevel] = ThinkingLevel.allCases
    var titleOverride: String? = nil
    var headerMessage: String? = nil
    var cancelTitle = "Done"
    var submitTitle = "Send"
    var showsAttachmentControls = true
    var showsVoiceInputControl = true
    var showsSessionToolbar = true
    var showsCounters = true
    var usesCommandPrefixMode = true
    var allowsEmptySubmit = false
    var isSubmitInFlight = false
    var autoFocusOnAppear = false
    var dismissesOnCancel = true
    var dismissesOnSubmit = true
    var preservesVoiceInputOnDismiss = false
    var editorAccessibilityIdentifier: String? = nil
    var cancelAccessibilityIdentifier: String? = nil
    var submitAccessibilityIdentifier: String? = nil
    var onCancel: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false

    /// BCP 47 language of the active keyboard (e.g. "zh-Hans", "en-US").
    /// Updated by FullSizeTextView while editing.
    @State private var keyboardLanguage: String?

    /// Bumped to programmatically focus the text view for voice mode.
    @State private var focusRequestID = 0

    /// Mirrors inline composer behavior: keep the cursor visible during voice
    /// capture while hiding the keyboard until the user taps back into typing.
    @State private var suppressKeyboard = false

    /// Prevents double-submit/cancel while final dictation text is being committed.
    @State private var isHandlingVoiceLifecycle = false

    private var composerDisplayText: String {
        ComposerShared.currentComposerText(
            storedText: text,
            textBeforeRecording: textBeforeRecording,
            manager: voiceInputManager,
            owner: .expandedComposer
        )
    }

    private var ownsVoiceInput: Bool {
        ComposerShared.ownsVoiceInput(voiceInputManager, owner: .expandedComposer)
    }

    private var canSend: Bool {
        let hasImages = showsAttachmentControls && pendingAttachments.contains { $0.source == .image }
        let hasFiles = showsAttachmentControls
            && (pendingAttachments.contains { $0.source != .image } || !pendingRepoPointers.isEmpty)
        let hasText = !composerDisplayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || hasImages || hasFiles
    }

    private var canSubmit: Bool {
        !isSubmitInFlight && !isHandlingVoiceLifecycle && (allowsEmptySubmit || canSend)
    }

    private var accentColor: Color { .themeBlue }
    private var composerInputFont: UIFont { .preferredFont(forTextStyle: .body) }
    private var composerAutocorrectionEnabled: Bool { true }

    private var autocompleteContext: ComposerAutocompleteContext {
        ComposerAutocomplete.context(for: text, isBusy: isBusy)
    }

    private var slashSuggestions: [SlashCommand] {
        guard case .slash(let query) = autocompleteContext else {
            return []
        }
        return ComposerAutocomplete.slashSuggestions(query: query, commands: slashCommands)
    }

    /// Text binding that strips the "$ " prefix for bash mode display when used as the chat composer.
    private var textFieldBinding: Binding<String> {
        guard usesCommandPrefixMode else { return $text }
        return ComposerShared.textFieldBinding(text: $text) { composerDisplayText }
    }

    private var correctionRangesForDisplay: [NSRange] {
        return ComposerShared.correctionRanges(
            manager: voiceInputManager,
            textBeforeRecording: textBeforeRecording,
            owner: .expandedComposer
        )
    }

    private var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private var charCount: Int { text.count }

    private var lineCount: Int {
        max(1, text.components(separatedBy: "\n").count)
    }

    private var expandedTitle: String {
        if let title = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        guard isBusy else { return "Compose" }
        return busyStreamingBehavior == .steer ? "Steer Agent" : "Queue Follow-up"
    }

    private var trimmedHeaderMessage: String? {
        guard let message = headerMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return nil
        }
        return message
    }

    private var showsControlRow: Bool {
        showsAttachmentControls
            || (showsVoiceInputControl && ReleaseFeatures.voiceInputEnabled && voiceInputManager != nil)
            || showsSessionToolbar
    }

    private var showsBottomBar: Bool {
        showsControlRow
            || showsCounters
            || (showsAttachmentControls && (!pendingAttachments.isEmpty || !pendingRepoPointers.isEmpty))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let trimmedHeaderMessage {
                    Text(trimmedHeaderMessage)
                        .font(.body)
                        .foregroundStyle(.themeFg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.themeBgDark)
                }

                FullSizeTextView(
                    text: textFieldBinding,
                    keyboardLanguage: $keyboardLanguage,
                    font: composerInputFont,
                    textColor: UIColor(Color.themeFg),
                    tintColor: UIColor(accentColor),
                    volatileSuffixLength: ComposerShared.volatileSuffixLength(manager: voiceInputManager, owner: .expandedComposer),
                    correctionRanges: correctionRangesForDisplay,
                    autocorrectionEnabled: composerAutocorrectionEnabled,
                    onPasteImages: { images in
                        guard showsAttachmentControls else { return }
                        ComposerShared.handlePastedImages(images, into: $pendingAttachments)
                    },
                    onCommandEnter: handleSend,
                    onAlternateEnter: handleSend,
                    autoFocusOnAppear: autoFocusOnAppear,
                    focusRequestID: focusRequestID,
                    suppressKeyboard: suppressKeyboard,
                    allowKeyboardRestoreOnTap: true,
                    onKeyboardRestoreRequest: {
                        ComposerShared.handleKeyboardRestore(
                            suppressKeyboard: $suppressKeyboard,
                            textBeforeRecording: $textBeforeRecording,
                            voiceInputManager: voiceInputManager,
                            expectedOwner: .expandedComposer
                        )
                    },
                    accessibilityIdentifier: editorAccessibilityIdentifier ?? "expanded.composer.editor"
                )

                if !slashSuggestions.isEmpty {
                    SlashCommandSuggestionList(suggestions: slashSuggestions) { command in
                        ComposerShared.insertSlashCommand(command, into: $text)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                if !fileSuggestions.isEmpty, case .atFile = autocompleteContext {
                    FileSuggestionList(suggestions: fileSuggestions) { suggestion in
                        ComposerShared.insertFileSuggestion(suggestion, text: $text, pendingRepoPointers: $pendingRepoPointers)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                if showsBottomBar {
                    Divider().overlay(Color.themeComment.opacity(0.2))
                    bottomBar
                }
            }
            .background(.themeBg)
            .navigationTitle(expandedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.themeBgDark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) {
                        handleCancel()
                    }
                    .disabled(isSubmitInFlight || isHandlingVoiceLifecycle)
                    .foregroundStyle(.themeFgDim)
                    .accessibilityIdentifier(cancelAccessibilityIdentifier ?? "expanded.composer.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        handleSend()
                    } label: {
                        Text(submitTitle)
                            .fontWeight(.semibold)
                    }
                    .disabled(!canSubmit)
                    .foregroundStyle(canSubmit ? accentColor : .themeComment)
                    .accessibilityIdentifier(submitAccessibilityIdentifier ?? "expanded.composer.submit")
                }
            }
        }
        .preferredColorScheme(ThemeRuntimeState.currentThemeID().preferredColorScheme)
        .onAppear {
            guard ComposerShared.shouldSuppressKeyboardForActiveVoiceInput(
                voiceInputManager,
                owner: .expandedComposer
            ) else { return }
            suppressKeyboard = true
            focusRequestID &+= 1
        }
        .onChange(of: text) { _, newText in
            ComposerShared.notifyFileSuggestionContext(
                for: newText,
                isBusy: isBusy,
                onFileSuggestionQuery: onFileSuggestionQuery
            )
        }
        .onChange(of: photoSelection) { _, items in
            ComposerShared.loadSelectedPhotos(items, into: $pendingAttachments)
            photoSelection = []
        }
        .onChange(of: voiceInputManager?.transcriptPresentationRevision) { _, _ in
            guard let prefix = textBeforeRecording, let manager = voiceInputManager else { return }
            guard ComposerShared.ownsVoiceInput(manager, owner: .expandedComposer) else { return }
            text = prefix + manager.currentTranscript
        }
        .onChange(of: keyboardLanguage) { _, newLanguage in
            guard ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager else { return }
            guard AppPreferences.Keyboard.normalize(newLanguage) != nil else { return }
            Task {
                await manager.prewarm(
                    keyboardLanguage: newLanguage,
                    source: "expanded_keyboard_change"
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

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if showsAttachmentControls, !pendingAttachments.isEmpty {
                attachmentStrip
            }

            if showsAttachmentControls, !pendingRepoPointers.isEmpty {
                filePillStrip
            }

            if showsControlRow {
                HStack(spacing: 6) {
                    if showsAttachmentControls {
                        attachMenu
                    }

                    if showsVoiceInputControl, ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager {
                        micButton(manager: manager)
                    }

                    Spacer(minLength: 0)

                    if showsSessionToolbar {
                        SessionToolbar(
                            session: session,
                            modelOverride: modelOverride,
                            thinkingLevel: thinkingLevel,
                            supportedThinkingLevels: supportedThinkingLevels,
                            onModelTap: onModelTap,
                            onThinkingSelect: onThinkingSelect,
                            onSaveThinkingAsDefault: onSaveThinkingAsDefault
                        )
                    }
                }
                .padding(.horizontal, 16)
            }

            if showsCounters {
                HStack {
                    Spacer()

                    if charCount > 0 {
                        HStack(spacing: 8) {
                            Text("\(lineCount)L")
                            Text("\(wordCount)W")
                            Text("\(charCount)C")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.themeComment)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 8)
        .background(.themeBgDark)
    }

    private var attachmentStrip: some View {
        ComposerShared.attachmentStrip(
            pendingAttachments: $pendingAttachments,
            horizontalPadding: 16
        )
    }

    private var filePillStrip: some View {
        ComposerShared.filePillStrip(
            pendingRepoPointers: $pendingRepoPointers,
            horizontalPadding: 16
        )
    }

    private var attachMenu: some View {
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
            ZStack {
                Circle().fill(Color.themeBgHighlight)
                Circle().stroke(Color.themeComment.opacity(0.35), lineWidth: 1)

                Image(systemName: "plus")
                    .font(.appButton)
                    .foregroundStyle(.themeComment)
            }
            .frame(width: 32, height: 32)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: ComposerShared.maxPhotoSelectionCount,
            matching: .images,
            preferredItemEncoding: .current
        )
    }

    // MARK: - Mic Button

    private func micButton(manager: VoiceInputManager) -> some View {
        let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .expandedComposer)

        return Button {
            Task {
                guard ComposerShared.canControlVoiceInput(manager, owner: .expandedComposer) else { return }
                switch manager.state {
                case .recording:
                    await ComposerShared.stopVoiceInput(
                        manager: manager,
                        text: $text,
                        textBeforeRecording: $textBeforeRecording
                    )
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
                            owner: .expandedComposer,
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
                diameter: 32
            )
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isEnabled)
        .accessibilityIdentifier("expanded.voiceInput")
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }

    // MARK: - Actions

    private func handleSend() {
        guard canSubmit else { return }
        isHandlingVoiceLifecycle = true
        Task { @MainActor in
            await ComposerShared.finishOwnedVoiceInputBeforeSubmit(
                manager: voiceInputManager,
                owner: .expandedComposer,
                text: $text,
                textBeforeRecording: $textBeforeRecording,
                suppressKeyboard: $suppressKeyboard
            )
            isHandlingVoiceLifecycle = false
            onSend()
            if dismissesOnSubmit {
                dismiss()
            }
        }
    }

    private func handleCancel() {
        guard !isSubmitInFlight, !isHandlingVoiceLifecycle else { return }
        isHandlingVoiceLifecycle = true
        Task { @MainActor in
            if !preservesVoiceInputOnDismiss {
                await ComposerShared.cancelOwnedVoiceInput(
                    manager: voiceInputManager,
                    owner: .expandedComposer,
                    textBeforeRecording: $textBeforeRecording,
                    suppressKeyboard: $suppressKeyboard
                )
            }
            isHandlingVoiceLifecycle = false
            onCancel?()
            if dismissesOnCancel {
                dismiss()
            }
        }
    }
}
