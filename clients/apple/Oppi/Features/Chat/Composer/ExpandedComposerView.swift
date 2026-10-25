import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// What the expanded composer shows that its presenter can change while it is
/// open: the draft, suggestions, session pills, busy state, and theme. The
/// presenter sends a fresh copy every time it re-renders
/// (`RouterScreen.liveController`), the way hosted SwiftUI content refreshes.
struct ExpandedComposerLiveState {
    var text: String
    var textBeforeRecording: String?
    var pendingAttachments: [PendingAttachment] = []
    var pendingRepoPointers: [PendingFileReference] = []
    var isBusy = false
    var busyStreamingBehavior: StreamingBehavior = .followUp
    var slashCommands: [SlashCommand] = []
    var fileSuggestions: [FileSuggestion] = []
    var session: Session?
    var modelOverride: String?
    var providerOverride: String?
    var thinkingLevel: ThinkingLevel = .medium
    var supportedThinkingLevels: [ThinkingLevel] = ThinkingLevel.allCases
    var allowsEmptySubmit = false
    var isSubmitInFlight = false
    var colors: ComposerThemeColors
    var thinkingTint: UIColor
}

/// Fixed for one presentation: callbacks, titles, and which controls show.
/// The chat composer uses the defaults; the extension editor turns attachments,
/// the session pills, and command-prefix mode off and keeps the sheet open
/// until its response lands.
struct ExpandedComposerConfiguration {
    var voiceInputManager: VoiceInputManager?
    var onPrepareVoiceInput: ((VoiceInputManager) async throws -> Void)?
    /// Offers Live Voice in the mic's long-press menu (Quick Session starts a voice session).
    var onLiveVoiceSelected: (() -> Void)?
    var onSend: () -> Void
    var onCancel: (() -> Void)?
    var onModelTap: () -> Void = {}
    var onThinkingSelect: (ThinkingLevel) -> Void = { _ in }
    var onSaveThinkingAsDefault: (() -> Void)?
    var onFileSuggestionQuery: ((String?) -> Void)?
    var onTextChange: (String) -> Void
    var onTextBeforeRecordingChange: (String?) -> Void = { _ in }
    var onAttachmentsChange: ([PendingAttachment]) -> Void = { _ in }
    var onRepoPointersChange: ([PendingFileReference]) -> Void = { _ in }
    /// Runs once when the presentation goes away, however it was closed.
    var onClose: (() -> Void)?
    var composerDraftStore: ComposerDraftStore?
    var mediaImportGate: ComposerMediaImportGate?
    var titleOverride: String?
    var headerMessage: String?
    var cancelTitle = "Done"
    var submitTitle = "Send"
    var showsAttachmentControls = true
    var showsVoiceInputControl = true
    var showsSessionToolbar = true
    var showsCounters = true
    var usesCommandPrefixMode = true
    var autoFocusOnAppear = false
    var dismissesOnCancel = true
    var dismissesOnSubmit = true
    var preservesVoiceInputOnDismiss = false
    var editorAccessibilityIdentifier = "expanded.composer.editor"
    var cancelAccessibilityIdentifier = "expanded.composer.cancel"
    var submitAccessibilityIdentifier = "expanded.composer.submit"
}

