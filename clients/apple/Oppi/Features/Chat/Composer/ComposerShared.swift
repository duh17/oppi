import Foundation
import UIKit
import UniformTypeIdentifiers

/// Shared logic between the inline composer (`ChatComposerOwner`) and the
/// expanded composer (`ExpandedComposerViewController`).
///
/// Eliminates duplicated private functions for image handling, input manipulation,
/// voice UI helpers, and keyboard management. Both composers delegate to these
/// static functions instead of maintaining their own copies.
@MainActor
enum ComposerShared {
    /// Visible photo in the composer strip. Keep larger than the old 56pt tile
    /// so annotate vs remove is easy to hit. HIG wants at least 44×44 hit regions.
    static let attachmentThumbnailSize: CGFloat = 76
    static let attachmentTileSize: CGFloat = 88
    static let attachmentRemoveHitSize: CGFloat = 44
    /// Picker UX limit only. Server-side chat attachments are constrained by byte budgets,
    /// not by a small fixed image count, so keep this comfortably above the old 5-item cap.
    static let maxPhotoSelectionCount = 10

    enum VoiceInputOwner: String, Sendable {
        case inlineComposer = "inline_mic_tap"
        case expandedComposer = "expanded_mic_tap"
        case inboxComposer = "inbox_mic_tap"
        /// Edit-menu mic that dictates a review comment into the chat composer.
        case reviewCommentMenu = "review_comment_menu_mic_tap"
        case askCard = "ask_card_mic_tap"
        case reviewCommentInline = "review_comment_inline_mic_tap"

        var isMessageComposer: Bool {
            switch self {
            case .inlineComposer, .expandedComposer, .inboxComposer, .reviewCommentMenu: true
            case .askCard, .reviewCommentInline: false
            }
        }
    }

    struct MicButtonPresentation: Equatable {
        let isRecording: Bool
        let isPreparing: Bool
        let isProcessing: Bool
        let isBlockedByOtherOwner: Bool
        let voiceSpectrum: VoiceSpectrumFrame
        let languageLabel: String?
        let engineBadge: MicEngineBadge
        let accessibilityValue: String

        var isBusy: Bool { isPreparing || isProcessing }
        /// Commit listening chrome on tap. Preparing is not a spinner; the ring
        /// stays flat until first PCM. Success haptic still waits for recording.
        var showsListeningChrome: Bool { isRecording || isPreparing }
        var isEnabled: Bool { !isProcessing && !isBlockedByOtherOwner }
        var accessibilityLabel: String {
            if isRecording { return "Stop recording" }
            if isPreparing { return "Cancel voice input" }
            return "Start voice input"
        }
    }

    /// Mic tap after a failed start must retry, not sit disabled in `.error`.
    enum VoiceMicTapAction: Equatable {
        case start
        case stop
        case cancelPreparing
        case ignore
    }

    // MARK: - Voice UI Helpers

