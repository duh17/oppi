import UIKit
@testable import Oppi

extension ComposerBarContent {
    /// A plain idle bar: no Ask, no voice, the chat's identifiers.
    static func testDefault() -> ComposerBarContent {
        ComposerBarContent(
            text: "",
            textBeforeRecording: nil,
            pendingAttachments: [],
            pendingRepoPointers: [],
            isBusy: false,
            busyStreamingBehavior: .followUp,
            isSending: false,
            pendingReviewCommentCount: 0,
            placeholderOverride: nil,
            allowsEmptySubmit: false,
            sendProgressText: nil,
            isStopping: false,
            voiceInputManager: nil,
            showForceStop: false,
            isForceStopInFlight: false,
            askRequest: nil,
            slashCommands: [],
            fileSuggestions: [],
            appliesOuterPadding: false,
            alwaysShowActionRow: true,
            allowsExpansion: true,
            allowsAttachments: true,
            attachmentButtonPlacement: .leading,
            actionRowMinimumHeight: 0,
            showsAccessoryRow: true,
            autocorrectionEnabled: true,
            inputAccessibilityIdentifier: "chat.input",
            sendAccessibilityIdentifier: "chat.send",
            actionRow: .init(),
            colors: .placeholder,
            reduceMotion: true,
            suppressKeyboard: false,
            focusRequestID: 0,
            keyboardLanguage: nil,
            keyStripHeight: 0,
            mediaImportEpoch: 0
        )
    }
}

/// A screen that feeds the chat's composer owner from plain values, the way
/// the chat does, for tests of the owner path.
@MainActor
final class ComposerOwnerTestScreen: UIViewController, ChatComposerSource {
    var content: ComposerBarContent
    /// Runs after the composer edits the draft or its recording prefix.
    var onEdit: ((ComposerBarContent) -> Void)?
    let composer = ChatComposerOwner()

    init(content: ComposerBarContent) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        composer.source = self
        addChild(composer)
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer.view)
        composer.didMove(toParent: self)
        NSLayoutConstraint.activate([
            composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    var composerContent: ComposerBarContent { content }
    var composerDraftStore: ComposerDraftStore? { nil }
    var composerMediaImportGate: ComposerMediaImportGate? { nil }
    func composerSetText(_ text: String) {
        content.text = text
        onEdit?(content)
        composer.setNeedsUpdateProperties()
    }
    func composerSetTextBeforeRecording(_ value: String?) {
        content.textBeforeRecording = value
        onEdit?(content)
        composer.setNeedsUpdateProperties()
    }
    func composerSetPendingAttachments(_ value: [PendingAttachment]) {}
    func composerSetPendingRepoPointers(_ value: [PendingFileReference]) {}
    func composerSetBusyStreamingBehavior(_ value: StreamingBehavior) {}
    func composerSend() {}
    func composerStop() {}
    func composerForceStop() {}
    func composerExpand() {}
    func composerSubmitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) {}
    func composerIgnoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion) {}
    func composerFileSuggestionQuery(_ query: String?) {}
    func composerPrepareVoiceInput(_ manager: VoiceInputManager) async throws {}
    var isComposerExpanded: Bool { false }
    func composerExpandedDidClose() {}
    func makeExpandedComposer() -> ExpandedComposerViewController {
        preconditionFailure("The test never expands the composer")
    }
    var expandedComposerLiveState: ExpandedComposerLiveState {
        preconditionFailure("The test never expands the composer")
    }
}
