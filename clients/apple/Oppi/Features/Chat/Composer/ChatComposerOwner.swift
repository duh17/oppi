import UIKit

/// What a screen gives its composer: the bar's content (draft, session state,
/// action row), where edits go, its actions, and the expanded composer.
///
/// The owner reads `composerContent` and `isComposerExpanded` in its own
/// `updateProperties()`, so `@Observable` reads inside them re-run only the
/// composer, not the screen.
@MainActor
protocol ChatComposerSource: AnyObject {
    /// The bar's content. The owner replaces its own fields: keyboard
    /// suppression, focus requests, keyboard language, and the media epoch.
    var composerContent: ComposerBarContent { get }
    var composerDraftStore: ComposerDraftStore? { get }
    var composerMediaImportGate: ComposerMediaImportGate? { get }

    func composerSetText(_ text: String)
    func composerSetTextBeforeRecording(_ value: String?)
    func composerSetPendingAttachments(_ value: [PendingAttachment])
    func composerSetPendingRepoPointers(_ value: [PendingFileReference])
    func composerSetBusyStreamingBehavior(_ value: StreamingBehavior)

    /// The field gained or lost the keyboard. Most screens ignore it; the
    /// compact guided bar opens and closes its pills with it.
    func composerInputFocusDidChange(_ focused: Bool)
    func composerSend()
    func composerStop()
    func composerForceStop()
    func composerExpand()
    func composerSubmitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    )
    func composerIgnoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion)
    func composerFileSuggestionQuery(_ query: String?)
    func composerPrepareVoiceInput(_ manager: VoiceInputManager) async throws

    /// The expanded composer is up while this is true; the owner presents it
    /// over the screen and reports a close with `composerExpandedDidClose()`.
    var isComposerExpanded: Bool { get }
    func composerExpandedDidClose()
    func makeExpandedComposer() -> ExpandedComposerViewController
    /// The screen's current draft and session values for the open expanded composer.
    var expandedComposerLiveState: ExpandedComposerLiveState { get }
    /// What paces the inline Ask card's auto-advance; nil keeps the card's own.
    var composerAskAutoAdvanceController: AskInlineAutoAdvanceController? { get }
}

extension ChatComposerSource {
    var composerAskAutoAdvanceController: AskInlineAutoAdvanceController? { nil }
    func composerInputFocusDidChange(_ focused: Bool) {}
}

/// The chat input bar in UIKit: `ComposerBarController` with the dictation
/// failure notice above it and the busy-mode tip in its slot, the inline
/// voice wiring, focus and dictation requests, and the expanded composer.
/// A screen (the chat, Quick Session, the guided control composer) embeds
/// this controller as a child (the SSH terminal embeds `ComposerBarController`
/// the same way) and supplies a `ChatComposerSource`. Every height change
/// goes through `updateHeight()`, measured when it happens.
@MainActor
final class ChatComposerOwner: UIViewController, ComposerBarHosting {
    weak var source: ChatComposerSource?
    let bar = ComposerBarController()

