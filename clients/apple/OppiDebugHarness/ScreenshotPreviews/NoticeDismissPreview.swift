#if DEBUG
import UIKit

/// The two transient notices that share `NoticeDismissTimer`, each over its
/// real view: the composer's "Dictation stopped" notice (a real
/// `VoiceInputManager` publishing a failed take) and the message queue error.
/// The auto-dismiss timer never fires here, so a capture or a UI test holds the
/// notice until it taps the real Dismiss button.
extension NoticeTimerEnvironment {
    static var neverExpiring: NoticeTimerEnvironment {
        NoticeTimerEnvironment(sleep: { _ in try await Task.sleep(for: .seconds(86_400)) })
    }
}

@MainActor
final class NoticeDismissDictationPreviewController: UIViewController {
    private let manager = VoiceInputManager(noticeEnvironment: .neverExpiring)
    private let composer: PreviewComposerController

    init() {
        composer = PreviewComposerController(values: .init(
            text: "Earlier draft that was kept",
            voiceInputManager: manager,
            colors: ComposerThemeColors(palette: ThemeRuntimeState.currentPalette())
        ))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = composer.values.colors.bg
        view.accessibilityIdentifier = "screenshot.ready"
        FeatureEducationTips.markPromptAnswered()
        addChild(composer)
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer.view)
        NSLayoutConstraint.activate([
            composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composer.view.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor),
        ])
        composer.didMove(toParent: self)
        manager.debugPublishCaptureFailure(
            owner: ComposerShared.VoiceInputOwner.inlineComposer.rawValue,
            message: "The microphone route changed and dictation could not keep recording. This take was discarded. Your earlier draft was kept. Retry dictation."
        )
    }
}

@MainActor
final class NoticeDismissQueuePreviewController: UIViewController {
    private let queueView = MessageQueueView(presentation: .drawer, noticeEnvironment: .neverExpiring)

    override func viewDidLoad() {
        super.viewDidLoad()
        let colors = ComposerThemeColors(palette: ThemeRuntimeState.currentPalette())
        view.backgroundColor = colors.bg
        view.accessibilityIdentifier = "screenshot.ready"
        queueView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(queueView)
        NSLayoutConstraint.activate([
            queueView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            queueView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            queueView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        queueView.apply(
            MessageQueueSurfaceConfiguration(
                queue: .empty,
                onRemove: { _ in },
                onEditInComposer: {},
                error: "Couldn't take the queued messages back from the server. Nothing was changed; your queue is still waiting. Check the connection and try Stop again."
            ),
            themeID: ThemeRuntimeState.currentThemeID()
        )
    }
}
#endif
