import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// Chat input bar with text input, image attachments, bash mode, and steer/stop controls.
///
/// **Layout**: `[ + button ][ $ indicator (bash) ][ TextField ][ send/stop ]`
///
/// The `+` button opens a menu with Photo Library and Camera options.
/// Selected images appear as a horizontal thumbnail strip above the text field.
///
/// **Idle**: Send button routes through `onSend` (prompt).
/// **Busy**: TextField stays enabled for steering messages. Purple send
/// button appears when text is entered, routed through `onSend` (caller
/// decides prompt vs steer). Stop button always visible.
/// After 5s of stopping, shows Force Stop option.
///
/// Bash mode: when input starts with "$ ", the bar shows a green shell
/// prompt and routes the command through `onBash` instead of `onSend`.
/// Bash is disabled while busy — agent owns the workspace.
struct ChatInputBar: View {
    @Binding var text: String
    @Binding var pendingImages: [PendingImage]
    let isBusy: Bool
    let isSending: Bool
    let sendProgressText: String?
    let isStopping: Bool
    let showForceStop: Bool
    let isForceStopInFlight: Bool
    let slashCommands: [SlashCommand]
    let onSend: () -> Void
    let onBash: (String) -> Void
    let onStop: () -> Void
    let onForceStop: () -> Void
    let onExpand: () -> Void
    let appliesOuterPadding: Bool

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showCamera = false

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
        isBashMode ? .tokyoGreen : .tokyoBlue
    }

    private var borderColor: Color {
        if isBashMode { return .tokyoGreen.opacity(0.5) }
        if isBusy { return .tokyoPurple.opacity(0.5) }
        return .tokyoComment.opacity(0.35)
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

            VStack(spacing: 0) {
                // Image thumbnail strip
                if !pendingImages.isEmpty {
                    imageStrip
                }

                if !slashSuggestions.isEmpty {
                    SlashCommandSuggestionList(suggestions: slashSuggestions, onSelect: insertSlashCommand)
                        .padding(.horizontal, 12)
                        .padding(.top, pendingImages.isEmpty ? 10 : 6)
                        .padding(.bottom, 6)
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
                    .foregroundStyle(.tokyoComment)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, pendingImages.isEmpty ? 10 : 6)
                    .padding(.bottom, 2)
                }

                // Input row
                HStack(spacing: 8) {
                    attachButton

                    if isBashMode {
                        Text("$")
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundStyle(.tokyoGreen)
                    }

                    ZStack(alignment: .leading) {
                        // Placeholder
                        if text.isEmpty {
                            Text(isBusy ? "Steer agent…" : (isBashMode ? "command…" : "Message…"))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tokyoComment)
                                .allowsHitTesting(false)
                        }

                        PastableTextView(
                            text: textFieldBinding,
                            placeholder: "",
                            font: .monospacedSystemFont(ofSize: 17, weight: .regular),
                            textColor: UIColor(Color.tokyoFg),
                            tintColor: UIColor(isBusy ? Color.tokyoPurple : accentColor),
                            maxLines: 8,
                            onPasteImages: handlePastedImages,
                            accessibilityIdentifier: "chat.input"
                        )
                    }

                    expandButton

                    actionButtons
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color.tokyoBgHighlight, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .padding(.horizontal, appliesOuterPadding ? 16 : 0)
        .padding(.bottom, appliesOuterPadding ? 8 : 0)
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
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(isBashMode ? .tokyoComment : .tokyoBlue)
                .symbolRenderingMode(.hierarchical)
        }
        .disabled(isBashMode)
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
                                    .stroke(Color.tokyoComment.opacity(0.3), lineWidth: 1)
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
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    private var expandButton: some View {
        Button(action: onExpand) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.footnote)
                .foregroundStyle(.tokyoComment)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if isBusy {
            if isSending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.tokyoPurple)
                    .frame(width: 36, height: 36)
            } else if canSend {
                Button(action: handleSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tokyoPurple)
                }
                .frame(width: 36, height: 36)
                .accessibilityIdentifier("chat.send")
            }

            Button(action: onStop) {
                if isStopping {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.tokyoOrange)
                } else {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.tokyoRed)
                }
            }
            .disabled(isStopping)
            .frame(width: 36, height: 36)
            .accessibilityIdentifier("chat.stop")
        } else {
            Button(action: handleSend) {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accentColor)
                } else {
                    Image(systemName: isBashMode ? "terminal.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? accentColor : .tokyoComment)
                }
            }
            .disabled(!canSend || isSending)
            .frame(width: 36, height: 36)
            .accessibilityIdentifier("chat.send")
        }
    }

    private var forceStopButton: some View {
        Button(role: .destructive) {
            onForceStop()
        } label: {
            if isForceStopInFlight {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.tokyoRed)
                    Text("Stopping…")
                }
            } else {
                Text("Force Stop Session")
            }
        }
        .font(.caption)
        .foregroundStyle(.tokyoRed)
        .disabled(isForceStopInFlight)
    }

    // MARK: - Actions

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
            // here caused a SafeArea resize → LazyVStack full placement
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
    static func from(_ image: UIImage) -> PendingImage {
        let resized = downsample(image, maxDimension: 1568)
        let jpegData = resized.jpegData(compressionQuality: 0.85) ?? Data()
        let base64 = jpegData.base64EncodedString()
        let thumb = downsample(image, maxDimension: 112)

        return PendingImage(
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