    static func micEngineBadge(for manager: VoiceInputManager) -> MicEngineBadge {
        switch manager.routeIndicator {
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

    static func captureFailure(
        _ manager: VoiceInputManager?, owner: VoiceInputOwner
    ) -> VoiceCaptureFailure? {
        guard let failure = manager?.currentComposerCaptureFailure else { return nil }
        let source = VoiceInputOwner(rawValue: failure.source)
        guard failure.source == owner.rawValue || (owner.isMessageComposer && source?.isMessageComposer == true) else {
            return nil
        }
        return failure
    }

    /// Both composer presentations share the same draft binding. Restore only
    /// while its take prefix is present, then retire that prefix so later typing
    /// or the second surface's observer cannot erase the user's edits.
    static func discardFailedTake(
        manager: VoiceInputManager?,
        owner: VoiceInputOwner,
        setText: @escaping (String) -> Void,
        getTextBeforeRecording: @escaping () -> String?,
        setTextBeforeRecording: @escaping (String?) -> Void,
        setSuppressKeyboard: @escaping (Bool) -> Void
    ) {
        guard captureFailure(manager, owner: owner) != nil else { return }
        if let prefix = getTextBeforeRecording() {
            setText(prefix)
            setTextBeforeRecording(nil)
        }
        setSuppressKeyboard(false)
    }

    static func micTapAction(for state: VoiceInputManager.State) -> VoiceMicTapAction {
        switch state {
        case .idle, .error:
            return .start
        case .recording:
            return .stop
        case .preparingModel:
            return .cancelPreparing
        case .processing:
            return .ignore
        }
    }

    static func canControlVoiceInput(_ manager: VoiceInputManager, owner: VoiceInputOwner) -> Bool {
        ownsVoiceInput(manager, owner: owner) || micTapAction(for: manager.state) == .start
    }

    static func micButtonPresentation(
        for manager: VoiceInputManager,
        owner: VoiceInputOwner
    ) -> MicButtonPresentation {
        let ownsInput = ownsVoiceInput(manager, owner: owner)
        let isRecording = manager.isRecording && ownsInput
        let isPreparing = manager.isPreparing && ownsInput
        let isProcessing = manager.isProcessing && ownsInput
        let isBlocked = micTapAction(for: manager.state) != .start && !ownsInput
        return MicButtonPresentation(
            isRecording: isRecording,
            isPreparing: isPreparing,
            isProcessing: isProcessing,
            isBlockedByOtherOwner: isBlocked,
            voiceSpectrum: manager.voiceSpectrum,
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
            isBlockedByOtherOwner: micTapAction(for: manager.state) != .start,
            voiceSpectrum: .zero,
            languageLabel: nil,
            engineBadge: micEngineBadge(for: manager),
            accessibilityValue: voiceRouteAccessibilityValue(for: manager)
        )
    }

    // MARK: - Image Handling

    @discardableResult
    static func applyCanvasToComposer(
        attachment: PendingAttachment,
        recognizedText _: String,
        getAttachments: @escaping () -> [PendingAttachment],
        setAttachments: @escaping ([PendingAttachment]) -> Void,
        replacingAttachmentID: String?
    ) -> Bool {
        setAttachments(replacedPendingAttachments(
            getAttachments(),
            with: attachment,
            replacingAttachmentID: replacingAttachmentID
        ))
        return getAttachments().contains(where: { $0.id == attachment.id })
    }

    static func replacedPendingAttachments(
        _ pendingAttachments: [PendingAttachment],
        with attachment: PendingAttachment,
        replacingAttachmentID: String?
    ) -> [PendingAttachment] {
        var next = pendingAttachments
        if let replacingAttachmentID,
           let index = next.firstIndex(where: { $0.id == replacingAttachmentID }) {
            next[index] = attachment
            return next
        }
        if !next.contains(where: { $0.id == attachment.id }) {
            next.append(attachment)
        }
        return next
    }

    static func image(forPendingAttachment attachment: PendingAttachment) -> UIImage? {
        let raw: UIImage?
        if let imageAttachment = attachment.imageAttachment,
           let data = Data(base64Encoded: imageAttachment.data, options: .ignoreUnknownCharacters),
           let image = UIImage(data: data) {
            raw = image
        } else if let data = attachment.localFileData,
                  attachment.localMimeType?.hasPrefix("image/") == true {
            raw = UIImage(data: data)
        } else {
            raw = attachment.thumbnail
        }
        return raw.map(PaperMarkupCanvasSession.copiedImage(from:))
    }

    static let photoLibraryImportRefusedMessage = "Photos and videos can only be attached to a message."

    /// Append imported attachments. Returns any items the binding dropped so the
    /// caller can discard their draft files and surface an error.
    static func commitImportedAttachments(
        _ attachments: [PendingAttachment],
        getAttachments: @escaping () -> [PendingAttachment],
        setAttachments: @escaping ([PendingAttachment]) -> Void
    ) -> [PendingAttachment] {
        setAttachments(getAttachments() + attachments)
        let acceptedIDs = Set(getAttachments().map(\.id))
        return attachments.filter { !acceptedIDs.contains($0.id) }
    }

    static func importPhotoLibraryProviders(
        _ providers: [NSItemProvider],
        getAttachments: @escaping () -> [PendingAttachment],
        setAttachments: @escaping ([PendingAttachment]) -> Void,
        store: ComposerDraftStore?,
        shouldAccept: @escaping @MainActor () -> Bool,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        Task { @MainActor in
            let result = await PhotoLibraryMediaImporter.importProviders(providers, store: store)
            finishPhotoLibraryImport(
                result,
                getAttachments: getAttachments,
                setAttachments: setAttachments,
                store: store,
                shouldAccept: shouldAccept,
                onFailure: onFailure
            )
        }
    }

    static func finishPhotoLibraryImport(
        _ result: PhotoLibraryMediaImporter.ImportResult,
        getAttachments: @escaping () -> [PendingAttachment],
        setAttachments: @escaping ([PendingAttachment]) -> Void,
        store: ComposerDraftStore?,
        shouldAccept: @MainActor () -> Bool,
        onFailure: @MainActor (String) -> Void
    ) {
        guard shouldAccept() else {
            PhotoLibraryMediaImporter.discardImportedFiles(result.attachments, store: store)
            onFailure(photoLibraryImportRefusedMessage)
            return
        }
        let rejected = commitImportedAttachments(
            result.attachments,
            getAttachments: getAttachments,
            setAttachments: setAttachments
        )
        if !rejected.isEmpty {
            PhotoLibraryMediaImporter.discardImportedFiles(rejected, store: store)
            onFailure(photoLibraryImportRefusedMessage)
        } else if let message = result.failureMessage {
            onFailure(message)
        }
    }

    static func addCapturedImage(
        _ image: UIImage,
        getAttachments: @escaping () -> [PendingAttachment],
        setAttachments: @escaping ([PendingAttachment]) -> Void,
        shouldAccept: @escaping @MainActor () -> Bool
    ) {
        appendEncodedImages(
            [image],
            getAttachments: getAttachments,
            setAttachments: setAttachments,
            shouldAccept: shouldAccept
        )
    }

    /// Encodes the batch off the main actor in one task, so it keeps its
    /// order, then appends it to the draft once. `shouldAccept` is asked after
    /// the encode: a draft that was sent or cleared meanwhile gets nothing.
    private static func appendEncodedImages(
        _ images: [UIImage],
        getAttachments: @escaping () -> [PendingAttachment],
        setAttachments: @escaping ([PendingAttachment]) -> Void,
        shouldAccept: @escaping @MainActor () -> Bool
    ) {
        guard !images.isEmpty else { return }
        Task { @MainActor in
            let pending = await Task.detached(priority: .userInitiated) { images.map(PendingImage.from) }.value
            guard shouldAccept() else { return }
            setAttachments(getAttachments() + pending.map(\.pendingAttachment))
        }
    }

    static func removeAttachment(
        _ id: String,
        getAttachments: @escaping () -> [PendingAttachment],
        setAttachments: @escaping ([PendingAttachment]) -> Void
    ) {
        var attachments = getAttachments()
        attachments.removeAll { $0.id == id }
        setAttachments(attachments)
    }

    static func handlePastedImages(
        _ images: [UIImage],
        getAttachments: @escaping () -> [PendingAttachment],
        setAttachments: @escaping ([PendingAttachment]) -> Void,
        shouldAccept: @escaping @MainActor () -> Bool
    ) {
        appendEncodedImages(
            images,
            getAttachments: getAttachments,
            setAttachments: setAttachments,
            shouldAccept: shouldAccept
        )
    }

    static func loadSelectedFiles(
        _ result: Result<[URL], Error>,
        getAttachments: @escaping () -> [PendingAttachment],
        setAttachments: @escaping ([PendingAttachment]) -> Void,
        store: ComposerDraftStore?,
        shouldAccept: @escaping @MainActor () -> Bool,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        Task { @MainActor in
            await importSelectedFiles(
                result,
                getAttachments: getAttachments,
                setAttachments: setAttachments,
                store: store,
                shouldAccept: shouldAccept,
                onFailure: onFailure
            )
        }
    }

    /// Copy Files-picked videos into the Class B draft URL off-main before the
    /// chip. Non-video files still load as in-memory attachments.
    static func importSelectedFiles(
        _ result: Result<[URL], Error>,
        getAttachments: @escaping () -> [PendingAttachment],
        setAttachments: @escaping ([PendingAttachment]) -> Void,
        store: ComposerDraftStore?,
        shouldAccept: @escaping @MainActor () -> Bool,
        onFailure: @escaping @MainActor (String) -> Void
    ) async {
        guard case .success(let urls) = result else { return }
        let imported = await importSelectedFileURLs(urls, store: store)
        finishPhotoLibraryImport(
            imported,
            getAttachments: getAttachments,
            setAttachments: setAttachments,
            store: store,
            shouldAccept: shouldAccept,
            onFailure: onFailure
        )
    }

    static func importSelectedFileURLs(
        _ urls: [URL],
        store: ComposerDraftStore?
    ) async -> PhotoLibraryMediaImporter.ImportResult {
        var attachments: [PendingAttachment] = []
        var failures: [String] = []
        for url in urls {
            do {
                attachments.append(try await importSelectedFile(url, store: store))
            } catch {
                let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty {
                    failures.append(error.localizedDescription)
                } else {
                    failures.append("Couldn't attach \(name).")
                }
            }
        }
        return PhotoLibraryMediaImporter.ImportResult(attachments: attachments, failures: failures)
    }

    static func importSelectedFile(
        _ url: URL,
        store: ComposerDraftStore?
    ) async throws -> PendingAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .nameKey])
        let mimeType = PendingAttachment.mimeType(for: url, contentType: values?.contentType)
        let displayName = values?.name ?? url.lastPathComponent

