import UIKit
import UniformTypeIdentifiers

/// UIKit host that points `ComposerBarController` at a terminal: local draft,
/// dictation, attachments uploaded to the host, empty Send as Enter.
@MainActor
final class SSHTerminalComposerHost: ComposerBarHosting {
    let channel: SSHTerminalChannel
    var connection: ServerConnection?
    var draftStore: ComposerDraftStore?
    var themeID: ThemeID
    var showRawKeyboard: () -> Void
    var onNeedsLayout: (() -> Void)?
    var onFailureChange: ((String?) -> Void)?

    weak var controller: ComposerBarController?

    private(set) var text = ""
    private var textBeforeRecording: String?
    private var pendingAttachments: [PendingAttachment] = []
    private var pendingRepoPointers: [PendingFileReference] = []
    private var streamingBehavior: StreamingBehavior = .followUp
    private var uploading = false
    private var voiceInputManager: VoiceInputManager?
    private var voiceComposerGeneration: Int?
    private var failure: String?
    private var suppressKeyboard = false
    private var focusRequestID = 0
    private var keyboardLanguage: String?
    private var reduceMotion = UIAccessibility.isReduceMotionEnabled
    var connected = true

    init(
        channel: SSHTerminalChannel,
        connection: ServerConnection?,
        draftStore: ComposerDraftStore?,
        themeID: ThemeID,
        showRawKeyboard: @escaping () -> Void
    ) {
        self.channel = channel
        self.connection = connection
        self.draftStore = draftStore
        self.themeID = themeID
        self.showRawKeyboard = showRawKeyboard
    }

    func attach(_ controller: ComposerBarController) {
        self.controller = controller
        controller.host = self
    }

    var sendFailure: String? { failure }
    var voiceManager: VoiceInputManager? { voiceInputManager }

    var content: ComposerBarContent {
        ComposerBarContent(
            text: text,
            textBeforeRecording: textBeforeRecording,
            pendingAttachments: pendingAttachments,
            pendingRepoPointers: pendingRepoPointers,
            isBusy: false,
            busyStreamingBehavior: streamingBehavior,
            isSending: uploading,
            pendingReviewCommentCount: 0,
            placeholderOverride: "",
            allowsEmptySubmit: true,
            sendProgressText: uploading ? "Uploading" : nil,
            isStopping: false,
            voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
            showForceStop: false,
            isForceStopInFlight: false,
            askRequest: nil,
            slashCommands: [],
            fileSuggestions: [],
            appliesOuterPadding: true,
            alwaysShowActionRow: false,
            allowsExpansion: false,
            allowsAttachments: true,
            attachmentButtonPlacement: .leading,
            actionRowMinimumHeight: ComposerInputMetrics.controlDiameter,
            showsAccessoryRow: true,
            autocorrectionEnabled: false,
            inputAccessibilityIdentifier: "chat.input",
            sendAccessibilityIdentifier: "chat.send",
            actionRow: .init(),
            colors: ComposerThemeColors(palette: themeID.palette),
            reduceMotion: reduceMotion,
            suppressKeyboard: suppressKeyboard,
            focusRequestID: focusRequestID,
            keyboardLanguage: keyboardLanguage,
            askHeight: 0,
            keyStripHeight: ComposerInputMetrics.controlDiameter,
            mediaImportEpoch: 0
        )
    }

    func refreshChrome(themeID: ThemeID, reduceMotion: Bool, connected: Bool) {
        self.themeID = themeID
        self.reduceMotion = reduceMotion
        self.connected = connected
        controller?.view.isUserInteractionEnabled = connected
        controller?.view.alpha = connected ? 1 : 0.45
        controller?.apply()
        onNeedsLayout?()
    }

    func requestFocus() {
        suppressKeyboard = false
        focusRequestID += 1
        controller?.apply()
    }

    func prepareVoice() async {
        guard ReleaseFeatures.voiceInputEnabled, connection != nil else { return }
        let manager = VoiceInputManager.shared
        await ComposerShared.cancelVoiceInputOnDismiss(manager: manager)
        if Task.isCancelled { return }
        configureVoice(manager)
        if Task.isCancelled { return }
        voiceInputManager = manager
        controller?.apply()
    }

    func installVoiceManager(_ manager: VoiceInputManager) {
        voiceInputManager = manager
    }

