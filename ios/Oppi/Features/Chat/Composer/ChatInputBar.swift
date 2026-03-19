import Foundation
import PhotosUI
import SwiftUI
import UIKit

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
    @Binding var pendingImages: [PendingImage]
    @Binding var pendingFiles: [PendingFileReference]
    var contextPills: [ContextPill] = []
    var onContextPillTap: ((ContextPill) -> Void)?
    let isBusy: Bool
    @Binding var busyStreamingBehavior: StreamingBehavior
    let isSending: Bool
    let sendProgressText: String?
    let isStopping: Bool
    var voiceInputManager: VoiceInputManager?
    let showForceStop: Bool
    let isForceStopInFlight: Bool
    let slashCommands: [SlashCommand]
    let fileSuggestions: [FileSuggestion]
    let onFileSuggestionQuery: ((String?) -> Void)?
    let onSend: () -> Void
    let onStop: () -> Void
    let onForceStop: () -> Void
    let onExpand: () -> Void
    let externalFocusRequestID: Int
    let appliesOuterPadding: Bool
    @ViewBuilder let actionRow: () -> ActionRow

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var inlineVisualLineCount = 1

    /// Text in the field before voice recording started.
    /// Used to prepend existing text when streaming transcription.
    @State private var textBeforeRecording: String?

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
    private let actionVisualDiameter: CGFloat = 32
    private let expandVisualDiameter: CGFloat = 28
    private let composerHorizontalPadding: CGFloat = 12

    private var composerInputFont: UIFont {
        .preferredFont(forTextStyle: .body)
    }

    private var composerPlaceholderFont: Font { .body }
    private var composerAutocorrectionEnabled: Bool { true }

    private var canSend: Bool {
        let hasImages = !pendingImages.isEmpty
        let hasFiles = !pendingFiles.isEmpty
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || hasImages || hasFiles
    }

    private var accentColor: Color { .themeBlue }

    private var composerPlaceholder: String {
        guard isBusy else { return "Message…" }
        return busyStreamingBehavior == .steer ? "Steer agent…" : "Queue follow-up…"
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
        (canSend || isSending) ? .white : .themeComment
    }

    private var autocompleteContext: ComposerAutocompleteContext {
        guard !isBusy else {
            return .none
        }
        return ComposerAutocomplete.context(for: text)
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
        (pendingImages.isEmpty && pendingFiles.isEmpty) ? inlineMaxLines : inlineMaxLinesWithImages
    }

    /// Show manual expand only when input is getting long.
    private var showsExpandButton: Bool {
        inlineVisualLineCount >= expandVisibilityLineThreshold
            || (!pendingImages.isEmpty && inlineVisualLineCount >= inlineMaxLinesWithImages)
    }

    /// Slack-style inline controls row: hidden until composer is active.
    private var showsComposerActionRow: Bool {
        isBusy || isInputFocused || !pendingImages.isEmpty || !pendingFiles.isEmpty
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

    var body: some View {
        VStack(spacing: 8) {
            if showForceStop {
                forceStopButton
            }

            if !slashSuggestions.isEmpty {
                SlashCommandSuggestionList(suggestions: slashSuggestions, onSelect: insertSlashCommand)
            }

            if !fileSuggestions.isEmpty, case .atFile = autocompleteContext {
                FileSuggestionList(suggestions: fileSuggestions, onSelect: insertFileSuggestion)
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
            notifyFileSuggestionContext(for: newValue)
        }
        .onChange(of: photoSelection) { _, items in
            loadSelectedPhotos(items)
        }
        .onChange(of: externalFocusRequestID) { _, _ in
            suppressKeyboard = false
            focusRequestID += 1
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
                    source: "inline_keyboard_change"
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

    private var composerCapsule: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Context pill strip (display-only, review session context)
            if !contextPills.isEmpty {
                contextPillStrip
                    .padding(.horizontal, composerHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            // Image strip inside capsule
            if !pendingImages.isEmpty {
                imageStrip
                    .padding(.horizontal, composerHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            // File reference pills
            if !pendingFiles.isEmpty {
                filePillStrip
                    .padding(.horizontal, composerHorizontalPadding)
                    .padding(.top, pendingImages.isEmpty ? 8 : 2)
                    .padding(.bottom, 4)
            }

            // Text row with mic + text + send/stop
            HStack(alignment: .bottom, spacing: 6) {
                if ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager {
                    inlineMicButton(manager: manager)
                        .fixedSize()
                }

                ZStack(alignment: .leading) {
                    if text.isEmpty {
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
                        maxLines: effectiveMaxLines,
                        autocorrectionEnabled: composerAutocorrectionEnabled,
                        onPasteImages: handlePastedImages,
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
                        onKeyboardRestoreRequest: handleKeyboardRestore,
                        accessibilityIdentifier: "chat.input",
                        keyboardLanguage: $keyboardLanguage
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                primaryActionButton
                    .fixedSize()
            }
            .padding(.horizontal, composerHorizontalPadding)
            .padding(.vertical, 7)

            if showsComposerActionRow {
                HStack(spacing: 6) {
                    attachButton

                    if !isBusy {
                        slashActionButton
                        atFileActionButton
                    }

                    if isBusy {
                        busyModeSelector
                    }

                    actionRow()
                }
                .padding(.horizontal, composerHorizontalPadding)
                .padding(.top, 2)
                .padding(.bottom, 7)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minHeight: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if showsExpandButton {
                expandButton
                    .padding(.top, 4)
                    .padding(.trailing, composerHorizontalPadding)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showsComposerActionRow)
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

    private var contextPillStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(contextPills) { pill in
                    contextPillView(pill)
                }
            }
        }
    }

    private func contextPillView(_ pill: ContextPill) -> some View {
        let icon = FileIcon.forPath(pill.path)
        let label = HStack(spacing: 4) {
            Image(systemName: icon.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(icon.color)

            Text(pill.displayTitle)
                .font(.caption2.monospaced())
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .fixedSize()

            if let subtitle = pill.displaySubtitle {
                Text(subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.themeComment.opacity(0.1), in: Capsule())

        return Group {
            if let onContextPillTap {
                Button { onContextPillTap(pill) } label: { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
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
        }
    }

    private var filePillStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pendingFiles) { file in
                    filePillView(file)
                }
            }
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

    private var slashActionButton: some View {
        Button {
            text += "/"
            focusRequestID += 1
        } label: {
            Text("/")
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(.themeFg)
                .frame(width: 28, height: 28)
                .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var atFileActionButton: some View {
        Button {
            if !text.isEmpty, !text.hasSuffix(" "), !text.hasSuffix("\n") {
                text += " "
            }
            text += "@"
            focusRequestID += 1
        } label: {
            Text("@")
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(.themeFg)
                .frame(width: 28, height: 28)
                .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var expandButton: some View {
        Button(action: onExpand) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
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
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
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
        let engineBadge = micEngineBadge(for: manager)

        return Button {
            Task {
                switch manager.state {
                case .recording:
                    await manager.stopRecording()
                    textBeforeRecording = nil
                    // Keep keyboard suppressed — user tapping the text field
                    // will restore it via handleKeyboardRestore()
                case .preparingModel:
                    await manager.cancelRecording()
                    textBeforeRecording = nil
                    suppressKeyboard = false
                case .idle:
                    // Capture text prefix — add space if there's existing content
                    let current = text
                    if current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") {
                        textBeforeRecording = current
                    } else {
                        textBeforeRecording = current + " "
                    }
                    // Show cursor without keyboard — keyboard appears on text field tap
                    suppressKeyboard = true
                    focusRequestID += 1
                    do {
                        try await manager.startRecording(
                            keyboardLanguage: keyboardLanguage,
                            source: "inline_mic_tap"
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
                diameter: actionVisualDiameter
            )
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .accessibilityIdentifier("chat.voiceInput")
        .accessibilityLabel(accessibilityLabel(isRecording: isRecording, isPreparing: isPreparing))
        .accessibilityValue(voiceRouteAccessibilityValue(for: manager))
    }

    private var stopActionButton: some View {
        Button(action: onStop) {
            ZStack {
                Circle().fill(isStopping ? Color.themeOrange : Color.themeRed)
                Circle().stroke((isStopping ? Color.themeOrange : Color.themeRed).opacity(0.9), lineWidth: 1)

                if isStopping {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
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

    private func handleSend() {
        guard !isSending else { return }

        // Stop voice recording setup/session before sending so transcript updates
        // don't repopulate the text field after it's cleared.
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
            }
        }

        onSend()
    }

    private func handleAlternateSend() {
        guard !isSending else { return }

        if isBusy {
            busyStreamingBehavior = .followUp
        }

        handleSend()
    }

    /// User tapped the text field while keyboard was suppressed — stop any
    /// active recording and restore the keyboard so they can type.
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
            DispatchQueue.global(qos: .userInitiated).async {
                let pending = PendingImage.from(image)
                DispatchQueue.main.async {
                    pendingImages.append(pending)
                }
            }
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
        // Reset selection so the same photo can be picked again
        photoSelection = []
    }

    private func addCapturedImage(_ image: UIImage) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pending = PendingImage.from(image)
            DispatchQueue.main.async {
                pendingImages.append(pending)
            }
        }
    }

    private func removeImage(_ id: String) {
        pendingImages.removeAll { $0.id == id }
    }
}

// MARK: - PendingImage

/// An image queued for sending. Holds the thumbnail for display and
/// the compressed JPEG data + base64 for the wire protocol.
struct PendingImage: Identifiable, Sendable {
    let id: String
    let thumbnail: UIImage
    let attachment: ImageAttachment

    /// Create from a UIImage. Resizes large images and compresses to JPEG.
    static func from(_ image: UIImage) -> Self {
        let resized = downsample(image, maxDimension: 1568)
        let jpegData = resized.jpegData(compressionQuality: 0.85) ?? Data()
        let base64 = jpegData.base64EncodedString()
        let thumb = downsample(image, maxDimension: 112)

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