    private let stack = UIStackView()
    private let failureView = ComposerDictationFailureView()
    private var heightConstraint: NSLayoutConstraint?
    private lazy var tipHost: FeatureEducationTipHostView = {
        let host = FeatureEducationTipHostView(
            tip: FeatureEducationTips.BusySendModeTip(),
            descriptor: FeatureEducationTips.busySendMode,
            insets: NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 2, trailing: 12),
            ownsHeight: false
        )
        host.onHeightChange = { [weak self, weak host] in
            guard let self, let host, self.bar.setBusyTipHeight(host.reservedHeight) else { return }
            self.updateHeight()
        }
        return host
    }()
    private var tipShown = false
    private let expandedPresenter = RouterModalPresenter()

    /// The last content read in `updateProperties()`, with this owner's own
    /// values and the bar's edits applied since.
    private var current: ComposerBarContent?
    private var suppressKeyboard = false
    private var focusRequestID = 0
    private var keyboardLanguage: String?
    private var lastCaptureFailureMessage: String?
    private var lastVoiceState: VoiceInputManager.State?
    private var lastTranscriptRevision: Int?
    private var lastNotifiedText: String?
    private var dictationTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        failureView.isHidden = true
        failureView.onRetry = { [weak self] in
            Task { await self?.startOwnedVoiceInput(owner: .inlineComposer) }
        }
        stack.addArrangedSubview(failureView)

        bar.host = self
        addChild(bar)
        bar.view.backgroundColor = .clear
        stack.addArrangedSubview(bar.view)
        bar.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: 60)
        height.priority = .required - 1
        heightConstraint = height
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
        ])
        expandedPresenter.anchor = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeight()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        expandedPresenter.sync()
    }

    override func updateProperties() {
        super.updateProperties()
        guard let source else { return }
        var content = source.composerContent
        applyOwnedValues(to: &content)
        current = content
        observeVoice(content.voiceInputManager)
        if content.text != lastNotifiedText {
            // An outside edit (a restored draft, a template) reaches the
            // suggestion lookup the same as typing.
            if lastNotifiedText != nil { notifyFileSuggestionContext(for: content.text) }
            lastNotifiedText = content.text
        }
        applyFailureNotice(content)
        bar.apply()
        updateBusyTip(content)
        updateExpandedComposer(source)
        updateHeight()
    }

    private func applyOwnedValues(to content: inout ComposerBarContent) {
        content.suppressKeyboard = suppressKeyboard
        content.focusRequestID = focusRequestID
        content.keyboardLanguage = keyboardLanguage
        content.mediaImportEpoch = source?.composerMediaImportGate?.epoch ?? 0
    }

    /// The bar asked for a change of its own value: apply it now, then let
    /// the bar re-read.
    private func patch(_ change: (inout ComposerBarContent) -> Void) {
        guard var content = current else { return }
        change(&content)
        current = content
    }

    // MARK: - Requests from the screen

    /// Raises the keyboard in the inline bar.
    func requestFocus() {
        suppressKeyboard = false
        focusRequestID += 1
        patch { $0.suppressKeyboard = false; $0.focusRequestID = focusRequestID }
        bar.apply()
    }

    /// Starts dictation for `owner` (the review-comment menu, Quick Session's
    /// dictation start) when the mic is idle.
    func requestDictation(owner: ComposerShared.VoiceInputOwner) {
        dictationTask?.cancel()
        dictationTask = Task { [weak self] in
            guard let self else { return }
            // The screen may have just handed the composer its microphone
            // (Quick Session claims it as it opens): read the source first.
            self.updatePropertiesIfNeeded()
            guard let manager = self.current?.voiceInputManager else { return }
            guard ComposerShared.canControlVoiceInput(manager, owner: owner) else { return }
            guard ComposerShared.micTapAction(for: manager.state) == .start else { return }
            await self.startOwnedVoiceInput(owner: owner)
        }
    }

    // MARK: - Layout

    private func updateHeight() {
        guard isViewLoaded else { return }
        let width = view.bounds.width >= 280 && view.bounds.width < 10_000 ? view.bounds.width : 390
        var height = bar.sizeThatFits(width: width).height
        if !failureView.isHidden {
            height += failureView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height + stack.spacing
        }
        height = max(ceil(height), 1)
        guard let heightConstraint, abs(heightConstraint.constant - height) > 0.5 else { return }
        heightConstraint.constant = height
        view.superview?.setNeedsLayout()
    }

    private func applyFailureNotice(_ content: ComposerBarContent) {
        if let failure = ComposerShared.captureFailure(content.voiceInputManager, owner: .inlineComposer) {
            failureView.apply(message: failure.message, colors: content.colors)
            failureView.isHidden = false
        } else {
            failureView.isHidden = true
        }
    }

    /// The busy-mode tip claims height only while it is presented.
    private func updateBusyTip(_ content: ComposerBarContent) {
        let show = ComposerPolicy.showsBusyModeSelector(
            isBusy: content.isBusy,
            hasAskRequest: content.askRequest != nil
        )
        guard show else {
            if tipShown {
                tipShown = false
                tipHost.stop()
                bar.installBusyTip(nil)
            }
            return
        }
        guard !tipShown else { return }
        tipShown = true
        bar.installBusyTip(tipHost)
        tipHost.start()
    }

    // MARK: - Voice

    /// The inline bar's voice take: a failed take restores the draft, an
    /// active take hides the keyboard, and the live transcript follows the
    /// text typed before recording.
    private func observeVoice(_ manager: VoiceInputManager?) {
        guard let manager else { return }
        let failureMessage = ComposerShared.captureFailure(manager, owner: .inlineComposer)?.message
        if failureMessage != lastCaptureFailureMessage {
            lastCaptureFailureMessage = failureMessage
            discardFailedVoiceTake()
        }
        let state = manager.state
        if state != lastVoiceState {
            lastVoiceState = state
            if ComposerShared.shouldSuppressKeyboardForActiveVoiceInput(manager, owner: .inlineComposer) {
                suppressKeyboard = true
                patch { $0.suppressKeyboard = true }
            }
        }
        let revision = manager.transcriptPresentationRevision
        if revision != lastTranscriptRevision {
            lastTranscriptRevision = revision
            if let prefix = current?.textBeforeRecording,
               ComposerShared.ownsVoiceInput(manager, owner: .inlineComposer) {
                setText(prefix + manager.currentTranscript)
            }
        }
    }

    private func startOwnedVoiceInput(owner: ComposerShared.VoiceInputOwner) async {
        guard let manager = current?.voiceInputManager else { return }
        guard ComposerShared.canControlVoiceInput(manager, owner: owner) else { return }
        do {
            try await startVoice(
                keyboardLanguage: keyboardLanguage,
                owner: owner,
                baseText: current?.text ?? ""
            )
        } catch is CancellationError {
        } catch {
            let alert = UIAlertController(
                title: "Couldn't Start Dictation",
                message: error.localizedDescription.isEmpty ? "Please try again." : error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            Router.topPresenter(from: self).present(alert, animated: true)
        }
    }

    // MARK: - Expanded composer

    private func updateExpandedComposer(_ source: ChatComposerSource) {
        guard let root = HostFactory.root(near: self) else { return }
        expandedPresenter.clearItem = { [weak self] in self?.source?.composerExpandedDidClose() }
        if source.isComposerExpanded {
            // `.overFullScreen` keeps the screen in the window, so it keeps
            // rendering under the composer: the composer's model picker,
            // which the screen presents, and the values it reads stay live.
            expandedPresenter.request = RouterModalPresenter.Request(
                id: AnyHashable("expanded-composer"),
                presentation: ModalPresentation(style: .overFullScreen).inNavigation(),
                root: root,
                screen: .liveController({ [weak self] in
                    guard let composer = self?.source?.makeExpandedComposer() else {
                        preconditionFailure("The expanded composer presents only while its screen is alive")
                    }
                    return composer
                }, update: { [weak self] (composer: ExpandedComposerViewController) in
                    guard let live = self?.source?.expandedComposerLiveState else { return }
                    composer.live = live
                })
            )
            // Live updates while it is up: read here so the owner re-runs.
            _ = source.expandedComposerLiveState
        } else {
            expandedPresenter.request = nil
        }
        expandedPresenter.sync()
    }

    // MARK: - ComposerBarHosting

    var content: ComposerBarContent {
        if let current { return current }
        guard let source else {
            preconditionFailure("ChatComposerOwner needs its source before the bar reads content")
        }
        var content = source.composerContent
        applyOwnedValues(to: &content)
        return content
    }

    func setText(_ text: String) {
        patch { $0.text = text }
        source?.composerSetText(text)
    }

    func setTextBeforeRecording(_ value: String?) {
        patch { $0.textBeforeRecording = value }
        source?.composerSetTextBeforeRecording(value)
    }

    func setPendingAttachments(_ value: [PendingAttachment]) {
        patch { $0.pendingAttachments = value }
        source?.composerSetPendingAttachments(value)
    }

    func setPendingRepoPointers(_ value: [PendingFileReference]) {
        patch { $0.pendingRepoPointers = value }
        source?.composerSetPendingRepoPointers(value)
    }

    func setBusyStreamingBehavior(_ value: StreamingBehavior) {
        patch { $0.busyStreamingBehavior = value }
        source?.composerSetBusyStreamingBehavior(value)
    }

    func setSuppressKeyboard(_ value: Bool) {
        suppressKeyboard = value
        patch { $0.suppressKeyboard = value }
    }

    func consumeFocusRequest() {
        focusRequestID = 0
        patch { $0.focusRequestID = 0 }
    }

    func setKeyboardLanguage(_ value: String?) {
        keyboardLanguage = value
        patch { $0.keyboardLanguage = value }
    }

    func setInputFocused(_ value: Bool) {
        source?.composerInputFocusDidChange(value)
        // The action row comes and goes with focus: measure again.
        updateHeight()
    }

    func performSend() { source?.composerSend() }
    func performStop() { source?.composerStop() }
    func performForceStop() { source?.composerForceStop() }
    func performExpand() { source?.composerExpand() }

    func submitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) {
        source?.composerSubmitAsk(request, answers: answers, completion: completion)
    }

    func ignoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion) {
        source?.composerIgnoreAsk(request, completion: completion)
    }

    private var textAccess: (get: () -> String, set: (String) -> Void) {
        ({ [weak self] in self?.current?.text ?? "" }, { [weak self] in self?.setText($0) })
    }

    private var prefixAccess: (get: () -> String?, set: (String?) -> Void) {
        ({ [weak self] in self?.current?.textBeforeRecording }, { [weak self] in self?.setTextBeforeRecording($0) })
    }

    private var suppressAccess: (get: () -> Bool, set: (Bool) -> Void) {
        ({ [weak self] in self?.suppressKeyboard ?? false }, { [weak self] in self?.setSuppressKeyboard($0) })
    }

    private var attachmentsAccess: (get: () -> [PendingAttachment], set: ([PendingAttachment]) -> Void) {
        ({ [weak self] in self?.current?.pendingAttachments ?? [] }, { [weak self] in self?.setPendingAttachments($0) })
    }

    private var pointersAccess: (get: () -> [PendingFileReference], set: ([PendingFileReference]) -> Void) {
        ({ [weak self] in self?.current?.pendingRepoPointers ?? [] }, { [weak self] in self?.setPendingRepoPointers($0) })
    }

    func startVoice(
        keyboardLanguage: String?,
        owner: ComposerShared.VoiceInputOwner,
        baseText: String
    ) async throws {
        guard let manager = current?.voiceInputManager else { return }
        try await ComposerShared.startVoiceInput(
            manager: manager,
            keyboardLanguage: keyboardLanguage,
            owner: owner,
            baseText: baseText,
            getText: textAccess.get,
            setText: textAccess.set,
            getTextBeforeRecording: prefixAccess.get,
            setTextBeforeRecording: prefixAccess.set,
            getSuppressKeyboard: suppressAccess.get,
            setSuppressKeyboard: suppressAccess.set,
            getFocusRequestID: { [weak self] in self?.focusRequestID ?? 0 },
            setFocusRequestID: { [weak self] value in
                guard let self else { return }
                self.focusRequestID = value
                self.patch { $0.focusRequestID = value }
            },
            prepare: { [weak self] in
                try await self?.source?.composerPrepareVoiceInput(manager)
            }
        )
        bar.apply()
    }

    func stopVoice() async {
        guard let manager = current?.voiceInputManager else { return }
        await ComposerShared.stopVoiceInput(
            manager: manager,
            getText: textAccess.get,
            setText: textAccess.set,
            getTextBeforeRecording: prefixAccess.get,
            setTextBeforeRecording: prefixAccess.set
        )
        bar.apply()
    }

    func cancelVoice() async {
        guard let manager = current?.voiceInputManager else { return }
        await ComposerShared.cancelVoiceInput(
            manager: manager,
            getTextBeforeRecording: prefixAccess.get,
            setTextBeforeRecording: prefixAccess.set,
            getSuppressKeyboard: suppressAccess.get,
            setSuppressKeyboard: suppressAccess.set
        )
        bar.apply()
    }

    func finishVoiceBeforeSubmit() async {
        guard let manager = current?.voiceInputManager else { return }
        await ComposerShared.finishOwnedVoiceInputBeforeSubmit(
            manager: manager,
            owner: .inlineComposer,
            getText: textAccess.get,
            setText: textAccess.set,
            getTextBeforeRecording: prefixAccess.get,
            setTextBeforeRecording: prefixAccess.set,
            getSuppressKeyboard: suppressAccess.get,
            setSuppressKeyboard: suppressAccess.set,
            restoreKeyboard: false
        )
    }

    func handlePastedImages(_ images: [UIImage]) {
        ComposerShared.handlePastedImages(
            images,
            getAttachments: attachmentsAccess.get,
            setAttachments: attachmentsAccess.set
        )
    }

    func insertSlashCommand(_ command: SlashCommand) {
        ComposerShared.insertSlashCommand(command, getText: textAccess.get, setText: textAccess.set)
    }

    func insertFileSuggestion(_ suggestion: FileSuggestion) {
        ComposerShared.insertFileSuggestion(
            suggestion,
            getText: textAccess.get,
            setText: textAccess.set,
            getPointers: pointersAccess.get,
            setPointers: pointersAccess.set
        )
    }

    func removeAttachment(id: String) {
        ComposerShared.removeAttachment(
            id,
            getAttachments: attachmentsAccess.get,
            setAttachments: attachmentsAccess.set
        )
    }

    func removeRepoPointer(id: String) {
        ComposerShared.removeFile(id, getPointers: pointersAccess.get, setPointers: pointersAccess.set)
    }

    func importPhotoProviders(
        _ providers: [NSItemProvider],
        capturedGate: UInt64,
        capturedLocal: UInt64,
        currentLocal: @escaping () -> UInt64,
        onFailure: @escaping (String) -> Void
    ) {
        let gate = source?.composerMediaImportGate
        ComposerShared.importPhotoLibraryProviders(
            providers,
            getAttachments: attachmentsAccess.get,
            setAttachments: attachmentsAccess.set,
            store: source?.composerDraftStore,
            shouldAccept: {
                (gate?.isCurrent(capturedGate) ?? true) && capturedLocal == currentLocal()
            },
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
            getAttachments: attachmentsAccess.get,
            setAttachments: attachmentsAccess.set
        )
    }

    func applyCanvas(
        attachment: PendingAttachment,
        recognizedText: String,
        replacingAttachmentID: String?
    ) -> Bool {
        ComposerShared.applyCanvasToComposer(
            attachment: attachment,
            recognizedText: recognizedText,
            getText: textAccess.get,
            setText: textAccess.set,
            getAttachments: attachmentsAccess.get,
            setAttachments: attachmentsAccess.set,
            replacingAttachmentID: replacingAttachmentID
        )
    }

    func loadSelectedFiles(
        _ result: Result<[URL], Error>,
        capturedGate: UInt64,
        capturedLocal: UInt64,
        currentLocal: @escaping () -> UInt64,
        onFailure: @escaping (String) -> Void
    ) {
        let gate = source?.composerMediaImportGate
        ComposerShared.loadSelectedFiles(
            result,
            getAttachments: attachmentsAccess.get,
            setAttachments: attachmentsAccess.set,
            store: source?.composerDraftStore,
            shouldAccept: {
                (gate?.isCurrent(capturedGate) ?? true) && capturedLocal == currentLocal()
            },
            onFailure: { message in
                Task { @MainActor in
                    onFailure(message)
                }
            }
        )
    }

    func notifyFileSuggestionContext(for text: String) {
        lastNotifiedText = text
        ComposerShared.notifyFileSuggestionContext(
            for: text,
            isBusy: current?.isBusy ?? false,
            onFileSuggestionQuery: { [weak self] in self?.source?.composerFileSuggestionQuery($0) }
        )
    }

    func discardFailedVoiceTake() {
        ComposerShared.discardFailedTake(
            manager: current?.voiceInputManager,
            owner: .inlineComposer,
            getText: textAccess.get,
            setText: textAccess.set,
            getTextBeforeRecording: prefixAccess.get,
            setTextBeforeRecording: prefixAccess.set,
            getSuppressKeyboard: suppressAccess.get,
            setSuppressKeyboard: suppressAccess.set
        )
    }

    func restoreKeyboardFromSuppression() {
        ComposerShared.handleKeyboardRestore(
            getSuppressKeyboard: suppressAccess.get,
            setSuppressKeyboard: suppressAccess.set,
            getTextBeforeRecording: prefixAccess.get,
            setTextBeforeRecording: prefixAccess.set,
            voiceInputManager: current?.voiceInputManager,
            expectedOwner: .inlineComposer
        )
    }

    func barHeightDidChange() {
        updateHeight()
    }

    var askAutoAdvanceController: AskInlineAutoAdvanceController? {
        source?.composerAskAutoAdvanceController
    }
}