    /// Copies a live take into the draft and rolls back a failed take.
    /// The terminal controller observes the manager and calls this.
    func applyOwnedVoiceObservation() {
        guard let manager = voiceInputManager else { return }
        _ = manager.transcriptPresentationRevision
        _ = manager.currentTranscript
        _ = manager.state
        _ = manager.currentComposerCaptureFailure
        if ComposerShared.shouldSuppressKeyboardForActiveVoiceInput(manager, owner: .inlineComposer) {
            suppressKeyboard = true
        }
        if ComposerShared.captureFailure(manager, owner: .inlineComposer) != nil {
            discardFailedVoiceTake()
            return
        }
        guard let prefix = textBeforeRecording,
              ComposerShared.ownsVoiceInput(manager, owner: .inlineComposer) else { return }
        text = prefix + manager.currentTranscript
        controller?.apply()
        onNeedsLayout?()
    }

    func releaseVoice() {
        let manager = voiceInputManager
        let take = ComposerShared.takeIdentityForDismissedComposer(
            manager: manager,
            generation: voiceComposerGeneration
        )
        if let generation = voiceComposerGeneration {
            manager?.endComposer(generation: generation)
            voiceComposerGeneration = nil
        }
        Task { await ComposerShared.cancelVoiceInputOnDismiss(manager: manager, matching: take) }
        voiceInputManager = nil
    }

    func retryVoice() {
        Task {
            try? await startVoice(
                keyboardLanguage: keyboardLanguage,
                owner: .inlineComposer,
                baseText: text
            )
            controller?.apply()
        }
    }

    /// The prompt, then one host path per line. Agents read images by path.
    static func prompt(_ text: String, paths: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([trimmed].filter { !$0.isEmpty } + [paths.joined(separator: "\n")]).joined(separator: "\n\n")
    }