        if mimeType.lowercased().hasPrefix("video/") {
            guard let store else {
                throw PhotoLibraryMediaImporter.ImportError.missingDraftStore
            }
            let destination = try store.importAttachmentFile(from: url)
            do {
                return try PhotoLibraryMediaImporter.makePendingAttachment(
                    fromCopiedFile: destination,
                    kind: .video,
                    displayName: displayName,
                    mimeType: mimeType,
                    store: store
                )
            } catch {
                store.deleteImportedAttachmentFile(destination)
                throw error
            }
        }

        let data = try await Task.detached {
            try Data(contentsOf: url)
        }.value
        let thumbnail: UIImage? = if mimeType.hasPrefix("image/") {
            UIImage(data: data)
        } else {
            nil
        }
        return PendingAttachment.localFile(
            name: displayName,
            data: data,
            mimeType: mimeType,
            thumbnail: thumbnail
        )
    }

    // MARK: - Input Manipulation

    static func insertSlashCommand(
        _ command: SlashCommand,
        getText: @escaping () -> String,
        setText: @escaping (String) -> Void
    ) {
        setText(ComposerAutocomplete.insertSlashCommand(command, into: getText()))
    }

    static func insertFileSuggestion(
        _ suggestion: FileSuggestion,
        getText: @escaping () -> String,
        setText: @escaping (String) -> Void,
        getPointers: @escaping () -> [PendingFileReference],
        setPointers: @escaping ([PendingFileReference]) -> Void
    ) {
        var text = getText()
        if let tokenRange = ComposerAutocomplete.activeAtTokenRange(in: text) {
            text.replaceSubrange(tokenRange, with: "")
            setText(text)
        }
        if suggestion.isDirectory {
            setText(text + "@\(suggestion.path)")
            return
        }

        let ref = PendingFileReference(path: suggestion.path, isDirectory: false, kind: .workspaceFile)
        var pointers = getPointers()
        if !pointers.contains(where: { $0.id == ref.id }) {
            pointers.append(ref)
            setPointers(pointers)
        }
    }

    static func removeFile(
        _ id: String,
        getPointers: @escaping () -> [PendingFileReference],
        setPointers: @escaping ([PendingFileReference]) -> Void
    ) {
        var pointers = getPointers()
        pointers.removeAll { $0.id == id }
        setPointers(pointers)
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
        // Render the rollback immediately, even before SwiftUI's onChange
        // commits it to the shared draft binding.
        if captureFailure(manager, owner: owner) != nil, let textBeforeRecording {
            return textBeforeRecording
        }
        return currentComposerText(
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
        setText: ((String) -> Void)? = nil,
        setTextBeforeRecording: @escaping (String?) -> Void,
        setSuppressKeyboard: @escaping (Bool) -> Void,
        getFocusRequestID: @escaping () -> Int,
        setFocusRequestID: @escaping (Int) -> Void,
        prepare: (() async throws -> Void)? = nil,
        playTapHaptic: () -> Void = { AppHaptics.dictationTapAccepted() },
        playActivationHaptic: () -> Void = { AppHaptics.dictationActivated() }
    ) async throws -> String {
        // Admission precedes binding writes: a tap during cancellation drain
        // must not replace the failed take's rollback or a retry's prefix.
        let startupID = try manager.beginComposerStartup()
        playTapHaptic()
        let prefix = dictationPrefix(for: baseText)
        setTextBeforeRecording(prefix)
        setSuppressKeyboard(true)
        setFocusRequestID(getFocusRequestID() &+ 1)

        do {
            try await prepare?()
            guard manager.composerStartupID == startupID else { throw CancellationError() }
            try await manager.startRecording(
                keyboardLanguage: keyboardLanguage,
                source: owner.rawValue,
                onCaptureFailure: { [weak manager] in
                    guard manager?.composerStartupID == startupID, let setText else { return }
                    setText(baseText)
                    setTextBeforeRecording(nil)
                    setSuppressKeyboard(false)
                }
            )
            guard manager.composerStartupID == startupID else { throw CancellationError() }
            guard manager.isActiveRecordingSource(owner.rawValue), manager.isRecording || manager.isPreparing else {
                if case .error(let message) = manager.state {
                    throw VoiceInputError.internalError(message)
                }
                throw CancellationError()
            }
            // One pulse after capture is ready, including any route recovery.
            if manager.isRecording { playActivationHaptic() }
            return prefix
        } catch {
            // The retired surface must not clear shared bindings or report a
            // stale error after another presentation has admitted a new take.
            guard manager.composerStartupID == startupID else { throw CancellationError() }
            setTextBeforeRecording(nil)
            setSuppressKeyboard(false)
            throw error
        }
    }

    static func stopVoiceInput(
        manager: VoiceInputManager,
        setText: @escaping (String) -> Void,
        getTextBeforeRecording: @escaping () -> String?,
        setTextBeforeRecording: @escaping (String?) -> Void
    ) async {
        let prefix = getTextBeforeRecording() ?? ""
        let transcript = await manager.stopRecording()
        setTextBeforeRecording(nil)
        if !transcript.isEmpty {
            setText(prefix + transcript)
        }
    }

    static func cancelVoiceInput(
        manager: VoiceInputManager,
        setTextBeforeRecording: @escaping (String?) -> Void,
        setSuppressKeyboard: @escaping (Bool) -> Void
    ) async {
        await manager.cancelRecording()
        setTextBeforeRecording(nil)
        setSuppressKeyboard(false)
    }

    /// Drop in-flight capture when the owning UI disappears.
    /// Dismiss must not leave SpeechAnalyzer / the mic tap running, or the next
    /// start fails with NSError during setup.
    static func cancelVoiceInputOnDismiss(manager: VoiceInputManager?) async {
        guard let manager, manager.isRecording || manager.isPreparing else { return }
        await manager.cancelRecording()
    }

    /// Deferred disappearance cleanup. `takeIdentity` is captured before the
    /// Task is queued; a nil or stale identity must not cancel a newer take.
    static func cancelVoiceInputOnDismiss(
        manager: VoiceInputManager?,
        matching takeIdentity: VoiceCaptureTakeIdentity?
    ) async {
        guard let manager else { return }
        await manager.cancelRecording(matching: takeIdentity)
    }

    /// Snapshot the retiring composer's take. A delayed disappear after another
    /// composer claimed must not bind the newer take.
    static func takeIdentityForDismissedComposer(
        manager: VoiceInputManager?,
        generation: Int?
    ) -> VoiceCaptureTakeIdentity? {
        guard let generation else { return nil }
        guard let identity = manager?.currentCaptureTakeIdentity(),
              identity.composerGeneration == generation else {
            return nil
        }
        return identity
    }

    /// Conversation-free composer. If `ownedGeneration` still matches an in-flight
    /// take, keep that generation
    /// for dismiss matching instead of replacing it with a newer configuration claim.
    @discardableResult
    static func prepareStandaloneVoiceInput(
        manager: VoiceInputManager,
        serverId: String,
        credentials: ServerCredentials?,
        connection: ServerConnection?,
        playbackInterrupter: (any VoicePlaybackCaptureCoordinating)?,
        workspaceId: String? = nil,
        ownedGeneration: Int? = nil
    ) -> Int {
        if let ownedGeneration,
           let identity = manager.currentCaptureTakeIdentity(),
           identity.composerGeneration == ownedGeneration {
            manager.setPlaybackInterrupter(playbackInterrupter)
            return ownedGeneration
        }
        let generation = manager.beginStandaloneComposer(
            serverId: serverId,
            credentials: credentials,
            connection: connection,
            workspaceId: workspaceId
        )
        manager.setPlaybackInterrupter(playbackInterrupter)
        return generation
    }

    /// Reclaim the conversation composer for this session.
    static func prepareConversationVoiceInput(
        manager: VoiceInputManager,
        serverId: String?,
        sessionId: String,
        credentials: ServerCredentials?,
        connection: ServerConnection?,
        playbackInterrupter: (any VoicePlaybackCaptureCoordinating)?,
        workspaceId: String? = nil
    ) {
        guard let serverId else { return }
        _ = manager.activateConversationComposer(
            serverId: serverId,
            sessionId: sessionId,
            credentials: credentials,
            connection: connection,
            workspaceId: workspaceId
        )
        manager.setPlaybackInterrupter(playbackInterrupter)
    }

    @discardableResult
    static func finishOwnedVoiceInputBeforeSubmit(
        manager: VoiceInputManager?,
        owner: VoiceInputOwner,
        setText: @escaping (String) -> Void,
        getTextBeforeRecording: @escaping () -> String?,
        setTextBeforeRecording: @escaping (String?) -> Void,
        setSuppressKeyboard: @escaping (Bool) -> Void,
        restoreKeyboard: Bool = true
    ) async -> Bool {
        guard let manager,
              ownsVoiceInput(manager, owner: owner),
              manager.isRecording || manager.isPreparing else { return false }

        if manager.isRecording {
            await stopVoiceInput(
                manager: manager,
                setText: setText,
                getTextBeforeRecording: getTextBeforeRecording,
                setTextBeforeRecording: setTextBeforeRecording
            )
        } else {
            await manager.cancelRecording()
            setTextBeforeRecording(nil)
        }
        if restoreKeyboard {
            setSuppressKeyboard(false)
        }
        return true
    }

    /// The mic's long-press menu wherever a composer can start Live Voice.
    static func voiceEntryMenu(
        identifierPrefix: String,
        onLiveVoice: @escaping () -> Void,
        onDictation: @escaping () -> Void
    ) -> UIMenu {
        UIMenu(title: "Voice", children: [
            UIAction(
                title: "Live Voice",
                image: UIImage(systemName: "waveform"),
                identifier: UIAction.Identifier("\(identifierPrefix).voiceEntry.liveVoice")
            ) { _ in onLiveVoice() },
            UIAction(
                title: "Dictation",
                image: UIImage(systemName: "mic"),
                identifier: UIAction.Identifier("\(identifierPrefix).voiceEntry.dictation")
            ) { _ in onDictation() },
        ])
    }

    /// The dictation a composer near `view` offers: none while the app's Live Voice call holds
    /// the one microphone, whichever session it is on. Read in a pass that Observation
    /// tracks, the mic comes back when the call ends.
    static func dictation(_ manager: VoiceInputManager?, near view: UIView?) -> VoiceInputManager? {
        if let view, HostFactory.root(near: view)?.liveVoiceCalls.ownsMicrophone == true {
            return nil
        }
        return manager
    }

    static func stopDictationBeforeLiveVoice(manager: VoiceInputManager?) async {
        guard let manager, manager.isRecording || manager.isPreparing else { return }
        await manager.cancelRecording()
    }

    @discardableResult
    static func cancelOwnedVoiceInput(
        manager: VoiceInputManager?,
        owner: VoiceInputOwner,
        setTextBeforeRecording: @escaping (String?) -> Void,
        setSuppressKeyboard: @escaping (Bool) -> Void
    ) async -> Bool {
        guard let manager,
              ownsVoiceInput(manager, owner: owner),
              manager.isRecording || manager.isPreparing else { return false }

        await manager.cancelRecording()
        setTextBeforeRecording(nil)
        setSuppressKeyboard(false)
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
        setSuppressKeyboard: @escaping (Bool) -> Void,
        setTextBeforeRecording: @escaping (String?) -> Void,
        voiceInputManager: VoiceInputManager?,
        expectedOwner: VoiceInputOwner?
    ) {
        setSuppressKeyboard(false)
        setTextBeforeRecording(nil)
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
