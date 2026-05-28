import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Shared logic between ChatInputBar and ExpandedComposerView.
///
/// Eliminates duplicated private functions for image handling, input manipulation,
/// voice UI helpers, and keyboard management. Both composers delegate to these
/// static functions instead of maintaining their own copies.
@MainActor
enum ComposerShared {

    // MARK: - Voice UI Helpers

    static func micEngineBadge(for manager: VoiceInputManager) -> MicButtonLabel.EngineBadge {
        switch manager.routeIndicator {
        case .auto: return .auto
        case .onDevice: return .onDevice
        case .remote: return .remote
        }
    }

    static func voiceRouteAccessibilityValue(for manager: VoiceInputManager) -> String {
        manager.routeIndicator.accessibilityLabel
    }

    static func accessibilityLabel(isRecording: Bool, isPreparing: Bool) -> String {
        if isRecording { return "Stop recording" }
        if isPreparing { return "Cancel voice input" }
        return "Start voice input"
    }

    // MARK: - Image Handling

    static func loadSelectedPhotos(
        _ items: [PhotosPickerItem],
        into pendingAttachments: Binding<[PendingAttachment]>
    ) {
        for item in items {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                guard let uiImage = UIImage(data: data) else { return }
                let mimeType = item.supportedContentTypes
                    .compactMap(\.preferredMIMEType)
                    .first
                let pending = PendingImage.from(data: data, mimeType: mimeType, image: uiImage)
                await MainActor.run {
                    pendingAttachments.wrappedValue.append(pending.pendingAttachment)
                }
            }
        }
    }

    static func addCapturedImage(
        _ image: UIImage,
        to pendingAttachments: Binding<[PendingAttachment]>
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pending = PendingImage.from(image)
            DispatchQueue.main.async {
                pendingAttachments.wrappedValue.append(pending.pendingAttachment)
            }
        }
    }

    static func removeAttachment(
        _ id: String,
        from pendingAttachments: Binding<[PendingAttachment]>
    ) {
        pendingAttachments.wrappedValue.removeAll { $0.id == id }
    }

    static func handlePastedImages(
        _ images: [UIImage],
        into pendingAttachments: Binding<[PendingAttachment]>
    ) {
        for image in images {
            DispatchQueue.global(qos: .userInitiated).async {
                let pending = PendingImage.from(image)
                DispatchQueue.main.async {
                    pendingAttachments.wrappedValue.append(pending.pendingAttachment)
                }
            }
        }
    }

    static func loadSelectedFiles(
        _ result: Result<[URL], Error>,
        into pendingAttachments: Binding<[PendingAttachment]>
    ) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                guard let data = try? Data(contentsOf: url) else { return }
                let values = try? url.resourceValues(forKeys: [.contentTypeKey, .nameKey])
                let mimeType = PendingAttachment.mimeType(for: url, contentType: values?.contentType)
                let displayName = values?.name ?? url.lastPathComponent
                let thumbnail: UIImage? = if mimeType.hasPrefix("image/") {
                    UIImage(data: data)
                } else {
                    nil
                }
                let attachment = PendingAttachment.localFile(
                    name: displayName,
                    data: data,
                    mimeType: mimeType,
                    thumbnail: thumbnail
                )
                await MainActor.run {
                    pendingAttachments.wrappedValue.append(attachment)
                }
            }
        }
    }

    // MARK: - Shared Attachment Views

    static func attachmentStrip(
        pendingAttachments: Binding<[PendingAttachment]>,
        horizontalPadding: CGFloat? = nil
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            if let horizontalPadding {
                attachmentRow(pendingAttachments: pendingAttachments)
                    .padding(.horizontal, horizontalPadding)
            } else {
                attachmentRow(pendingAttachments: pendingAttachments)
            }
        }
    }

    static func filePillStrip(
        pendingRepoPointers: Binding<[PendingFileReference]>,
        horizontalPadding: CGFloat? = nil
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            if let horizontalPadding {
                filePillRow(pendingRepoPointers: pendingRepoPointers)
                    .padding(.horizontal, horizontalPadding)
            } else {
                filePillRow(pendingRepoPointers: pendingRepoPointers)
            }
        }
    }

    private static func attachmentRow(
        pendingAttachments: Binding<[PendingAttachment]>
    ) -> some View {
        HStack(spacing: 8) {
            ForEach(pendingAttachments.wrappedValue) { attachment in
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
                            removeAttachment(attachment.id, from: pendingAttachments)
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
                        removeAttachment(attachment.id, from: pendingAttachments)
                    }
                }
            }
        }
    }

    private static func filePillRow(
        pendingRepoPointers: Binding<[PendingFileReference]>
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(pendingRepoPointers.wrappedValue) { file in
                ComposerFilePill(file: file) {
                    removeFile(file.id, from: pendingRepoPointers)
                }
            }
        }
    }

    // MARK: - Input Manipulation

    static func insertSlashCommand(
        _ command: SlashCommand,
        into text: Binding<String>
    ) {
        text.wrappedValue = ComposerAutocomplete.insertSlashCommand(command, into: text.wrappedValue)
    }

    static func insertFileSuggestion(
        _ suggestion: FileSuggestion,
        text: Binding<String>,
        pendingRepoPointers: Binding<[PendingFileReference]>
    ) {
        if let tokenRange = ComposerAutocomplete.activeAtTokenRange(in: text.wrappedValue) {
            text.wrappedValue.replaceSubrange(tokenRange, with: "")
        }
        if suggestion.isDirectory {
            text.wrappedValue += "@\(suggestion.path)"
            return
        }

        let ref = PendingFileReference(path: suggestion.path, isDirectory: false, kind: .workspaceFile)
        if !pendingRepoPointers.wrappedValue.contains(where: { $0.id == ref.id }) {
            pendingRepoPointers.wrappedValue.append(ref)
        }
    }

    static func removeFile(
        _ id: String,
        from pendingRepoPointers: Binding<[PendingFileReference]>
    ) {
        pendingRepoPointers.wrappedValue.removeAll { $0.id == id }
    }

    static func notifyFileSuggestionContext(
        for newText: String,
        isBusy: Bool,
        onFileSuggestionQuery: ((String?) -> Void)?
    ) {
        let ctx = ComposerAutocomplete.context(for: newText)
        if case .atFile(let query) = ctx {
            onFileSuggestionQuery?(query)
        } else {
            onFileSuggestionQuery?(nil)
        }
    }

    // MARK: - Keyboard / Voice

    static func currentComposerText(
        storedText: String,
        textBeforeRecording: String?,
        liveTranscript: String?
    ) -> String {
        guard let prefix = textBeforeRecording, let liveTranscript else {
            return storedText
        }
        return prefix + liveTranscript
    }

    static func visibleComposerText(_ text: String) -> String {
        if text.hasPrefix("$ ") {
            return String(text.dropFirst(2))
        }
        return text
    }

    static func textFieldBinding(
        text: Binding<String>,
        displayText: @escaping () -> String
    ) -> Binding<String> {
        Binding(
            get: {
                visibleComposerText(displayText())
            },
            set: { newValue in
                if text.wrappedValue.hasPrefix("$ ") {
                    text.wrappedValue = newValue.isEmpty ? "" : "$ " + newValue
                } else {
                    text.wrappedValue = newValue
                }
            }
        )
    }

    static func correctionRanges(
        manager: VoiceInputManager?,
        textBeforeRecording: String?
    ) -> [NSRange] {
        guard let manager,
              let prefix = textBeforeRecording else { return [] }
        let offset = (visibleComposerText(prefix) as NSString).length
        return manager.currentTranscriptCorrectionRanges.map { range in
            NSRange(location: range.location + offset, length: range.length)
        }
    }

    static func dictationPrefix(for base: String) -> String {
        if base.isEmpty || base.last?.isWhitespace == true {
            return base
        }
        return base + " "
    }

    static func startVoiceInput(
        manager: VoiceInputManager,
        keyboardLanguage: String?,
        source: String,
        baseText: String,
        textBeforeRecording: Binding<String?>? = nil,
        suppressKeyboard: Binding<Bool>,
        focusRequestID: Binding<Int>,
        prepare: (() async throws -> Void)? = nil
    ) async throws -> String {
        let prefix = dictationPrefix(for: baseText)
        textBeforeRecording?.wrappedValue = prefix
        suppressKeyboard.wrappedValue = true
        focusRequestID.wrappedValue &+= 1

        do {
            try await prepare?()
            try await manager.startRecording(
                keyboardLanguage: keyboardLanguage,
                source: source
            )
            return prefix
        } catch {
            textBeforeRecording?.wrappedValue = nil
            suppressKeyboard.wrappedValue = false
            throw error
        }
    }

    static func stopVoiceInput(
        manager: VoiceInputManager,
        text: Binding<String>,
        textBeforeRecording: Binding<String?>
    ) async {
        let prefix = textBeforeRecording.wrappedValue ?? ""
        let transcript = await manager.stopRecording()
        textBeforeRecording.wrappedValue = nil
        if !transcript.isEmpty {
            text.wrappedValue = prefix + transcript
        }
    }

    static func cancelVoiceInput(
        manager: VoiceInputManager,
        textBeforeRecording: Binding<String?>,
        suppressKeyboard: Binding<Bool>
    ) async {
        await manager.cancelRecording()
        textBeforeRecording.wrappedValue = nil
        suppressKeyboard.wrappedValue = false
    }

    static func handleKeyboardRestore(
        suppressKeyboard: Binding<Bool>,
        textBeforeRecording: Binding<String?>,
        voiceInputManager: VoiceInputManager?
    ) {
        suppressKeyboard.wrappedValue = false
        textBeforeRecording.wrappedValue = nil
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
}