/// Full-screen composer for long-form text. Opens over the chat from the
/// composer's expand button (`.overFullScreen`, so the chat underneath keeps
/// rendering and the draft stays shared both ways) and serves the extension
/// editor.
///
/// ```
/// ┌─────────────────────────────┐
/// │ ✕        Compose         ➤  │  navigation bar
/// ├─────────────────────────────┤
/// │ [header message]            │  extension editor only
/// │ [dictation failure]         │  conditional
/// │  Full-height text editor    │
/// │ [/ or @ suggestions]        │  conditional
/// ├─────────────────────────────┤
/// │ [attachments] [file pills]  │  conditional
/// │ [+] [mic]     model  think  │
/// │                 3L 12W 64C  │
/// └─────────────────────────────┘
/// ```
@MainActor
final class ExpandedComposerViewController: UIViewController, UITextViewDelegate,
    PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate,
    UIDocumentPickerDelegate {
    /// The presenter's current values. Setting it redraws; the draft the user
    /// is editing only moves when the presenter's copy actually differs.
    var live: ExpandedComposerLiveState {
        didSet { if isViewLoaded { applyChrome() } }
    }

    private let configuration: ExpandedComposerConfiguration

    private let headerWrap = UIView()
    private let headerLabel = UILabel()
    private let failureWrap = UIView()
    private let failureView = ComposerDictationFailureView()
    private let textView = PastableUITextView()
    private let suggestionStack = UIStackView()
    private let slashPanel = ComposerSuggestionPanelView()
    private let filePanel = ComposerSuggestionPanelView()
    private let bottomBar = UIView()
    private let bottomDivider = UIView()
    private let attachmentStrip = ComposerAttachmentStripView()
    private let filePillStrip = ComposerFilePillStripView()
    private let attachButton = ComposerGlassPillButton()
    private let micButton = MicButtonChromeView()
    private let modelButton = ComposerToolbarPillButton()
    private let thinkingButton = ComposerToolbarPillButton()
    private let countersLabel = UILabel()
    private let controlRow = UIStackView()

    private var keyboardLanguage: String?
    private var focusRequestID = 0
    private var suppressKeyboard = false
    private var isHandlingVoiceLifecycle = false
    private var localMediaImportEpoch: UInt64 = 0
    private var lastSubmitInFlight = false
    private var canvasBackgroundImage: UIImage?
    private var canvasReplacingAttachmentID: String?
    private var didAutoFocus = false
    private var didClose = false
    nonisolated(unsafe) private var inputModeObserver: NSObjectProtocol?

    init(configuration: ExpandedComposerConfiguration, live: ExpandedComposerLiveState) {
        self.configuration = configuration
        self.live = live
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let inputModeObserver {
            NotificationCenter.default.removeObserver(inputModeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHierarchy()
        configureNavigation()
        inputModeObserver = NotificationCenter.default.addObserver(
            forName: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateKeyboardLanguage() }
        }
        applyChrome()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if ComposerShared.shouldSuppressKeyboardForActiveVoiceInput(
            configuration.voiceInputManager,
            owner: .expandedComposer
        ) {
            suppressKeyboard = true
            focusRequestID &+= 1
            textView.setKeyboardSuppressed(true)
            textView.becomeFirstResponder()
        } else if configuration.autoFocusOnAppear, !didAutoFocus {
            didAutoFocus = true
            textView.becomeFirstResponder()
            textView.moveCaretToEnd()
            updateKeyboardLanguage()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let closing = isBeingDismissed || navigationController?.isBeingDismissed == true
            || presentingViewController == nil
        guard closing, !didClose else { return }
        didClose = true
        configuration.onClose?()
    }

    /// Voice state is `@Observable`; reading it here re-runs this on every
    /// transcript, spectrum, or failure change (iOS 26 observation tracking).
    override func updateProperties() {
        super.updateProperties()
        _ = AppLockService.shared.isLocked
        textView.hideFromAccessibility(whileLocked: AppLockService.shared.isLocked)
        if let manager = configuration.voiceInputManager {
            _ = manager.state
            _ = manager.voiceSpectrum
            _ = manager.transcriptPresentationRevision
            _ = manager.currentComposerCaptureFailure
            ComposerShared.discardFailedTake(
                manager: manager,
                owner: .expandedComposer,
                getText: { [weak self] in self?.live.text ?? "" },
                setText: { [weak self] value in self?.setComposerText(value) },
                getTextBeforeRecording: { [weak self] in self?.live.textBeforeRecording },
                setTextBeforeRecording: { [weak self] value in self?.setPrefix(value) },
                getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
                setSuppressKeyboard: { [weak self] value in self?.suppressKeyboard = value }
            )
            if let prefix = live.textBeforeRecording,
               ComposerShared.ownsVoiceInput(manager, owner: .expandedComposer) {
                let next = prefix + manager.currentTranscript
                if next != live.text { setComposerText(next) }
            }
        }
        applyChrome()
    }

    // MARK: - Build

    private func buildHierarchy() {
        let root = UIStackView()
        root.axis = .vertical
        root.alignment = .fill
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        headerLabel.font = UIFont.preferredFont(forTextStyle: .body)
        headerLabel.adjustsFontForContentSizeCategory = true
        headerLabel.numberOfLines = 0
        pin(headerLabel, in: headerWrap, insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))

        failureView.onRetry = { [weak self] in self?.handleMicTap() }
        pin(failureView, in: failureWrap, insets: UIEdgeInsets(top: 8, left: 16, bottom: 0, right: 16))

        textView.delegate = self
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.accessibilityIdentifier = configuration.editorAccessibilityIdentifier
        textView.installKeyboardRestoreGesture()
        textView.setAllowKeyboardRestoreOnTap(true)
        textView.onPasteImages = { [weak self] images in
            guard let self, self.configuration.showsAttachmentControls else { return }
            ComposerShared.handlePastedImages(
                images,
                getAttachments: { self.live.pendingAttachments },
                setAttachments: { self.setAttachments($0) }
            )
        }
        textView.onCommandEnter = { [weak self] in self?.handleSend() }
        textView.onAlternateEnter = { [weak self] in self?.handleSend() }
        textView.onKeyboardRestoreRequest = { [weak self] in
            guard let self else { return }
            ComposerShared.handleKeyboardRestore(
                getSuppressKeyboard: { self.suppressKeyboard },
                setSuppressKeyboard: { self.suppressKeyboard = $0 },
                getTextBeforeRecording: { self.live.textBeforeRecording },
                setTextBeforeRecording: { self.setPrefix($0) },
                voiceInputManager: self.configuration.voiceInputManager,
                expectedOwner: .expandedComposer
            )
            self.applyChrome()
        }
        applyComposerInputTraits(to: textView, autocorrectionEnabled: true)

        slashPanel.onSelectSlash = { [weak self] command in
            guard let self else { return }
            ComposerShared.insertSlashCommand(
                command,
                getText: { self.live.text },
                setText: { self.setComposerText($0) }
            )
        }
        filePanel.onSelectFile = { [weak self] suggestion in
            guard let self else { return }
            ComposerShared.insertFileSuggestion(
                suggestion,
                getText: { self.live.text },
                setText: { self.setComposerText($0) },
                getPointers: { self.live.pendingRepoPointers },
                setPointers: { self.setPointers($0) }
            )
        }
        suggestionStack.axis = .vertical
        suggestionStack.spacing = 8
        suggestionStack.isLayoutMarginsRelativeArrangement = true
        suggestionStack.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
        suggestionStack.addArrangedSubview(slashPanel)
        suggestionStack.addArrangedSubview(filePanel)

        attachmentStrip.onAnnotate = { [weak self] attachment in
            self?.canvasBackgroundImage = ComposerShared.image(forPendingAttachment: attachment)
            self?.canvasReplacingAttachmentID = attachment.id
            self?.presentCanvas()
        }
        attachmentStrip.onRemove = { [weak self] id in
            guard let self else { return }
            ComposerShared.removeAttachment(
                id,
                getAttachments: { self.live.pendingAttachments },
                setAttachments: { self.setAttachments($0) }
            )
        }
        filePillStrip.onRemove = { [weak self] id in
            guard let self else { return }
            ComposerShared.removeFile(
                id,
                getPointers: { self.live.pendingRepoPointers },
                setPointers: { self.setPointers($0) }
            )
        }

        attachButton.showsMenuAsPrimaryAction = true
        attachButton.preferredMenuElementOrder = .priority
        attachButton.menu = attachmentMenu()
        attachButton.accessibilityIdentifier = "expanded.attach"
        attachButton.accessibilityLabel = "Add attachment"
        micButton.addAction(UIAction { [weak self] _ in self?.handleMicTap() }, for: .touchUpInside)
        micButton.accessibilityIdentifier = "expanded.voiceInput"
        micButton.menuProvider = { [weak self] in self?.voiceEntryMenu() }
        modelButton.addAction(UIAction { [weak self] _ in self?.configuration.onModelTap() }, for: .touchUpInside)
        modelButton.accessibilityIdentifier = "session.toolbar.model"
        modelButton.accessibilityLabel = "Model"
        thinkingButton.addAction(UIAction { [weak self] _ in self?.presentThinkingPicker() }, for: .touchUpInside)
        thinkingButton.accessibilityIdentifier = "session.toolbar.thinking"
        thinkingButton.accessibilityLabel = "Thinking level"
        countersLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        countersLabel.textAlignment = .right

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlRow.axis = .horizontal
        controlRow.alignment = .center
        controlRow.spacing = 6
        for view in [attachButton, micButton, spacer, modelButton, thinkingButton] as [UIView] {
            controlRow.addArrangedSubview(view)
        }
        NSLayoutConstraint.activate([
            micButton.widthAnchor.constraint(equalToConstant: 32),
            micButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        let bottomStack = UIStackView(arrangedSubviews: [attachmentStrip, filePillStrip, controlRow, countersLabel])
        bottomStack.axis = .vertical
        bottomStack.spacing = 8
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(bottomDivider)
        bottomBar.addSubview(bottomStack)
        NSLayoutConstraint.activate([
            bottomDivider.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            bottomDivider.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
            bottomStack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            bottomStack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            bottomStack.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 8),
            bottomStack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -8),
        ])

        for view in [headerWrap, failureWrap, textView, suggestionStack, bottomBar] as [UIView] {
            root.addArrangedSubview(view)
        }
    }

    private func pin(_ child: UIView, in container: UIView, insets: UIEdgeInsets) {
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
        ])
    }

    private func configureNavigation() {
        let cancel = UIBarButtonItem(
            title: configuration.cancelTitle,
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.handleCancel() }
        )
        cancel.accessibilityIdentifier = configuration.cancelAccessibilityIdentifier
        let submit = UIBarButtonItem(
            title: configuration.submitTitle,
            image: UIImage(systemName: "paperplane"),
            primaryAction: UIAction { [weak self] _ in self?.handleSend() }
        )
        submit.accessibilityIdentifier = configuration.submitAccessibilityIdentifier
        navigationItem.leftBarButtonItem = cancel
        navigationItem.rightBarButtonItem = submit
        navigationItem.largeTitleDisplayMode = .never
    }

    // MARK: - Derived state

    /// No dictation while a Live Voice call holds the microphone.
    private var voiceInputManager: VoiceInputManager? {
        ComposerShared.dictation(configuration.voiceInputManager, near: viewIfLoaded)
    }

    private var composerDisplayText: String {
        ComposerShared.currentComposerText(
            storedText: live.text,
            textBeforeRecording: live.textBeforeRecording,
            manager: voiceInputManager,
            owner: .expandedComposer
        )
    }

    private var canSend: Bool {
        let attachments = configuration.showsAttachmentControls
        let hasImages = attachments && live.pendingAttachments.contains { $0.source == .image }
        let hasFiles = attachments
            && (live.pendingAttachments.contains { $0.source != .image } || !live.pendingRepoPointers.isEmpty)
        let hasText = !composerDisplayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || hasImages || hasFiles
    }

    private var canSubmit: Bool {
        !live.isSubmitInFlight && !isHandlingVoiceLifecycle && (live.allowsEmptySubmit || canSend)
    }

    private var expandedTitle: String {
        if let title = configuration.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        guard live.isBusy else { return "Compose" }
        return live.busyStreamingBehavior == .steer ? "Steer Agent" : "Queue Follow-up"
    }

    private var trimmedHeaderMessage: String? {
        let message = configuration.headerMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message, !message.isEmpty else { return nil }
        return message
    }

    // MARK: - Apply

    private func applyChrome() {
        let colors = live.colors
        if live.isSubmitInFlight, !lastSubmitInFlight {
            localMediaImportEpoch &+= 1
        }
        lastSubmitInFlight = live.isSubmitInFlight
        view.backgroundColor = colors.bg
        navigationItem.title = expandedTitle
        applyNavigationBarAppearance(colors)

        headerWrap.isHidden = trimmedHeaderMessage == nil
        headerWrap.backgroundColor = colors.bgDark
        headerLabel.text = trimmedHeaderMessage
        headerLabel.textColor = colors.fg

        if let failure = ComposerShared.captureFailure(voiceInputManager, owner: .expandedComposer) {
            failureView.apply(message: failure.message, colors: colors)
            failureWrap.isHidden = false
        } else {
            failureWrap.isHidden = true
        }

        let visible = configuration.usesCommandPrefixMode
            ? ComposerShared.visibleComposerText(composerDisplayText)
            : composerDisplayText
        let font = UIFont.preferredFont(forTextStyle: .body)
        textView.font = font
        textView.tintColor = colors.blue
        textView.applyStyledText(
            visible,
            font: font,
            baseColor: colors.fg,
            volatileSuffixLength: ComposerShared.volatileSuffixLength(
                manager: voiceInputManager,
                owner: .expandedComposer
            ),
            volatileColor: colors.blue,
            volatileBackgroundColor: colors.blue.withAlphaComponent(0.20),
            correctionRanges: ComposerShared.correctionRanges(
                manager: voiceInputManager,
                textBeforeRecording: live.textBeforeRecording,
                owner: .expandedComposer
            ),
            correctionUnderlineColor: colors.orange,
            scrollCaretToVisible: true
        )
        if textView.isKeyboardSuppressed != suppressKeyboard {
            textView.setKeyboardSuppressed(suppressKeyboard)
        }

        applySuggestions(colors: colors)
        applyBottomBar(colors: colors)

        let navigationEnabled = !live.isSubmitInFlight && !isHandlingVoiceLifecycle
        navigationItem.leftBarButtonItem?.isEnabled = navigationEnabled
        navigationItem.leftBarButtonItem?.tintColor = colors.fgDim
        navigationItem.rightBarButtonItem?.isEnabled = canSubmit
        navigationItem.rightBarButtonItem?.tintColor = canSubmit ? colors.blue : colors.comment
    }

    private func applyNavigationBarAppearance(_ colors: ComposerThemeColors) {
        guard let bar = navigationController?.navigationBar else { return }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = colors.bgDark
        appearance.titleTextAttributes = [.foregroundColor: colors.fg]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        bar.tintColor = colors.blue
    }

    private func applySuggestions(colors: ComposerThemeColors) {
        let context = ComposerAutocomplete.context(for: live.text, isBusy: live.isBusy)
        var slash: [SlashCommand] = []
        if case .slash(let query) = context {
            slash = ComposerAutocomplete.slashSuggestions(query: query, commands: live.slashCommands)
        }
        slashPanel.apply(content: slash.isEmpty ? .empty : .slash(slash), colors: colors)
        var showsFiles = false
        if case .atFile = context { showsFiles = !live.fileSuggestions.isEmpty }
        filePanel.apply(content: showsFiles ? .files(live.fileSuggestions) : .empty, colors: colors)
        suggestionStack.isHidden = slash.isEmpty && !showsFiles
    }

    private func applyBottomBar(colors: ComposerThemeColors) {
        let showsAttachments = configuration.showsAttachmentControls
        bottomBar.backgroundColor = colors.bgDark
        bottomDivider.backgroundColor = colors.comment.withAlphaComponent(0.2)

        attachmentStrip.apply(
            attachments: live.pendingAttachments,
            colors: colors,
            allowsMutation: !live.isSubmitInFlight
        )
        attachmentStrip.isHidden = !showsAttachments || live.pendingAttachments.isEmpty
        filePillStrip.apply(pointers: live.pendingRepoPointers, colors: colors)
        filePillStrip.isHidden = !showsAttachments || live.pendingRepoPointers.isEmpty

        attachButton.isHidden = !showsAttachments
        attachButton.isEnabled = !live.isSubmitInFlight
        attachButton.apply(title: nil, systemImage: "plus", colors: colors, symbolPointSize: 11)

        let showsMic = configuration.showsVoiceInputControl && voiceInputManager != nil
        micButton.isHidden = !showsMic
        if showsMic, let manager = voiceInputManager {
            let presentation = ComposerShared.micButtonPresentation(for: manager, owner: .expandedComposer)
            micButton.apply(presentation: presentation, accentColor: colors.blue, diameter: 32)
            micButton.isEnabled = presentation.isEnabled
            micButton.accessibilityLabel = presentation.accessibilityLabel
            micButton.accessibilityValue = presentation.accessibilityValue
        }
        let offersLiveVoice = showsMic && configuration.onLiveVoiceSelected != nil
        micButton.isContextMenuInteractionEnabled = offersLiveVoice
        // VoiceOver reaches the same owner action as the long-press menu.
        micButton.accessibilityCustomActions = offersLiveVoice
            ? [UIAccessibilityCustomAction(name: "Live Voice") { [weak self] _ in
                self?.handleLiveVoiceChoice()
                return true
            }]
            : nil

        let showsToolbar = configuration.showsSessionToolbar
        modelButton.isHidden = !showsToolbar
        thinkingButton.isHidden = !showsToolbar
        if showsToolbar {
            let model = live.modelOverride ?? live.session?.model
            let modelTitle = model.flatMap { $0.isEmpty ? nil : shortModelName($0) } ?? "Model"
            let provider: String? = {
                if let override = live.providerOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !override.isEmpty {
                    return override
                }
                return model.flatMap(providerFromModel)
            }()
            let icon = provider.map { ComposerProviderIconRenderer.image(provider: $0, size: 11, colors: colors) }
            modelButton.apply(title: modelTitle, icon: icon, tint: colors.fg, showsChevron: true, colors: colors)
            modelButton.accessibilityValue = modelTitle
            thinkingButton.apply(
                title: live.thinkingLevel.compactTitle,
                icon: UIImage(systemName: "sparkle"),
                tint: live.thinkingTint,
                showsChevron: true,
                colors: colors
            )
            thinkingButton.accessibilityValue = live.thinkingLevel.displayTitle
        }
        controlRow.isHidden = !showsAttachments && !showsMic && !showsToolbar

        let text = live.text
        countersLabel.textColor = colors.comment
        countersLabel.isHidden = !configuration.showsCounters || text.isEmpty
        if !countersLabel.isHidden {
            let words = text.split(whereSeparator: \.isWhitespace).count
            let lines = max(1, text.components(separatedBy: "\n").count)
            countersLabel.text = "\(lines)L  \(words)W  \(text.count)C"
        }
        bottomBar.isHidden = controlRow.isHidden && attachmentStrip.isHidden && filePillStrip.isHidden
            && !configuration.showsCounters
    }

    // MARK: - Actions

    private func handleSend() {
        guard canSubmit else { return }
        isHandlingVoiceLifecycle = true
        applyChrome()
        Task { @MainActor [self] in
            await ComposerShared.finishOwnedVoiceInputBeforeSubmit(
                manager: voiceInputManager,
                owner: .expandedComposer,
                getText: { [weak self] in self?.live.text ?? "" },
                setText: { [weak self] value in self?.setComposerText(value) },
                getTextBeforeRecording: { [weak self] in self?.live.textBeforeRecording },
                setTextBeforeRecording: { [weak self] value in self?.setPrefix(value) },
                getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
                setSuppressKeyboard: { [weak self] value in self?.suppressKeyboard = value }
            )
            self.isHandlingVoiceLifecycle = false
            self.configuration.onSend()
            if self.configuration.dismissesOnSubmit {
                Router.finish(self)
            } else {
                self.applyChrome()
            }
        }
    }

    private func handleCancel() {
        guard !live.isSubmitInFlight, !isHandlingVoiceLifecycle else { return }
        isHandlingVoiceLifecycle = true
        applyChrome()
        Task { @MainActor [self] in
            if !self.configuration.preservesVoiceInputOnDismiss {
                await ComposerShared.cancelOwnedVoiceInput(
                    manager: self.voiceInputManager,
                    owner: .expandedComposer,
                    setTextBeforeRecording: { [weak self] value in self?.setPrefix(value) },
                    setSuppressKeyboard: { [weak self] value in self?.suppressKeyboard = value }
                )
            }
            self.isHandlingVoiceLifecycle = false
            self.configuration.onCancel?()
            if self.configuration.dismissesOnCancel {
                Router.finish(self)
            } else {
                self.applyChrome()
            }
        }
    }

    private func voiceEntryMenu() -> UIMenu? {
        guard configuration.onLiveVoiceSelected != nil else { return nil }
        return ComposerShared.voiceEntryMenu(
            identifierPrefix: "expanded",
            onLiveVoice: { [weak self] in self?.handleLiveVoiceChoice() },
            onDictation: { [weak self] in self?.handleMicTap() }
        )
    }

    /// Live Voice owns the microphone, so an in-progress dictation take ends first. The call
    /// lives in the chat below, so this editor closes.
    private func handleLiveVoiceChoice() {
        Task {
            await ComposerShared.stopDictationBeforeLiveVoice(manager: voiceInputManager)
            configuration.onLiveVoiceSelected?()
            Router.finish(self)
        }
    }

    private func handleMicTap() {
        guard let manager = voiceInputManager else { return }
        Task { [self] in
            guard ComposerShared.canControlVoiceInput(manager, owner: .expandedComposer) else { return }
            switch ComposerShared.micTapAction(for: manager.state) {
            case .stop:
                await ComposerShared.stopVoiceInput(
                    manager: manager,
                    getText: { [weak self] in self?.live.text ?? "" },
                    setText: { [weak self] value in self?.setComposerText(value) },
                    getTextBeforeRecording: { [weak self] in self?.live.textBeforeRecording },
                    setTextBeforeRecording: { [weak self] value in self?.setPrefix(value) }
                )
            case .cancelPreparing:
                await ComposerShared.cancelVoiceInput(
                    manager: manager,
                    getTextBeforeRecording: { [weak self] in self?.live.textBeforeRecording },
                    setTextBeforeRecording: { [weak self] value in self?.setPrefix(value) },
                    getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
                    setSuppressKeyboard: { [weak self] value in self?.suppressKeyboard = value }
                )
            case .start:
                try? await ComposerShared.startVoiceInput(
                    manager: manager,
                    keyboardLanguage: keyboardLanguage,
                    owner: .expandedComposer,
                    baseText: live.text,
                    getText: { [weak self] in self?.live.text ?? "" },
                    setText: { [weak self] value in self?.setComposerText(value) },
                    getTextBeforeRecording: { [weak self] in self?.live.textBeforeRecording },
                    setTextBeforeRecording: { [weak self] value in self?.setPrefix(value) },
                    getSuppressKeyboard: { [weak self] in self?.suppressKeyboard ?? false },
                    setSuppressKeyboard: { [weak self] value in self?.suppressKeyboard = value },
                    getFocusRequestID: { [weak self] in self?.focusRequestID ?? 0 },
                    setFocusRequestID: { [weak self] value in
                        self?.focusRequestID = value
                        self?.textView.becomeFirstResponder()
                    },
                    prepare: { [weak self] in
                        try await self?.configuration.onPrepareVoiceInput?(manager)
                    }
                )
            case .ignore:
                break
            }
            applyChrome()
        }
    }

    private func presentThinkingPicker() {
        ComposerThinkingPickerController.present(
            levels: live.supportedThinkingLevels,
            selected: live.thinkingLevel,
            colors: live.colors,
            onSelect: { [weak self] level in
                self?.live.thinkingLevel = level
                self?.configuration.onThinkingSelect(level)
            },
            onSaveDefault: configuration.onSaveThinkingAsDefault,
            from: self,
            sourceView: thinkingButton
        )
    }

    private func attachmentMenu() -> UIMenu {
        ComposerAttachmentPickers.menu(identifierPrefix: "expanded.attach") { [weak self] item in
            switch item {
            case .photoLibrary: self?.presentPhotoLibrary()
            case .camera: self?.presentCamera()
            case .chooseFile: self?.presentFileImporter()
            case .canvas: self?.presentCanvas()
            }
        }
    }

    private func presentPhotoLibrary() {
        present(ComposerAttachmentPickers.photoLibrary(delegate: self), animated: true)
    }

    private func presentCamera() {
        present(ComposerAttachmentPickers.camera(delegate: self), animated: true)
    }

    private func presentCanvas() {
        let background = canvasBackgroundImage.map { PaperMarkupCanvasSession.Background.image($0) } ?? .blank
        let replacing = canvasReplacingAttachmentID
        // The host puts Cancel and Add to Chat on its navigation item, so the
        // bar's controller has to come with it. `.overFullScreen` keeps this
        // composer rendering while the canvas writes its attachment back. The
        // canvas dismisses itself; these closures only reset state, because a
        // second `dismiss` here would close this composer once the canvas is gone.
        let controller = PaperMarkupCanvasHostController.makeNavigationController(
            background: background,
            onAddToChat: { [weak self] attachment, recognizedText in
                guard let self else { return false }
                let accepted = ComposerShared.applyCanvasToComposer(
                    attachment: attachment,
                    recognizedText: recognizedText,
                    getText: { self.live.text },
                    setText: { self.setComposerText($0) },
                    getAttachments: { self.live.pendingAttachments },
                    setAttachments: { self.setAttachments($0) },
                    replacingAttachmentID: replacing
                )
                if accepted {
                    self.canvasBackgroundImage = nil
                    self.canvasReplacingAttachmentID = nil
                }
                return accepted
            },
            onCancel: { [weak self] in
                self?.canvasBackgroundImage = nil
                self?.canvasReplacingAttachmentID = nil
            }
        )
        controller.modalPresentationStyle = .overFullScreen
        present(controller, animated: true)
    }

    private func presentFileImporter() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Draft writes

    /// Every edit goes to the presenter first, so the inline bar and this
    /// screen show one draft.
    private func setComposerText(_ value: String) {
        live.text = value
        configuration.onTextChange(value)
        ComposerShared.notifyFileSuggestionContext(
            for: value,
            isBusy: live.isBusy,
            onFileSuggestionQuery: configuration.onFileSuggestionQuery
        )
    }

    private func setPrefix(_ value: String?) {
        live.textBeforeRecording = value
        configuration.onTextBeforeRecordingChange(value)
    }

    private func setAttachments(_ value: [PendingAttachment]) {
        live.pendingAttachments = value
        configuration.onAttachmentsChange(value)
    }

    private func setPointers(_ value: [PendingFileReference]) {
        live.pendingRepoPointers = value
        configuration.onRepoPointersChange(value)
    }

    private func updateKeyboardLanguage() {
        guard !textView.isKeyboardSuppressed, textView.isFirstResponder else { return }
        let language = textView.textInputMode?.primaryLanguage
        keyboardLanguage = language
        AppPreferences.Keyboard.save(language)
        guard let manager = voiceInputManager,
              AppPreferences.Keyboard.normalize(language) != nil else { return }
        Task {
            await manager.prewarm(keyboardLanguage: language, source: "expanded_keyboard_change")
        }
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        let incoming = textView.text ?? ""
        if let pastable = textView as? PastableUITextView, !pastable.shouldCommitUserEdit(incoming) {
            return
        }
        var next = incoming
        if configuration.usesCommandPrefixMode, live.text.hasPrefix("$ ") {
            next = incoming.isEmpty ? "" : "$ " + incoming
        }
        setComposerText(next)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        updateKeyboardLanguage()
    }

    // MARK: - Pickers

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let capturedLocal = localMediaImportEpoch
        let gate = configuration.mediaImportGate?.epoch ?? 0
        ComposerShared.importPhotoLibraryProviders(
            results.map(\.itemProvider),
            getAttachments: { [weak self] in self?.live.pendingAttachments ?? [] },
            setAttachments: { [weak self] value in self?.setAttachments(value) },
            store: configuration.composerDraftStore,
            shouldAccept: { [weak self] in
                (self?.configuration.mediaImportGate?.isCurrent(gate) ?? true)
                    && capturedLocal == (self?.localMediaImportEpoch ?? 0)
            },
            onFailure: { [weak self] message in
                self?.presentAlert(title: "Couldn't Attach", message: message)
            }
        )
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else { return }
        ComposerShared.addCapturedImage(
            image,
            getAttachments: { [weak self] in self?.live.pendingAttachments ?? [] },
            setAttachments: { [weak self] value in self?.setAttachments(value) }
        )
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let capturedLocal = localMediaImportEpoch
        let gate = configuration.mediaImportGate?.epoch ?? 0
        ComposerShared.loadSelectedFiles(
            .success(urls),
            getAttachments: { [weak self] in self?.live.pendingAttachments ?? [] },
            setAttachments: { [weak self] value in self?.setAttachments(value) },
            store: configuration.composerDraftStore,
            shouldAccept: { [weak self] in
                (self?.configuration.mediaImportGate?.isCurrent(gate) ?? true)
                    && capturedLocal == (self?.localMediaImportEpoch ?? 0)
            },
            onFailure: { [weak self] message in
                self?.presentAlert(title: "Couldn't Attach", message: message)
            }
        )
    }
}
