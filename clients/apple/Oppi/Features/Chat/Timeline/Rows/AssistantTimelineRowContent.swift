import UIKit

/// Native UIKit assistant row — unified renderer for all assistant content.
///
/// Uses `AssistantMarkdownContentView` for both streaming and done states.
/// During streaming, the incremental markdown pipeline (tail-only CommonMark
/// parse + structural segment diffing) renders formatted content at 30fps.
/// Text appears immediately on each coalescer flush — no per-character
/// animation — keeping CPU cost minimal.
struct AssistantTimelineRowConfiguration: UIContentConfiguration {
    let text: String
    let isStreaming: Bool
    let canFork: Bool
    let onFork: (() -> Void)?
    let itemID: String?
    /// Session ID for the grid badge icon.
    let sessionId: String
    /// Shared interaction context for π text-selection actions.
    let interactionContext: TimelineInteractionContext?
    /// Workspace context for resolving markdown image paths.
    let workspaceID: String?
    let serverBaseURL: URL?
    /// Closure for fetching a workspace file by path. Wraps `APIClient.fetchWorkspaceFile`
    /// at the caller site so view-layer files stay decoupled from `APIClient` directly.
    let fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?
    /// Closure for fetching a file from the active session working directory.
    let fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?

    init(
        text: String,
        isStreaming: Bool,
        canFork: Bool,
        onFork: (() -> Void)?,
        itemID: String? = nil,
        sessionId: String = "",
        interactionContext: TimelineInteractionContext? = nil,
        workspaceID: String? = nil,
        serverBaseURL: URL? = nil,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? = nil,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.canFork = canFork
        self.onFork = onFork
        self.itemID = itemID
        self.sessionId = sessionId
        self.interactionContext = interactionContext
        self.workspaceID = workspaceID
        self.serverBaseURL = serverBaseURL
        self.fetchWorkspaceFile = fetchWorkspaceFile
        self.fetchSessionFile = fetchSessionFile
    }

    func makeContentView() -> any UIView & UIContentView {
        AssistantTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class AssistantTimelineRowContentView: UIView, UIContentView, TimelineRowInteractionProvider {
    /// Guard against non-finite/absurd Auto Layout results without truncating
    /// legitimately huge assistant messages. Very long review/write-up turns can
    /// exceed 10k points on phone-width layouts.
    private static let maxValidHeight: CGFloat = 1_000_000

    private let bubbleContainer = UIView()
    private let iconBadge = SessionGridBadgeView()
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

        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconBadge.setContentHuggingPriority(.required, for: .horizontal)

        markdownView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(bubbleContainer)
        bubbleContainer.addSubview(iconBadge)
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
            iconBadge.widthAnchor.constraint(equalToConstant: 18),
            iconBadge.heightAnchor.constraint(equalToConstant: 18),
            iconBadge.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 10),
            iconBadge.topAnchor.constraint(equalTo: bubbleContainer.topAnchor, constant: 10),

            markdownView.leadingAnchor.constraint(equalTo: iconBadge.trailingAnchor, constant: 8),
            markdownView.topAnchor.constraint(equalTo: bubbleContainer.topAnchor, constant: 8),
            markdownView.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -10),
            markdownView.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -8),
        ])
    }

    private func apply(configuration: AssistantTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = ThemeRuntimeState.currentPalette()
        iconBadge.sessionId = configuration.sessionId
        bubbleContainer.backgroundColor = UIColor(palette.purple).withAlphaComponent(TimelineBubbleStyle.subtleBgAlpha)

        let trimmedText = configuration.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Unified markdown path for both streaming and done states.
        // During streaming, the incremental parser (tail-only CommonMark parse
        // with FNV-1a prefix caching) keeps main-thread cost low. The segment
        // applier does structural diffing and only updates the growing tail.
        // Text appears immediately on each coalescer flush (no reveal animation).
        markdownView.fetchWorkspaceFile = configuration.fetchWorkspaceFile
        markdownView.fetchSessionFile = configuration.fetchSessionFile
        let selectedTextSourceContext = configuration.interactionContext?.sourceContext(
            surface: .assistantProse,
            timelineItemId: configuration.itemID
        )
        markdownView.apply(configuration: .make(
            content: trimmedText,
            isStreaming: configuration.isStreaming,
            themeID: ThemeRuntimeState.currentThemeID(),
            selectedTextPiRouter: configuration.interactionContext?.selectedTextActionContext?.dispatcher,
            selectedTextSourceContext: selectedTextSourceContext,
            reviewCommentAnnotations: configuration.interactionContext?.inlineReviewAnnotations(for: selectedTextSourceContext) ?? [],
            workspaceID: configuration.workspaceID,
            sessionID: configuration.sessionId,
            serverBaseURL: configuration.serverBaseURL,
            perfSurface: .inlineAssistant
        ))
    }
}
