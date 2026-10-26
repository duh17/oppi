#if DEBUG
import SwiftUI
import UIKit

/// Parks the production Ask delay owner until the fixture releases it.
@MainActor
final class AskCardIntentRegressionSession {
    var pendingCount = 0 {
        didSet { onChange?() }
    }
    /// Runs after the delay registers or releases.
    var onChange: (() -> Void)?

    private var continuations: [CheckedContinuation<Void, Error>] = []

    private(set) lazy var autoAdvance: AskInlineAutoAdvanceController = {
        AskInlineAutoAdvanceController(wait: { [weak self] duration in
            guard let self else { return }
            try await self.hold(duration)
        })
    }()

    var delayState: String {
        pendingCount > 0 ? "Delay pending" : "Delay idle"
    }

    private func hold(_ duration: Duration) async throws {
        _ = duration
        pendingCount += 1
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.continuations.append(continuation)
                }
            } onCancel: {
                Task { @MainActor in
                    self.failOldest()
                }
            }
        } catch {
            pendingCount = continuations.count
            throw error
        }
        pendingCount = continuations.count
    }

    func releaseAll() {
        let items = continuations
        continuations.removeAll()
        pendingCount = 0
        items.forEach { $0.resume() }
    }

    private func failOldest() {
        guard !continuations.isEmpty else {
            pendingCount = 0
            return
        }
        continuations.removeFirst().resume(throwing: CancellationError())
        pendingCount = continuations.count
    }
}

/// Lane-local Ask delayed-advance fixture: a three-question single-select
/// Ask on the chat's composer (`ChatComposerOwner`), busy so the composer's
/// Ignore control shows, with a same-id replacement button.
struct AskCardIntentRegressionPreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AskCardIntentRegressionPreviewController {
        AskCardIntentRegressionPreviewController()
    }

    func updateUIViewController(_ controller: AskCardIntentRegressionPreviewController, context: Context) {}

    static let threeQuestionRequest = AskRequest(
        id: "ask-intent-regression",
        sessionId: "preview-session",
        questions: [
            AskQuestion(
                id: "q1",
                question: "Intent question one?",
                options: [
                    AskOption(value: "alpha", label: "Alpha"),
                    AskOption(value: "bravo", label: "Bravo"),
                ],
                multiSelect: false
            ),
            AskQuestion(
                id: "q2",
                question: "Intent question two?",
                options: [
                    AskOption(value: "charlie", label: "Charlie"),
                    AskOption(value: "delta", label: "Delta"),
                ],
                multiSelect: false
            ),
            AskQuestion(
                id: "q3",
                question: "Intent question three?",
                options: [
                    AskOption(value: "echo", label: "Echo"),
                    AskOption(value: "foxtrot", label: "Foxtrot"),
                ],
                multiSelect: false
            ),
        ],
        allowCustom: false,
        timeout: nil
    )

    static let replacementRequest = AskRequest(
        id: "ask-intent-regression",
        sessionId: "preview-session",
        questions: [
            AskQuestion(
                id: "only",
                question: "Intent replacement only?",
                options: [
                    AskOption(value: "zulu", label: "Zulu"),
                ],
                multiSelect: false
            ),
        ],
        allowCustom: false,
        timeout: nil
    )
}

final class AskCardIntentRegressionPreviewController: UIViewController {
    private let session = AskCardIntentRegressionSession()
    private let statusLabel = UILabel()
    private let delayLabel = UILabel()
    private let composer: PreviewComposerController

