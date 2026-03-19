import PhotosUI
import SwiftUI
import UIKit

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
    @Binding var pendingImages: [PendingImage]
    @Binding var pendingFiles: [PendingFileReference]
    let isBusy: Bool
    let busyStreamingBehavior: StreamingBehavior
    let slashCommands: [SlashCommand]
    let fileSuggestions: [FileSuggestion]
    let onFileSuggestionQuery: ((String?) -> Void)?
    let session: Session?
    let thinkingLevel: ThinkingLevel
    var voiceInputManager: VoiceInputManager?
    let onSend: () -> Void
    let onModelTap: () -> Void
    let onThinkingSelect: (ThinkingLevel) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false

    /// BCP 47 language of the active keyboard (e.g. "zh-Hans", "en-US").
    /// Updated by FullSizeTextView while editing.
    @State private var keyboardLanguage: String?

    /// Text in the field before voice recording started.
    @State private var textBeforeRecording: String?

    /// Bumped to programmatically focus the text view for voice mode.
    @State private var focusRequestID = 0

    /// Mirrors inline composer behavior: keep the cursor visible during voice
    /// capture while hiding the keyboard until the user taps back into typing.
    @State private var suppressKeyboard = false

    private var canSend: Bool {
        let hasImages = !pendingImages.isEmpty
        let hasFiles = !pendingFiles.isEmpty
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || hasImages || hasFiles
    }

    private var accentColor: Color { .themeBlue }
    private var composerInputFont: UIFont { .preferredFont(forTextStyle: .body) }
    private var composerAutocorrectionEnabled: Bool { true }

    private var autocompleteContext: ComposerAutocompleteContext {
        guard !isBusy else { return .none }
        return ComposerAutocomplete.context(for: text)
    }

    private var slashSuggestions: [SlashCommand] {
        guard case .slash(let query) = autocompleteContext else {
            return []
        }
        return ComposerAutocomplete.slashSuggestions(query: query, commands: slashCommands)
    }

    /// Text binding that strips the "$ " prefix for bash mode display.
    private var textFieldBinding: Binding<String> {
        Binding(
            get: {
                if text.hasPrefix("$ ") {
                    return String(text.dropFirst(2))
                }
                return text
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
                    autocorrectionEnabled: composerAutocorrectionEnabled,
                    onPasteImages: handlePastedImages,
                    onCommandEnter: handleSend,
                    onAlternateEnter: handleSend,
                    autoFocusOnAppear: false,
                    focusRequestID: focusRequestID,
                    suppressKeyboard: suppressKeyboard,
                    allowKeyboardRestoreOnTap: true,
                    onKeyboardRestoreRequest: handleKeyboardRestore
                )

                if !slashSuggestions.isEmpty {
                    SlashCommandSuggestionList(suggestions: slashSuggestions, onSelect: insertSlashCommand)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }

                if !fileSuggestions.isEmpty, case .atFile = autocompleteContext {
                    FileSuggestionList(suggestions: fileSuggestions, onSelect: insertFileSuggestion)
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
            notifyFileSuggestionContext(for: newText)
        }
        .onChange(of: photoSelection) { _, items in
            loadSelectedPhotos(items)
        }
        .onChange(of: voiceInputManager?.currentTranscript) { _, newTranscript in
            guard let prefix = textBeforeRecording, let transcript = newTranscript else { return }
            text = prefix + transcript
        }
        .onChange(of: keyboardLanguage) { _, newLanguage in
            guard ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager else { return }
            guard KeyboardLanguageStore.normalize(newLanguage) != nil else { return }
            Task {
                await manager.prewarm(
                    keyboardLanguage: newLanguage,
                    source: "expanded_keyboard_change"
                )
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onCapture: { image in
                    addCapturedImage(image)
                    showCamera = false
                },
                onCancel: {
                    showCamera = false
                }
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Subviews

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !pendingImages.isEmpty {
                imageStrip
            }

            if !pendingFiles.isEmpty {
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

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { pending in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: pending.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.themeComment.opacity(0.3), lineWidth: 1)
                            )

                        Button {
                            removeImage(pending.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .background(Circle().fill(.black.opacity(0.6)))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var filePillStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pendingFiles) { file in
                    filePillView(file)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func filePillView(_ file: PendingFileReference) -> some View {
        let icon = file.isDirectory
            ? FileIcon(symbolName: "folder.fill", color: .themeYellow)
            : FileIcon.forPath(file.path)

        return HStack(spacing: 4) {
            Image(systemName: icon.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(icon.color)

            Text(file.displayName)
                .font(.caption2.monospaced())
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .fixedSize()

            Button {
                removeFile(file.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.themeComment)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.themeComment.opacity(0.1), in: Capsule())
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
        } label: {
            ZStack {
                Circle().fill(Color.themeBgHighlight)
                Circle().stroke(Color.themeComment.opacity(0.35), lineWidth: 1)

                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.themeComment)
            }
            .frame(width: 32, height: 32)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: 5,
            matching: .images
        )
    }

    // MARK: - Mic Button

    private func micButton(manager: VoiceInputManager) -> some View {
        let isRecording = manager.isRecording
        let isPreparing = manager.isPreparing
        let isProcessing = manager.isProcessing
        let engineBadge = micEngineBadge(for: manager)

        return Button {
            Task {
                switch manager.state {
                case .recording:
                    await manager.stopRecording()
                    textBeforeRecording = nil
                case .preparingModel:
                    await manager.cancelRecording()
                    textBeforeRecording = nil
                    suppressKeyboard = false
                case .idle:
                    let current = text
                    if current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") {
                        textBeforeRecording = current
                    } else {
                        textBeforeRecording = current + " "
                    }
                    suppressKeyboard = true
                    focusRequestID += 1
                    do {
                        try await manager.startRecording(
                            keyboardLanguage: keyboardLanguage,
                            source: "expanded_mic_tap"
                        )
                    } catch {
                        textBeforeRecording = nil
                        suppressKeyboard = false
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
                diameter: 32
            )
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .accessibilityIdentifier("expanded.voiceInput")
        .accessibilityLabel(accessibilityLabel(isRecording: isRecording, isPreparing: isPreparing))
        .accessibilityValue(voiceRouteAccessibilityValue(for: manager))
    }

    // MARK: - Actions

    private func micEngineBadge(for manager: VoiceInputManager) -> MicButtonLabel.EngineBadge {
        switch manager.routeIndicator {
        case .auto:
            return .auto
        case .onDevice:
            return .onDevice
        case .remote:
            return .remote
        }
    }

    private func voiceRouteAccessibilityValue(for manager: VoiceInputManager) -> String {
        manager.routeIndicator.accessibilityLabel
    }

    private func accessibilityLabel(isRecording: Bool, isPreparing: Bool) -> String {
        if isRecording {
            return "Stop recording"
        }
        if isPreparing {
            return "Cancel voice input"
        }
        return "Start voice input"
    }

    private func handleSend() {
        // Stop voice recording setup/session before sending
        if let manager = voiceInputManager, manager.isRecording || manager.isPreparing {
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

    /// User tapped back into the composer while voice was active — restore the
    /// keyboard immediately and stop/cancel voice so typing takes over.
    private func handleKeyboardRestore() {
        suppressKeyboard = false
        textBeforeRecording = nil
        if let manager = voiceInputManager, manager.isRecording || manager.isPreparing {
            Task {
                if manager.isRecording {
                    await manager.stopRecording()
                } else {
                    await manager.cancelRecording()
                }
            }
        }
    }

    private func insertSlashCommand(_ command: SlashCommand) {
        text = ComposerAutocomplete.insertSlashCommand(command, into: text)
    }

    private func insertFileSuggestion(_ suggestion: FileSuggestion) {
        // Add as pill instead of inline text. Remove the @query token from text.
        if let tokenRange = ComposerAutocomplete.activeAtTokenRange(in: text) {
            text.replaceSubrange(tokenRange, with: "")
        }

        let ref = PendingFileReference(path: suggestion.path, isDirectory: suggestion.isDirectory)
        if !pendingFiles.contains(where: { $0.path == ref.path }) {
            pendingFiles.append(ref)
        }

        // If it's a directory, re-trigger autocomplete for its contents
        if suggestion.isDirectory {
            text += "@\(suggestion.path)"
        }
    }

    private func removeFile(_ id: String) {
        pendingFiles.removeAll { $0.id == id }
    }

    private func notifyFileSuggestionContext(for newText: String) {
        let ctx = ComposerAutocomplete.context(for: newText)
        if case .atFile(let query) = ctx, !isBusy {
            onFileSuggestionQuery?(query)
        } else {
            onFileSuggestionQuery?(nil)
        }
    }

    private func handlePastedImages(_ images: [UIImage]) {
        for image in images {
            let pending = PendingImage.from(image)
            pendingImages.append(pending)
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        for item in items {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                guard let uiImage = UIImage(data: data) else { return }
                let pending = PendingImage.from(uiImage)
                await MainActor.run {
                    pendingImages.append(pending)
                }
            }
        }
        photoSelection = []
    }

    private func addCapturedImage(_ image: UIImage) {
        let pending = PendingImage.from(image)
        pendingImages.append(pending)
    }

    private func removeImage(_ id: String) {
        pendingImages.removeAll { $0.id == id }
    }
}
