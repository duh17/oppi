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
    let isBusy: Bool
    let isSending: Bool
    let sendProgressText: String?
    let isStopping: Bool
    var dictationService: DictationService?
    let showForceStop: Bool
    let isForceStopInFlight: Bool
    let slashCommands: [SlashCommand]
    let onSend: () -> Void
    let onBash: (String) -> Void
    let onStop: () -> Void
    let onForceStop: () -> Void
    let onExpand: () -> Void
    let appliesOuterPadding: Bool
    var thinkingBorderColor: Color = .themeComment
    @ViewBuilder let actionRow: () -> ActionRow

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var inlineVisualLineCount = 1

    private let inlineMaxLines = 8
    private let inlineMaxLinesWithImages = 4
    private let expandVisibilityLineThreshold = 5
    private let actionVisualDiameter: CGFloat = 32
    private let expandVisualDiameter: CGFloat = 28
    private let composerHorizontalPadding: CGFloat = 12

    /// Whether the current input is a bash command (starts with "$ ").
    private var isBashMode: Bool {
        text.hasPrefix("$ ")
    }

    /// The command text without the "$ " prefix.
    private var bashCommand: String {
        String(text.dropFirst(2))
    }

    private var canSend: Bool {
        let hasImages = !pendingImages.isEmpty
        if isBashMode {
            if isBusy { return false }
            return !bashCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || hasImages
    }

    private var accentColor: Color {
        isBashMode ? .themeGreen : .themeBlue
    }

    private var borderColor: Color {
        if isBashMode { return .themeGreen.opacity(0.5) }
        return thinkingBorderColor.opacity(0.5)
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
        guard !isBusy, !isBashMode else {
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

    /// Effective max lines — reduced when images are present to prevent the
    /// capsule from growing tall enough to push the send button off-screen.
    private var effectiveMaxLines: Int {
        pendingImages.isEmpty ? inlineMaxLines : inlineMaxLinesWithImages
    }

    /// Show manual expand only when input is getting long.
    private var showsExpandButton: Bool {
        inlineVisualLineCount >= expandVisibilityLineThreshold
            || (!pendingImages.isEmpty && inlineVisualLineCount >= inlineMaxLinesWithImages)
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

            // Action row: attach (fixed) + pills/controls (trailing)
            HStack(spacing: 6) {
                attachButton
                if ReleaseFeatures.composerDictationEnabled,
                   let dictationService,
                   isDictationEnabled {
                    dictationButton(service: dictationService)
                }
                actionRow()
            }
        }
        .padding(.horizontal, appliesOuterPadding ? 16 : 0)
        .padding(.bottom, appliesOuterPadding ? 8 : 0)
        .onChange(of: text) { _, newValue in
            if newValue.isEmpty {
                inlineVisualLineCount = 1
            }
        }
        .onChange(of: photoSelection) { _, items in
            loadSelectedPhotos(items)
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
            // Image strip inside capsule
            if !pendingImages.isEmpty {
                imageStrip
                    .padding(.horizontal, composerHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            // Text row with send/stop button
            HStack(alignment: .bottom, spacing: 8) {
                if isBashMode {
                    Text("$")
                        .font(.system(.body, design: .monospaced).bold())
                        .foregroundStyle(.themeGreen)
                }

                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(isBusy ? "Steer agent…" : (isBashMode ? "command…" : "Message…"))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.themeComment)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }

                    PastableTextView(
                        text: textFieldBinding,
                        placeholder: "",
                        font: .monospacedSystemFont(ofSize: 17, weight: .regular),
                        textColor: UIColor(Color.themeFg),
                        tintColor: UIColor(isBusy ? Color.themePurple : accentColor),
                        maxLines: effectiveMaxLines,
                        onPasteImages: handlePastedImages,
                        onCommandEnter: handleSend,
                        onOverflowChange: nil,
                        onLineCountChange: handleInlineLineCountChange,
                        onFocusChange: nil,
                        onDictationStateChange: nil,
                        focusRequestID: 0,
                        blurRequestID: 0,
                        dictationRequestID: 0,
                        accessibilityIdentifier: "chat.input"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                primaryActionButton
                    .fixedSize()
            }
            .padding(.horizontal, composerHorizontalPadding)
            .padding(.vertical, 7)
        }
        .frame(minHeight: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeBgHighlight, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if showsExpandButton {
                expandButton
                    .padding(.top, 4)
                    .padding(.trailing, composerHorizontalPadding)
            }
        }
    }

    private var attachButton: some View {
        Menu {
            PhotosPicker(
                selection: $photoSelection,
                maxSelectionCount: 5,
                matching: .images
            ) {
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
                .foregroundStyle(isBashMode ? .themeComment : .themeFg)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    Capsule()
                        .fill(Color.themeComment.opacity(0.18))
                        .overlay(Capsule().stroke(Color.themeComment.opacity(0.25), lineWidth: 0.5))
                }
        }
        .disabled(isBashMode)
    }

    private var isDictationEnabled: Bool {
        DictationConfig.load().enabled
    }

    private func dictationButton(service: DictationService) -> some View {
        let isRecording = service.state == .recording
        let isProcessing = service.state == .processing

        return Button {
            if isRecording {
                service.stop()
            } else if service.state == .idle || service.isErrorState {
                let config = DictationConfig.load()
                service.onTranscription = { fullText in
                    text = fullText
                }
                service.start(config: config)
            }
        } label: {
            Group {
                if isProcessing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: isRecording ? "mic.fill" : "mic")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isRecording ? .themeRed : .themeFg)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(isRecording ? Color.themeRed.opacity(0.18) : Color.themeComment.opacity(0.18))
                    .overlay(
                        Capsule().stroke(
                            isRecording ? Color.themeRed.opacity(0.4) : Color.themeComment.opacity(0.25),
                            lineWidth: 0.5
                        )
                    )
            }
        }
        .disabled(isProcessing || isBusy)
        .accessibilityIdentifier("chat.dictation")
        .accessibilityLabel(isRecording ? "Stop dictation" : "Start dictation")
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
                    Image(systemName: isBashMode ? "terminal.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(sendActionForegroundColor)
                }
            }
            .frame(width: actionVisualDiameter, height: actionVisualDiameter)
        }
        .disabled(!canSend || isSending)
        .accessibilityIdentifier("chat.send")
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

    private func handleSend() {
        guard !isSending else { return }

        if isBashMode {
            let cmd = bashCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return }
            onBash(cmd)
        } else {
            // Keyboard stays open during send. Stability input traits
            // (autocorrect/candidates disabled) prevent UITextInput from
            // generating layout-interfering updates. Dismissing keyboard
            // here caused a SafeArea resize -> LazyVStack full placement
            // cascade (2s+ hang). Let .scrollDismissesKeyboard handle it.
            onSend()
        }
    }

    private func insertSlashCommand(_ command: SlashCommand) {
        text = ComposerAutocomplete.insertSlashCommand(command, into: text)
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
