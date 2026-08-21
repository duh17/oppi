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
    private static let attachmentThumbnailSize: CGFloat = 56
    private static let attachmentTileSize: CGFloat = 64
    /// Picker UX limit only. Server-side chat attachments are constrained by byte budgets,
    /// not by a small fixed image count, so keep this comfortably above the old 5-item cap.
    static let maxPhotoSelectionCount = 10

    enum VoiceInputOwner: String, Sendable {
        case inlineComposer = "inline_mic_tap"
        case expandedComposer = "expanded_mic_tap"
        case askCard = "ask_card_mic_tap"
        case reviewCommentInline = "review_comment_inline_mic_tap"

        var isMessageComposer: Bool {
            self == .inlineComposer || self == .expandedComposer
        }
    }

    struct MicButtonPresentation: Equatable {
        let isRecording: Bool
        let isPreparing: Bool
        let isProcessing: Bool
        let isBlockedByOtherOwner: Bool
        let audioLevel: Float
        let languageLabel: String?
        let engineBadge: MicButtonLabel.EngineBadge
        let accessibilityValue: String

        var isBusy: Bool { isPreparing || isProcessing }
        var isEnabled: Bool { !isProcessing && !isBlockedByOtherOwner }
        var accessibilityLabel: String {
            if isRecording { return "Stop recording" }
            if isPreparing { return "Cancel voice input" }
            return "Start voice input"
        }
    }

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

    static func ownsVoiceInput(_ manager: VoiceInputManager?, owner: VoiceInputOwner) -> Bool {
        guard let manager, let activeSource = manager.activeRecordingSource else { return false }
        if activeSource == owner.rawValue { return true }

        // Inline and expanded are two presentations of the same message composer.
        // Keep the original source for telemetry, but let either surface render and
        // control the one shared recording session during presentation handoff.
        return owner.isMessageComposer && VoiceInputOwner(rawValue: activeSource)?.isMessageComposer == true
    }

    static func canControlVoiceInput(_ manager: VoiceInputManager, owner: VoiceInputOwner) -> Bool {
        ownsVoiceInput(manager, owner: owner) || manager.state == .idle
    }

    static func micButtonPresentation(
        for manager: VoiceInputManager,
        owner: VoiceInputOwner
    ) -> MicButtonPresentation {
        let ownsInput = ownsVoiceInput(manager, owner: owner)
        let isRecording = manager.isRecording && ownsInput
        let isPreparing = manager.isPreparing && ownsInput
        let isProcessing = manager.isProcessing && ownsInput
        let isBlocked = manager.state != .idle && !ownsInput
        return MicButtonPresentation(
            isRecording: isRecording,
            isPreparing: isPreparing,
            isProcessing: isProcessing,
            isBlockedByOtherOwner: isBlocked,
            audioLevel: manager.audioLevel,
            languageLabel: manager.activeLanguageLabel,
            engineBadge: micEngineBadge(for: manager),
            accessibilityValue: voiceRouteAccessibilityValue(for: manager)
        )
    }

    static func blockedMicButtonPresentation(for manager: VoiceInputManager) -> MicButtonPresentation {
        MicButtonPresentation(
            isRecording: false,
            isPreparing: false,
            isProcessing: false,
            isBlockedByOtherOwner: manager.state != .idle,
            audioLevel: 0,
            languageLabel: nil,
            engineBadge: micEngineBadge(for: manager),
            accessibilityValue: voiceRouteAccessibilityValue(for: manager)
        )
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
        .frame(height: attachmentTileSize)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(alignment: .center, spacing: 8) {
            ForEach(pendingAttachments.wrappedValue) { attachment in
                if attachment.source == .image, let thumbnail = attachment.thumbnail {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: attachmentThumbnailSize, height: attachmentThumbnailSize)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.themeComment.opacity(0.3), lineWidth: 1)
                            )
                            .frame(width: attachmentTileSize, height: attachmentTileSize, alignment: .bottomLeading)

                        Button {
                            removeAttachment(attachment.id, from: pendingAttachments)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.themeFg)
                                .background(Circle().fill(.themeScrim))
                        }
                    }
                    .frame(width: attachmentTileSize, height: attachmentTileSize)
                    .accessibilityIdentifier("chat.attachment.image.\(attachment.id)")
                } else {
                    ComposerAttachmentPill(name: attachment.displayName) {
                        removeAttachment(attachment.id, from: pendingAttachments)
                    }
                    .accessibilityIdentifier("chat.attachment.file.\(attachment.id)")
                }
            }
        }
        .frame(height: attachmentTileSize, alignment: .center)
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

    static func currentComposerText(
        storedText: String,
        textBeforeRecording: String?,
        manager: VoiceInputManager?,
        owner: VoiceInputOwner
    ) -> String {
        currentComposerText(
            storedText: storedText,
            textBeforeRecording: ownsVoiceInput(manager, owner: owner) ? textBeforeRecording : nil,
            liveTranscript: ownsVoiceInput(manager, owner: owner) ? manager?.currentTranscript : nil
        )
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

    static func correctionRanges(
        manager: VoiceInputManager?,
        textBeforeRecording: String?,
        owner: VoiceInputOwner
    ) -> [NSRange] {
        guard ownsVoiceInput(manager, owner: owner) else { return [] }
        return correctionRanges(manager: manager, textBeforeRecording: textBeforeRecording)
    }

    static func volatileSuffixLength(manager: VoiceInputManager?, owner: VoiceInputOwner) -> Int {
        guard ownsVoiceInput(manager, owner: owner) else { return 0 }
        return manager?.currentTranscriptVolatileSuffixLength ?? 0
    }

    static func dictationPrefix(for base: String) -> String {
        if base.isEmpty || base.last?.isWhitespace == true {
            return base
        }
        return base + " "
    }

    @discardableResult
    static func startVoiceInput(
        manager: VoiceInputManager,
        keyboardLanguage: String?,
        owner: VoiceInputOwner,
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
                source: owner.rawValue
            )
            guard manager.isActiveRecordingSource(owner.rawValue), manager.isRecording || manager.isPreparing else {
                textBeforeRecording?.wrappedValue = nil
                suppressKeyboard.wrappedValue = false
                throw CancellationError()
            }
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

    @discardableResult
    static func finishOwnedVoiceInputBeforeSubmit(
        manager: VoiceInputManager?,
        owner: VoiceInputOwner,
        text: Binding<String>,
        textBeforeRecording: Binding<String?>,
        suppressKeyboard: Binding<Bool>? = nil
    ) async -> Bool {
        guard let manager,
              ownsVoiceInput(manager, owner: owner),
              manager.isRecording || manager.isPreparing else { return false }

        if manager.isRecording {
            await stopVoiceInput(
                manager: manager,
                text: text,
                textBeforeRecording: textBeforeRecording
            )
        } else {
            await manager.cancelRecording()
            textBeforeRecording.wrappedValue = nil
        }
        suppressKeyboard?.wrappedValue = false
        return true
    }

    @discardableResult
    static func cancelOwnedVoiceInput(
        manager: VoiceInputManager?,
        owner: VoiceInputOwner,
        textBeforeRecording: Binding<String?>,
        suppressKeyboard: Binding<Bool>? = nil
    ) async -> Bool {
        guard let manager,
              ownsVoiceInput(manager, owner: owner),
              manager.isRecording || manager.isPreparing else { return false }

        await manager.cancelRecording()
        textBeforeRecording.wrappedValue = nil
        suppressKeyboard?.wrappedValue = false
        return true
    }

    static func shouldSuppressKeyboardForActiveVoiceInput(
        _ manager: VoiceInputManager?,
        owner: VoiceInputOwner
    ) -> Bool {
        guard let manager, ownsVoiceInput(manager, owner: owner) else { return false }
        return manager.isRecording || manager.isPreparing
    }

    static func handleKeyboardRestore(
        suppressKeyboard: Binding<Bool>,
        textBeforeRecording: Binding<String?>,
        voiceInputManager: VoiceInputManager?,
        expectedOwner: VoiceInputOwner? = nil
    ) {
        suppressKeyboard.wrappedValue = false
        textBeforeRecording.wrappedValue = nil
        if let manager = voiceInputManager,
           expectedOwner.map({ ownsVoiceInput(manager, owner: $0) }) ?? true,
           manager.isRecording || manager.isPreparing {
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
