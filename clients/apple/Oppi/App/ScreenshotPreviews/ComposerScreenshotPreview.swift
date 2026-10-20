#if DEBUG
import SwiftUI
import UIKit

// MARK: - Live Voice Composer Preview

/// A Live Voice call in the chat input bar, with a synthetic meter standing in for the
/// call's audio taps. `live-voice-composer` walks a whole call (draft set aside, connect,
/// listen, talk, reply, mute, end with the draft back); the suffixed screens hold one step.
/// `SCREENSHOT_DICTATION_STYLE` (`ring`, `breathing`, `composing`) picks the indicator.
struct LiveVoiceComposerPreview: UIViewControllerRepresentable {
    enum Step: String, CaseIterable {
        case draft, connecting, listening, talking, speaking, muted, restored
    }

    let pinned: Step?

    func makeUIViewController(context: Context) -> LiveVoiceComposerPreviewController {
        LiveVoiceComposerPreviewController(pinned: pinned)
    }

    func updateUIViewController(_ controller: LiveVoiceComposerPreviewController, context: Context) {}
}

/// The chat's composer (`ChatComposerOwner`), fed by this preview the way the chat feeds it.
final class LiveVoiceComposerPreviewController: UIViewController, ChatComposerSource {
    typealias Step = LiveVoiceComposerPreview.Step

    private let pinned: Step?
    private let composer = ChatComposerOwner()
    private let stepLabel = UILabel()
    private let draft = ChatComposerDraftController(initialText: "Draft from before the call")
    private let meter = LiveVoiceAudioMeter()
    private var step: Step = .draft {
        didSet { showStep() }
    }
    private var transcript = "" {
        didSet { composer.setNeedsUpdateProperties() }
    }
    private var textBeforeRecording: String?
    private var attachments: [PendingAttachment] = []
    private var repoPointers: [PendingFileReference] = []
    private var busyBehavior: StreamingBehavior = .steer
    private var script: Task<Void, Never>?

    private static let spoken = "check whether the server tests pass on main"