    func setText(_ text: String) { self.text = text }
    func setTextBeforeRecording(_ value: String?) { textBeforeRecording = value }
    func setPendingAttachments(_ value: [PendingAttachment]) {
        pendingAttachments = value
        controller?.apply()
        onNeedsLayout?()
    }
    func setPendingRepoPointers(_ value: [PendingFileReference]) {
        pendingRepoPointers = value
        controller?.apply()
        onNeedsLayout?()
    }
    func setBusyStreamingBehavior(_ value: StreamingBehavior) { streamingBehavior = value }
    func setSuppressKeyboard(_ value: Bool) { suppressKeyboard = value }
    func consumeFocusRequest() { focusRequestID = 0 }
    func setKeyboardLanguage(_ value: String?) { keyboardLanguage = value }
    func setInputFocused(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onNeedsLayout?()
        }
    }
    func performSend() { send() }
    func performStop() {}
    func performForceStop() {}
    func performExpand() {}
    func submitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) { completion(.completed) }
    func ignoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion) {
        completion(.completed)
    }

    func startVoice(
        keyboardLanguage: String?,
        owner: ComposerShared.VoiceInputOwner,
        baseText: String
    ) async throws {
        guard let manager = voiceInputManager else { return }
        try await ComposerShared.startVoiceInput(
            manager: manager,
            keyboardLanguage: keyboardLanguage,
            owner: owner,
            baseText: baseText,
            getText: { [weak self] in self?.text ?? "" },
            setText: { [weak self] in self?.text = $0 },
            getTextBeforeRecording: { [weak self] in self?.textBeforeRecording },
            setTextBeforeRecording: { [weak self] in self?.textBeforeRecording = $0 },
            getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
            setSuppressKeyboard: { [weak self] in self?.suppressKeyboard = $0 },
            getFocusRequestID: { [weak self] in self?.focusRequestID ?? 0 },
            setFocusRequestID: { [weak self] in self?.focusRequestID = $0 },
            prepare: { [weak self] in
                guard let self, let manager = self.voiceInputManager else { return }
                self.configureVoice(manager)
            }
        )
    }

    func stopVoice() async {
        guard let manager = voiceInputManager else { return }
        await ComposerShared.stopVoiceInput(
            manager: manager,
            getText: { [weak self] in self?.text ?? "" },
            setText: { [weak self] in self?.text = $0 },
            getTextBeforeRecording: { [weak self] in self?.textBeforeRecording },
            setTextBeforeRecording: { [weak self] in self?.textBeforeRecording = $0 }
        )
        controller?.apply()
    }

    func cancelVoice() async {
        guard let manager = voiceInputManager else { return }
        await ComposerShared.cancelVoiceInput(
            manager: manager,
            getTextBeforeRecording: { [weak self] in self?.textBeforeRecording },
            setTextBeforeRecording: { [weak self] in self?.textBeforeRecording = $0 },
            getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
            setSuppressKeyboard: { [weak self] in self?.suppressKeyboard = $0 }
        )
        controller?.apply()
    }

    func finishVoiceBeforeSubmit() async {
        guard let manager = voiceInputManager else { return }
        await ComposerShared.finishOwnedVoiceInputBeforeSubmit(
            manager: manager,
            owner: .inlineComposer,
            getText: { [weak self] in self?.text ?? "" },
            setText: { [weak self] in self?.text = $0 },
            getTextBeforeRecording: { [weak self] in self?.textBeforeRecording },
            setTextBeforeRecording: { [weak self] in self?.textBeforeRecording = $0 },
            getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
            setSuppressKeyboard: { [weak self] in self?.suppressKeyboard = $0 },
            restoreKeyboard: false
        )
    }

    func handlePastedImages(_ images: [UIImage]) {
        ComposerShared.handlePastedImages(
            images,
            getAttachments: { [weak self] in self?.pendingAttachments ?? [] },
            setAttachments: { [weak self] in self?.setPendingAttachments($0) }
        )
    }

    func insertSlashCommand(_ command: SlashCommand) {
        ComposerShared.insertSlashCommand(
            command,
            getText: { [weak self] in self?.text ?? "" },
            setText: { [weak self] in self?.text = $0 }
        )
        controller?.apply()
    }

    func insertFileSuggestion(_ suggestion: FileSuggestion) {
        ComposerShared.insertFileSuggestion(
            suggestion,
            getText: { [weak self] in self?.text ?? "" },
            setText: { [weak self] in self?.text = $0 },
            getPointers: { [weak self] in self?.pendingRepoPointers ?? [] },
            setPointers: { [weak self] in self?.setPendingRepoPointers($0) }
        )
        controller?.apply()
    }

    func removeAttachment(id: String) {
        ComposerShared.removeAttachment(
            id,
            getAttachments: { [weak self] in self?.pendingAttachments ?? [] },
            setAttachments: { [weak self] in self?.setPendingAttachments($0) }
        )
        controller?.apply()
        onNeedsLayout?()
    }

    func removeRepoPointer(id: String) {
        ComposerShared.removeFile(
            id,
            getPointers: { [weak self] in self?.pendingRepoPointers ?? [] },
            setPointers: { [weak self] in self?.setPendingRepoPointers($0) }
        )
        controller?.apply()
        onNeedsLayout?()
    }

    func importPhotoProviders(
        _ providers: [NSItemProvider],
        capturedGate: UInt64,
        capturedLocal: UInt64,
        currentLocal: @escaping () -> UInt64,
        onFailure: @escaping (String) -> Void
    ) {
        ComposerShared.importPhotoLibraryProviders(
            providers,
            getAttachments: { [weak self] in self?.pendingAttachments ?? [] },
            setAttachments: { [weak self] in self?.setPendingAttachments($0) },
            store: draftStore,
            shouldAccept: { capturedLocal == currentLocal() },
            onFailure: { message in
                Task { @MainActor in
                    onFailure(message)
                }
            }
        )
    }

    func addCapturedImage(_ image: UIImage) {
        ComposerShared.addCapturedImage(
            image,
            getAttachments: { [weak self] in self?.pendingAttachments ?? [] },
            setAttachments: { [weak self] in self?.setPendingAttachments($0) }
        )
    }

    func applyCanvas(
        attachment: PendingAttachment,
        recognizedText: String,
        replacingAttachmentID: String?
    ) -> Bool {
        let ok = ComposerShared.applyCanvasToComposer(
            attachment: attachment,
            recognizedText: recognizedText,
            getText: { [weak self] in self?.text ?? "" },
            setText: { [weak self] in self?.text = $0 },
            getAttachments: { [weak self] in self?.pendingAttachments ?? [] },
            setAttachments: { [weak self] in self?.setPendingAttachments($0) },
            replacingAttachmentID: replacingAttachmentID
        )
        controller?.apply()
        onNeedsLayout?()
        return ok
    }

    func loadSelectedFiles(
        _ result: Result<[URL], Error>,
        capturedGate: UInt64,
        capturedLocal: UInt64,
        currentLocal: @escaping () -> UInt64,
        onFailure: @escaping (String) -> Void
    ) {
        ComposerShared.loadSelectedFiles(
            result,
            getAttachments: { [weak self] in self?.pendingAttachments ?? [] },
            setAttachments: { [weak self] in self?.setPendingAttachments($0) },
            store: draftStore,
            shouldAccept: { capturedLocal == currentLocal() },
            onFailure: { message in
                Task { @MainActor in
                    onFailure(message)
                }
            }
        )
    }

    func notifyFileSuggestionContext(for text: String) {
        ComposerShared.notifyFileSuggestionContext(
            for: text,
            isBusy: false,
            onFileSuggestionQuery: nil
        )
    }

    func discardFailedVoiceTake() {
        ComposerShared.discardFailedTake(
            manager: voiceInputManager,
            owner: .inlineComposer,
            getText: { [weak self] in self?.text ?? "" },
            setText: { [weak self] in self?.text = $0 },
            getTextBeforeRecording: { [weak self] in self?.textBeforeRecording },
            setTextBeforeRecording: { [weak self] in self?.textBeforeRecording = $0 },
            getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
            setSuppressKeyboard: { [weak self] in self?.suppressKeyboard = $0 }
        )
        controller?.apply()
    }

    func restoreKeyboardFromSuppression() {
        ComposerShared.handleKeyboardRestore(
            getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
            setSuppressKeyboard: { [weak self] in self?.suppressKeyboard = $0 },
            getTextBeforeRecording: { [weak self] in self?.textBeforeRecording },
            setTextBeforeRecording: { [weak self] in self?.textBeforeRecording = $0 },
            voiceInputManager: voiceInputManager,
            expectedOwner: .inlineComposer
        )
        controller?.apply()
    }

    // MARK: - Send

    private func send() {
        failure = nil
        onFailureChange?(nil)
        guard !pendingAttachments.isEmpty else {
            do {
                try channel.submit(text)
                text = ""
                controller?.apply()
                onNeedsLayout?()
            } catch {
                failure = "Not sent. \(error.localizedDescription)"
                onFailureChange?(failure)
            }
            return
        }
        guard !uploading else { return }
        uploading = true
        controller?.apply()
        let attachments = pendingAttachments
        Task {
            defer {
                uploading = false
                controller?.apply()
                onNeedsLayout?()
            }
            do {
                var paths = [String]()
                for attachment in attachments {
                    let (data, ext) = try await Self.fileContents(attachment)
                    paths.append(try await channel.upload(data, fileExtension: ext))
                }
                try channel.submit(Self.prompt(text, paths: paths))
                text = ""
                pendingAttachments.removeAll { sent in attachments.contains { $0.id == sent.id } }
                controller?.apply()
                onNeedsLayout?()
            } catch {
                failure = "Not sent. \(error.localizedDescription)"
                onFailureChange?(failure)
            }
        }
    }

    private static func fileContents(_ attachment: PendingAttachment) async throws -> (Data, String) {
        let mimeType = attachment.imageAttachment?.mimeType ?? attachment.localMimeType
        let named = (attachment.displayName as NSString).pathExtension
        let ext = named.isEmpty
            ? mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? ""
            : named
        if let data = attachment.composerDraftData { return (data, ext) }
        if let url = attachment.localFileURL {
            let data = try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
            return (data, ext)
        }
        throw SSHTerminalUpload.Failure.rejected("\(attachment.displayName) has no local data to send.")
    }

    private func configureVoice(_ manager: VoiceInputManager) {
        guard let connection else { return }
        let serverId = connection.currentServerId ?? connection.credentials.map { "\($0.host):\($0.port)" } ?? ""
        voiceComposerGeneration = ComposerShared.prepareStandaloneVoiceInput(
            manager: manager,
            serverId: serverId,
            credentials: connection.credentials,
            connection: connection,
            playbackInterrupter: connection.audioPlayer,
            ownedGeneration: voiceComposerGeneration
        )
    }

}