    init() {
        composer = PreviewComposerController(values: .init(
            isBusy: true,
            askRequest: AskCardIntentRegressionPreview.threeQuestionRequest,
            colors: ComposerThemeColors(palette: ThemeRuntimeState.currentPalette())
        ))
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .dark
        composer.autoAdvance = session.autoAdvance
        composer.onAskSubmit = { [weak self] _, _ in self?.setStatus("Submitted") }
        composer.onAskIgnore = { [weak self] _ in self?.setStatus("Ignored all") }
        session.onChange = { [weak self] in self?.showDelayState() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let colors = composer.values.colors
        view.backgroundColor = colors.bg
        view.accessibilityIdentifier = "screenshot.ready"
        FeatureEducationTips.markPromptAnswered()

        let title = UILabel()
        title.text = "Ask intent regression"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = colors.fg
        for label in [statusLabel, delayLabel] {
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = colors.comment
        }
        statusLabel.accessibilityIdentifier = "ask.intent.status"
        delayLabel.accessibilityIdentifier = "ask.intent.delayState"
        setStatus("Waiting")
        showDelayState()
        let release = UIButton(configuration: .plain(), primaryAction: UIAction(title: "Release delay") { [weak self] _ in
            self?.session.releaseAll()
        })
        release.accessibilityIdentifier = "ask.intent.releaseDelay"
        let replace = UIButton(configuration: .plain(), primaryAction: UIAction(title: "Replace same-id content") { [weak self] _ in
            self?.composer.values.askRequest = AskCardIntentRegressionPreview.replacementRequest
            self?.setStatus("Replaced same id")
        })
        replace.accessibilityIdentifier = "ask.intent.replaceSameId"
        let header = UIStackView(arrangedSubviews: [title, statusLabel, delayLabel, release, replace])
        header.axis = .vertical
        header.alignment = .leading
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        addChild(composer)
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer.view)
        composer.didMove(toParent: self)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safe.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),
            composer.view.topAnchor.constraint(greaterThanOrEqualTo: header.bottomAnchor, constant: 12),
            composer.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func setStatus(_ status: String) {
        statusLabel.text = status
    }

    private func showDelayState() {
        delayLabel.text = session.delayState
    }
}

/// One question with enough options to exceed the inline Ask cap so the
/// card must scroll instead of stretching the composer.
struct AskCardTallScrollPreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AskCardTallScrollPreviewController {
        AskCardTallScrollPreviewController()
    }

    func updateUIViewController(_ controller: AskCardTallScrollPreviewController, context: Context) {}

    static let tallRequest = AskRequest(
        id: "ask-tall-scroll",
        sessionId: "preview-session",
        questions: [
            AskQuestion(
                id: "tall",
                question: "Pick a path for this long inline Ask.",
                options: [
                    AskOption(value: "alpha", label: "Alpha", description: "First choice in a list tall enough to scroll."),
                    AskOption(value: "bravo", label: "Bravo", description: "Second choice, still above the fold on a phone."),
                    AskOption(value: "charlie", label: "Charlie", description: "Third choice pushes past the keyboard cap."),
                    AskOption(value: "delta", label: "Delta", description: "Fourth choice keeps the card growing."),
                    AskOption(value: "echo", label: "Echo", description: "Fifth choice is below the unfocused cap."),
                    AskOption(value: "foxtrot", label: "Foxtrot", description: "Sixth choice stays reachable by scrolling."),
                    AskOption(value: "golf", label: "Golf", description: "Seventh choice near the bottom of the list."),
                    AskOption(value: "omega", label: "Omega last option", description: "Last option the slot must scroll to."),
                ],
                multiSelect: false
            ),
        ],
        allowCustom: true,
        timeout: nil
    )
}

final class AskCardTallScrollPreviewController: UIViewController {
    private let composer = PreviewComposerController(values: .init(
        askRequest: AskCardTallScrollPreview.tallRequest,
        colors: ComposerThemeColors(palette: ThemeRuntimeState.currentPalette())
    ))

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .light
        view.backgroundColor = composer.values.colors.bg
        view.accessibilityIdentifier = "screenshot.ready"
        FeatureEducationTips.markPromptAnswered()
        addChild(composer)
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer.view)
        composer.didMove(toParent: self)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            composer.view.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor),
            composer.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            composer.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            composer.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
    }
}
#endif