// MARK: - Composer File Pill

/// Reusable repo-pointer pill used by both inline and expanded composers.
struct ComposerFilePill: View {
    let file: PendingFileReference
    let onRemove: () -> Void

    private var accent: Color {
        switch file.kind {
        case .reviewFile:
            return .themeCyan
        case .workspaceFile:
            return .themePurple
        }
    }

    private var labelPrefix: String {
        if let displayPrefix = file.displayPrefix {
            return displayPrefix
        }
        switch file.kind {
        case .reviewFile:
            return "Review"
        case .workspaceFile:
            return "Repo"
        }
    }

    var body: some View {
        let icon = file.isDirectory
            ? FileIcon(symbolName: "folder.fill", color: .themeYellow)
            : FileIcon.forPath(file.path)

        HStack(spacing: 4) {
            Text(labelPrefix)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent)

            icon.iconView(size: 12, font: .appTag)

            Text(file.displayName)
                .font(.caption2.monospaced())
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .fixedSize()

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.appBadge)
                    .foregroundStyle(.themeComment)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(accent.opacity(0.10), in: Capsule())
        .overlay(
            Capsule()
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
    }
}

struct ComposerAttachmentPill: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            FileIcon.forPath(name).iconView(size: 12, font: .appTag)

            Text(name)
                .font(.caption2.monospaced())
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .fixedSize()

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.appBadge)
                    .foregroundStyle(.themeComment)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.themeComment.opacity(0.1), in: Capsule())
    }
}

// MARK: - Camera Cover

extension View {
    /// Camera full-screen cover shared by inline and expanded composers.
    func composerCameraCover(
        isPresented: Binding<Bool>,
        pendingAttachments: Binding<[PendingAttachment]>
    ) -> some View {
        fullScreenCover(isPresented: isPresented) {
            CameraPicker(
                onCapture: { image in
                    ComposerShared.addCapturedImage(image, to: pendingAttachments)
                    isPresented.wrappedValue = false
                },
                onCancel: {
                    isPresented.wrappedValue = false
                }
            )
            .ignoresSafeArea()
        }
    }
}
