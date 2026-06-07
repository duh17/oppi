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
        let hasImages = pendingAttachments.contains { $0.source == .image }
        let hasFiles = pendingAttachments.contains { $0.source != .image } || !pendingRepoPointers.isEmpty
        let hasText = !composerDisplayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || hasImages || hasFiles
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

    /// Text binding that strips the "$ " prefix for bash mode display.
    private var textFieldBinding: Binding<String> {
        ComposerShared.textFieldBinding(text: $text) { composerDisplayText }
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
        guard isBusy else { return "Compose" }
        return busyStreamingBehavior == .steer ? "Steer Agent" : "Queue Follow-up"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                FullSizeTextView(
                    text: textFieldBinding,
                    keyboardLanguage: $keyboardLanguage,
                    font: composerInputFont,
                    textColor: UIColor(Color.themeFg),
                    tintColor: UIColor(accentColor),
                    volatileSuffixLength: ComposerShared.volatileSuffixLength(manager: voiceInputManager, owner: .expandedComposer),
                    correctionRanges: correctionRangesForDisplay,
                    autocorrectionEnabled: composerAutocorrectionEnabled,
                    onPasteImages: { ComposerShared.handlePastedImages($0, into: $pendingAttachments) },
                    onCommandEnter: handleSend,
                    onAlternateEnter: handleSend,
                    autoFocusOnAppear: false,
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
                    accessibilityIdentifier: nil
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

                Divider().overlay(Color.themeComment.opacity(0.2))

                bottomBar
            }
            .background(Color.themeBg)
            .navigationTitle(expandedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.themeBgDark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.themeFgDim)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        handleSend()
                    } label: {
                        Text("Send")
                            .fontWeight(.semibold)
                    }
                    .disabled(!canSend)
                    .foregroundStyle(canSend ? accentColor : .themeComment)
                }
            }
        }
        .preferredColorScheme(ThemeRuntimeState.currentThemeID().preferredColorScheme)
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
            if !pendingAttachments.isEmpty {
                attachmentStrip
            }

            if !pendingRepoPointers.isEmpty {
                filePillStrip
            }

            HStack(spacing: 6) {
                attachMenu

                if ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager {
                    micButton(manager: manager)
                }

                Spacer(minLength: 0)

                SessionToolbar(
                    session: session,
                    modelOverride: modelOverride,
                    thinkingLevel: thinkingLevel,
                    onModelTap: onModelTap,
                    onThinkingSelect: onThinkingSelect
                )
            }
            .padding(.horizontal, 16)

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
        .padding(.top, 8)
        .background(Color.themeBgDark)
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
            maxSelectionCount: 5,
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
        // Stop voice recording setup/session before sending
        if let manager = voiceInputManager,
           ComposerShared.ownsVoiceInput(manager, owner: .expandedComposer),
           manager.isRecording || manager.isPreparing {
            textBeforeRecording = nil
            Task {
                if manager.isRecording {
                    await manager.stopRecording()
                } else {
                    await manager.cancelRecording()
                }
            }
        }
        onSend()
        dismiss()
    }
}
