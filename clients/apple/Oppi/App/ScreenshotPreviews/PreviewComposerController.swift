#if DEBUG
import UIKit

/// The chat's composer (`ChatComposerOwner`) over a preview's own values, fed
/// the way the chat feeds it, for harnesses that show one composer state (an
/// inline Ask, the busy-mode tip). The composer sits at the bottom of its view.
@MainActor
final class PreviewComposerController: UIViewController, ChatComposerSource {
    struct Values {
        var text = ""
        var isBusy = false
        var askRequest: AskRequest?
        var appliesOuterPadding = true
        var colors: ComposerThemeColors
    }

    var values: Values {
        didSet { composer.setNeedsUpdateProperties() }
    }
    /// Paces the Ask card's auto-advance (a fixture that parks it).
    var autoAdvance: AskInlineAutoAdvanceController?
    var onAskSubmit: ((AskRequest, [String: AskAnswer]) -> Void)?
    var onAskIgnore: ((AskRequest) -> Void)?

    let composer = ChatComposerOwner()
    private var textBeforeRecording: String?
    private var attachments: [PendingAttachment] = []
    private var repoPointers: [PendingFileReference] = []
    private var busyBehavior: StreamingBehavior = .steer

    init(values: Values) {
        self.values = values
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        composer.source = self
        addChild(composer)
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer.view)
        NSLayoutConstraint.activate([
            composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composer.view.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor),
        ])
        composer.didMove(toParent: self)
    }

    // MARK: ChatComposerSource

    var composerContent: ComposerBarContent {
        ComposerBarContent(
            text: values.text,
            textBeforeRecording: textBeforeRecording,
            pendingAttachments: attachments,
            pendingRepoPointers: repoPointers,
            isBusy: values.isBusy,
            busyStreamingBehavior: busyBehavior,
            isSending: false,
            pendingReviewCommentCount: 0,
            placeholderOverride: nil,
            allowsEmptySubmit: false,
            sendProgressText: nil,
            isStopping: false,
            voiceInputManager: nil,
            liveVoiceCall: nil,
            showForceStop: false,
            isForceStopInFlight: false,
            askRequest: values.askRequest,
            slashCommands: [],
            fileSuggestions: [],
            appliesOuterPadding: values.appliesOuterPadding,
            alwaysShowActionRow: true,
            allowsExpansion: false,
            allowsAttachments: true,
            attachmentButtonPlacement: .leading,
            actionRowMinimumHeight: 0,
            showsAccessoryRow: true,
            autocorrectionEnabled: true,
            inputAccessibilityIdentifier: "chat.input",
            sendAccessibilityIdentifier: "chat.send",
            actionRow: ComposerActionRow(),
            colors: values.colors,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            // The owner replaces these with its own.
            suppressKeyboard: false,
            focusRequestID: 0,
            keyboardLanguage: nil,
            keyStripHeight: 0,
            mediaImportEpoch: 0
        )
    }

    var composerDraftStore: ComposerDraftStore? { nil }
    var composerMediaImportGate: ComposerMediaImportGate? { nil }
    var composerAskAutoAdvanceController: AskInlineAutoAdvanceController? { autoAdvance }

    func composerSetText(_ text: String) { values.text = text }
    func composerSetTextBeforeRecording(_ value: String?) { textBeforeRecording = value }
    func composerSetPendingAttachments(_ value: [PendingAttachment]) { attachments = value }
    func composerSetPendingRepoPointers(_ value: [PendingFileReference]) { repoPointers = value }
    func composerSetBusyStreamingBehavior(_ value: StreamingBehavior) { busyBehavior = value }

    func composerSend() {}
    func composerStop() {}
    func composerForceStop() {}
    func composerExpand() {}
    func composerSubmitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) {
        onAskSubmit?(request, answers)
        completion(.completed)
    }
    func composerIgnoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion) {
        onAskIgnore?(request)
        completion(.completed)
    }
    func composerFileSuggestionQuery(_ query: String?) {}
    func composerPrepareVoiceInput(_ manager: VoiceInputManager) async throws {}

    // Expansion is off (`allowsExpansion: false`).
    var isComposerExpanded: Bool { false }
    func composerExpandedDidClose() {}
    func makeExpandedComposer() -> ExpandedComposerViewController {
        preconditionFailure("The preview composer does not expand")
    }
    var expandedComposerLiveState: ExpandedComposerLiveState {
        preconditionFailure("The preview composer does not expand")
    }
}
#endif
