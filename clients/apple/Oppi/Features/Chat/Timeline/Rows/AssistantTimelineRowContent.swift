import UIKit

/// Native UIKit assistant row — unified renderer for all assistant content.
///
/// Uses `AssistantMarkdownContentView` for both streaming and done states.
/// During streaming, the incremental markdown pipeline (tail-only CommonMark
/// parse + structural segment diffing) renders formatted content on coalescer ticks.
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
    /// Immutable saved-Agent presentation snapshot for this session.
    let agentId: String?
    let agentIcon: String?
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
        agentId: String? = nil,
        agentIcon: String? = nil,
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
        self.agentId = agentId
        self.agentIcon = agentIcon
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

    override func layoutSubviews() {
        super.layoutSubviews()

        #if DEBUG
            if let itemID = currentConfiguration.itemID {
                AssistantMarkdownDebugRegistry.update(
                    itemID: itemID,
                    frameHeight: bounds.height,
                    overlapPoints: markdownView.debugMaxRenderedSegmentOverlapPoints,
                    overflowPoints: markdownView.debugRenderedContentOverflowPoints
                )
            }
        #endif
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

        let size = CGSize(width: width, height: min(rawHeight, Self.maxValidHeight))

        #if DEBUG
            if let itemID = currentConfiguration.itemID {
                AssistantMarkdownDebugRegistry.update(
                    itemID: itemID,
                    frameHeight: size.height,
                    overlapPoints: markdownView.debugMaxRenderedSegmentOverlapPoints,
                    overflowPoints: markdownView.debugRenderedContentOverflowPoints
                )
            }
        #endif

        return size
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
        accessibilityIdentifier = configuration.itemID.map { "chat.timeline.assistant.\($0)" }

        let palette = ThemeRuntimeState.currentPalette()
        iconBadge.sessionId = configuration.sessionId
        iconBadge.agentId = configuration.agentId
        iconBadge.agentIcon = configuration.agentIcon
        bubbleContainer.backgroundColor = UIColor(palette.purple).withAlphaComponent(TimelineBubbleStyle.subtleBgAlpha)

        let trimmedText = configuration.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Unified markdown path for both streaming and done states.
        // During streaming, the incremental parser (tail-only CommonMark parse
        // with FNV-1a prefix caching) keeps main-thread cost low. The segment
        // applier does structural diffing and only updates the growing tail.
        // Text appears immediately on each coalescer flush (no reveal animation).
        markdownView.fetchWorkspaceFile = configuration.fetchWorkspaceFile
        markdownView.fetchSessionFile = configuration.fetchSessionFile
        let reviewCommentSourceContext = configuration.interactionContext?.sourceContext(
            surface: .assistantProse,
            timelineItemId: configuration.itemID
        )
        markdownView.apply(configuration: .make(
            content: trimmedText,
            isStreaming: configuration.isStreaming,
            themeID: ThemeRuntimeState.currentThemeID(),
            reviewCommentSelectionRouter: configuration.interactionContext?.reviewCommentSelectionContext?.dispatcher,
            reviewCommentSourceContext: reviewCommentSourceContext,
            workspaceID: configuration.workspaceID,
            sessionID: configuration.sessionId,
            serverBaseURL: configuration.serverBaseURL,
            perfSurface: .inlineAssistant
        ))
    }
}

#if DEBUG
@MainActor
struct AssistantMarkdownDebugSnapshot {
    let frameHeight: CGFloat
    let overlapPoints: CGFloat
    let overflowPoints: CGFloat
}

@MainActor
private enum AssistantMarkdownDebugRegistry {
    private static var snapshots: [String: AssistantMarkdownDebugSnapshot] = [:]

    static func update(itemID: String, frameHeight: CGFloat, overlapPoints: CGFloat, overflowPoints: CGFloat) {
        snapshots[itemID] = AssistantMarkdownDebugSnapshot(
            frameHeight: frameHeight,
            overlapPoints: overlapPoints,
            overflowPoints: overflowPoints
        )
    }

    static func snapshot(for itemID: String) -> AssistantMarkdownDebugSnapshot? {
        snapshots[itemID]
    }
}

extension AssistantTimelineRowContentView {
    var debugMarkdownRenderedOverlapPoints: CGFloat {
        markdownView.debugMaxRenderedSegmentOverlapPoints
    }

    var debugMarkdownOverflowPoints: CGFloat {
        markdownView.debugRenderedContentOverflowPoints
    }

    static func debugSnapshot(for itemID: String) -> AssistantMarkdownDebugSnapshot? {
        AssistantMarkdownDebugRegistry.snapshot(for: itemID)
    }
}
#endif