    init(pinned: Step?) {
        self.pinned = pinned
        super.init(nibName: nil, bundle: nil)
        if let style = ProcessInfo.processInfo.environment["SCREENSHOT_DICTATION_STYLE"] {
            ScreenshotVolatileDefaults.apply([AppPreferenceStore.Appearance.dictationIndicatorStyleKey: style])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var colors: ComposerThemeColors {
        ComposerThemeColors(palette: ThemeRuntimeState.currentPalette())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let colors = colors
        view.backgroundColor = colors.bg
        view.accessibilityIdentifier = "screenshot.ready"

        let title = UILabel()
        title.text = "Live Voice in the composer"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = colors.fg
        stepLabel.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        stepLabel.textColor = colors.comment
        stepLabel.accessibilityIdentifier = "liveVoice.preview.step"
        let header = UIStackView(arrangedSubviews: [title, stepLabel])
        header.axis = .vertical
        header.alignment = .leading
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        composer.source = self
        addChild(composer)
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer.view)
        composer.didMove(toParent: self)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safe.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),
            composer.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            composer.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            composer.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -24),
        ])
        showStep()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard script == nil else { return }
        script = Task { [weak self] in await self?.run() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        script?.cancel()
        script = nil
    }

    private func showStep() {
        stepLabel.text = "Step: \(step.rawValue)"
        composer.setNeedsUpdateProperties()
    }

    // MARK: ChatComposerSource

    var composerContent: ComposerBarContent {
        ComposerBarContent(
            text: draft.text,
            textBeforeRecording: textBeforeRecording,
            pendingAttachments: attachments,
            pendingRepoPointers: repoPointers,
            isBusy: false,
            busyStreamingBehavior: busyBehavior,
            isSending: false,
            pendingReviewCommentCount: 0,
            placeholderOverride: nil,
            allowsEmptySubmit: false,
            sendProgressText: nil,
            isStopping: false,
            voiceInputManager: nil,
            liveVoiceCall: call,
            showForceStop: false,
            isForceStopInFlight: false,
            askRequest: nil,
            slashCommands: [],
            fileSuggestions: [],
            appliesOuterPadding: false,
            alwaysShowActionRow: false,
            allowsExpansion: true,
            allowsAttachments: true,
            attachmentButtonPlacement: .leading,
            actionRowMinimumHeight: 0,
            showsAccessoryRow: true,
            autocorrectionEnabled: true,
            inputAccessibilityIdentifier: "chat.input",
            sendAccessibilityIdentifier: "chat.send",
            actionRow: .previewModelThinking,
            colors: colors,
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

    func composerSetText(_ text: String) { draft.updateVisibleText(text, for: .message) }
    func composerSetTextBeforeRecording(_ value: String?) { textBeforeRecording = value }
    func composerSetPendingAttachments(_ value: [PendingAttachment]) { attachments = value }
    func composerSetPendingRepoPointers(_ value: [PendingFileReference]) { repoPointers = value }
    func composerSetBusyStreamingBehavior(_ value: StreamingBehavior) { busyBehavior = value }

    // The preview sends nothing.
    func composerSend() {}
    func composerStop() {}
    func composerForceStop() {}
    func composerExpand() {}
    func composerSubmitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) {
        completion(.completed)
    }
    func composerIgnoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion) {
        completion(.completed)
    }
    func composerFileSuggestionQuery(_ query: String?) {}
    func composerPrepareVoiceInput(_ manager: VoiceInputManager) async throws {}

    var isComposerExpanded: Bool { false }
    func composerExpandedDidClose() {}
    func makeExpandedComposer() -> ExpandedComposerViewController {
        preconditionFailure("The Live Voice preview never expands its composer")
    }
    var expandedComposerLiveState: ExpandedComposerLiveState {
        preconditionFailure("The Live Voice preview never expands its composer")
    }

    private var call: ComposerLiveVoiceCall? {
        switch step {
        case .draft, .restored:
            return nil
        case .connecting, .listening, .talking, .speaking, .muted:
            return ComposerLiveVoiceCall(
                isLive: true,
                isConnecting: step == .connecting,
                isMuted: step == .muted,
                isSpeaking: step == .speaking,
                status: status,
                transcript: step == .talking ? transcript : "",
                meter: meter,
                onToggleMute: {},
                onEnd: {}
            )
        }
    }

    private var status: String {
        switch step {
        case .connecting: "Connecting"
        case .speaking: "Speaking"
        case .muted: "Muted"
        default: "Listening"
        }
    }

    private func enter(_ next: Step) {
        let wasInCall = call != nil
        step = next
        let inCall = call != nil
        if inCall, !wasInCall { draft.setAsideMessage() }
        if !inCall, wasInCall { draft.restoreSetAsideMessage() }
    }

    private func run() async {
        let feed = Task { await feedMeter() }
        defer { feed.cancel() }
        if let pinned {
            if pinned == .restored { enter(.listening) }
            if pinned == .talking { transcript = Self.spoken }
            enter(pinned)
            try? await Task.sleep(for: .seconds(3_600))
            return
        }
        let script: [(Step, Duration)] = [
            (.draft, .seconds(2)), (.connecting, .seconds(1.5)), (.listening, .seconds(2)),
            (.talking, .zero), (.speaking, .seconds(4)), (.muted, .seconds(2.5)), (.restored, .seconds(3)),
        ]
        for (next, hold) in script {
            enter(next)
            if next == .talking {
                let words = Self.spoken.split(separator: " ")
                for count in 1...words.count {
                    transcript = words.prefix(count).joined(separator: " ")
                    try? await Task.sleep(for: .milliseconds(350))
                }
                try? await Task.sleep(for: .seconds(1))
                transcript = ""
            }
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
        }
    }

    /// Speech-like levels at the tap's cadence: the mic while the user talks, the reply's
    /// voice while the agent speaks, room quiet otherwise.
    private func feedMeter() async {
        let start = Date()
        while !Task.isCancelled {
            let t = Date().timeIntervalSince(start)
            let syllable = Float(abs(sin(t * 7.3)) * (0.55 + 0.45 * abs(sin(t * 1.7))))
            var voice = VoiceSpectrumFrame(level: 0.15 + 0.7 * syllable, flux: 6 * syllable)
            for band in 0..<5 {
                voice.bands[band] = Float(0.2 + 0.8 * abs(sin(t * (3.1 + Double(band) * 1.9) + Double(band))))
                    * syllable
            }
            meter.publishMic(step == .talking ? voice : .zero)
            meter.publishPlayback(step == .speaking ? voice : .zero)
            try? await Task.sleep(for: .milliseconds(21))
        }
    }
}
#endif
