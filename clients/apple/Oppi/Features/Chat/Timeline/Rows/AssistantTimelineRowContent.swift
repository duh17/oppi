import UIKit

/// Native UIKit assistant row — unified renderer for all assistant content.
///
/// Uses `AssistantMarkdownContentView` for both streaming and done states.
/// During streaming, the incremental markdown pipeline (tail-only CommonMark
/// parse + structural segment diffing) renders formatted content at 30fps.
/// The `StreamingTextRevealer` inside the segment applier handles smooth
/// character reveal for the growing tail segment.
struct AssistantTimelineRowConfiguration: UIContentConfiguration {
    let text: String
    let isStreaming: Bool
    let canFork: Bool
    let onFork: (() -> Void)?
    /// Shared interaction context for π text-selection actions.
    let interactionContext: TimelineInteractionContext?
    /// Workspace context for resolving markdown image paths.
    let workspaceID: String?
    let serverBaseURL: URL?
    /// Closure for fetching a workspace file by path. Wraps `APIClient.fetchWorkspaceFile`
    /// at the caller site so view-layer files stay decoupled from `APIClient` directly.
    let fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?

    init(
        text: String,
        isStreaming: Bool,
        canFork: Bool,
        onFork: (() -> Void)?,
        interactionContext: TimelineInteractionContext? = nil,
        workspaceID: String? = nil,
        serverBaseURL: URL? = nil,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.canFork = canFork
        self.onFork = onFork
        self.interactionContext = interactionContext
        self.workspaceID = workspaceID
        self.serverBaseURL = serverBaseURL
        self.fetchWorkspaceFile = fetchWorkspaceFile
    }

    func makeContentView() -> any UIView & UIContentView {
        AssistantTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class AssistantTimelineRowContentView: UIView, UIContentView, TimelineRowInteractionProvider {
    private static let maxValidHeight: CGFloat = 10_000

    private let bubbleContainer = UIView()
    private let iconLabel = UILabel()
    private let markdownView = AssistantMarkdownContentView()

    private var currentConfiguration: AssistantTimelineRowConfiguration
    private var interactionHandlers: TimelineRowInteractionHandlers?

    // MARK: - TimelineRowInteractionProvider

    var copyableText: String? {
        let text = currentConfiguration.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    var interactionFeedbackView: UIView { bubbleContainer }

    var supportsFork: Bool {
        currentConfiguration.canFork && currentConfiguration.onFork != nil
    }

    var forkAction: (() -> Void)? { currentConfiguration.onFork }

    var additionalMenuActions: [UIAction] {
        guard let text = copyableText else { return [] }
        return [
            UIAction(
                title: String(localized: "Copy as Markdown"),
                image: UIImage(systemName: "text.document")
            ) { [weak self] _ in
                TimelineCopyFeedback.copy(
                    text,
                    feedbackView: self?.bubbleContainer,
                    trimWhitespaceAndNewlines: true
                )
            },
        ]
    }

    init(configuration: AssistantTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? AssistantTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let fitted = super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )

        let fallbackWidth = targetSize.width.isFinite ? targetSize.width : bounds.width
        let width = fitted.width.isFinite && fitted.width > 0 ? fitted.width : max(1, fallbackWidth)

        let rawHeight: CGFloat
        if fitted.height.isFinite && fitted.height > 0 {
            rawHeight = fitted.height
        } else {
            rawHeight = 44
        }

        return CGSize(width: width, height: min(rawHeight, Self.maxValidHeight))
    }

    private func setupViews() {
        backgroundColor = .clear

        // Same bubble shape as user messages — just different tint color.
        bubbleContainer.translatesAutoresizingMaskIntoConstraints = false
        bubbleContainer.layer.cornerRadius = TimelineBubbleStyle.bubbleCornerRadius
        bubbleContainer.clipsToBounds = true

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.font = AppFont.monoXL
        iconLabel.textColor = UIColor(ThemeRuntimeState.currentPalette().purple)
        iconLabel.text = "π"
        iconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)
        iconLabel.isUserInteractionEnabled = true

        markdownView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(bubbleContainer)
        bubbleContainer.addSubview(iconLabel)
        bubbleContainer.addSubview(markdownView)
        interactionHandlers = TimelineRowInteractionInstaller.install(
            on: bubbleContainer,
            provider: self
        )

        NSLayoutConstraint.activate([
            bubbleContainer.topAnchor.constraint(equalTo: topAnchor),
            bubbleContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubbleContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubbleContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Match user bubble insets: 10pt horizontal, 8pt vertical.
            iconLabel.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 10),
            iconLabel.topAnchor.constraint(equalTo: bubbleContainer.topAnchor, constant: 9),
            iconLabel.bottomAnchor.constraint(lessThanOrEqualTo: bubbleContainer.bottomAnchor, constant: -8),

            markdownView.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 6),
            markdownView.topAnchor.constraint(equalTo: bubbleContainer.topAnchor, constant: 8),
            markdownView.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -10),
            markdownView.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -8),
        ])
    }

    private func apply(configuration: AssistantTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = ThemeRuntimeState.currentPalette()
        iconLabel.textColor = UIColor(palette.purple)
        bubbleContainer.backgroundColor = UIColor(palette.purple).withAlphaComponent(TimelineBubbleStyle.subtleBgAlpha)

        let trimmedText = configuration.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Unified markdown path for both streaming and done states.
        // During streaming, the incremental parser (tail-only CommonMark parse
        // with FNV-1a prefix caching) keeps main-thread cost low. The segment
        // applier does structural diffing and only updates the growing tail.
        // StreamingTextRevealer inside the applier handles smooth character fade.
        markdownView.fetchWorkspaceFile = configuration.fetchWorkspaceFile
        markdownView.apply(configuration: .init(
            content: trimmedText,
            isStreaming: configuration.isStreaming,
            themeID: ThemeRuntimeState.currentThemeID(),
            selectedTextPiRouter: configuration.interactionContext?.selectedTextPiRouter,
            selectedTextSourceContext: configuration.interactionContext?.sourceContext(
                surface: .assistantProse
            ),
            workspaceID: configuration.workspaceID,
            serverBaseURL: configuration.serverBaseURL,
            perfSurface: .inlineAssistant
        ))
    }
}
