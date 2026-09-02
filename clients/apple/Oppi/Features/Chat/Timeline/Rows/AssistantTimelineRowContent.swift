import UIKit

/// Native UIKit assistant row — unified renderer for all assistant content.
///
/// Uses `AssistantMarkdownContentView` for both streaming and done states.
/// During streaming, the incremental markdown pipeline (tail-only CommonMark
/// parse + structural segment diffing) renders formatted content on coalescer ticks.
/// Each coalesced text tail lands immediately, then settles with one short
/// range-only fade; there is no per-character typewriter.
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
    let agentIcon: IconChoice?
    let iconAssetCache: IconAssetCache?
    /// Shared interaction context for π text-selection actions.
    let interactionContext: TimelineInteractionContext?
    /// Stable server scope for resource references.
    let serverID: String?
    /// Workspace context for resolving markdown image paths.
    let workspaceID: String?
    /// Source-session firstCheckout worktree for workspace image URL identity.
    let worktreeId: String?
    let serverBaseURL: URL?
    /// Closure for fetching a workspace file by path. Wraps `APIClient.fetchWorkspaceFile`
    /// at the caller site so view-layer files stay decoupled from `APIClient` directly.
    let fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?
    /// Closure for fetching a file from the active session working directory.
    let fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?
    /// Owner-host image fetcher. Sandbox callers remap guest POSIX paths.
    let fetchHostFile: ((_ path: String) async throws -> Data)?
    /// Existing authenticated/range-capable source path for inline wiki videos.
    let makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider?
    /// Existing authenticated/range-capable source path for inline wiki audio.
    let makeMarkdownAudioSource: MarkdownAudioMediaSourceProvider?
    let makeTimedTextSidecar: TimedTextSidecarProvider?
    let audioPlayer: AudioPlayerService?

    init(
        text: String,
        isStreaming: Bool,
        canFork: Bool,
        onFork: (() -> Void)?,
        itemID: String? = nil,
        sessionId: String = "",
        agentId: String? = nil,
        agentIcon: IconChoice? = nil,
        iconAssetCache: IconAssetCache? = nil,
        interactionContext: TimelineInteractionContext? = nil,
        serverID: String? = nil,
        workspaceID: String? = nil,
        worktreeId: String? = nil,
        serverBaseURL: URL? = nil,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? = nil,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)? = nil,
        fetchHostFile: ((_ path: String) async throws -> Data)? = nil,
        makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider? = nil,
        makeMarkdownAudioSource: MarkdownAudioMediaSourceProvider? = nil,
        makeTimedTextSidecar: TimedTextSidecarProvider? = nil,
        audioPlayer: AudioPlayerService? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.canFork = canFork
        self.onFork = onFork
        self.itemID = itemID
        self.sessionId = sessionId
        self.agentId = agentId
        self.agentIcon = agentIcon
        self.iconAssetCache = iconAssetCache
        self.interactionContext = interactionContext
        self.serverID = serverID
        self.workspaceID = workspaceID
        self.worktreeId = worktreeId
        self.serverBaseURL = serverBaseURL
        self.fetchWorkspaceFile = fetchWorkspaceFile
        self.fetchSessionFile = fetchSessionFile
        self.fetchHostFile = fetchHostFile
        self.makeMarkdownVideoSource = makeMarkdownVideoSource
        self.makeMarkdownAudioSource = makeMarkdownAudioSource
        self.makeTimedTextSidecar = makeTimedTextSidecar
        self.audioPlayer = audioPlayer
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

    /// Bubble padding and avatar geometry for the hanging content layout.
    /// Content uses the full bubble width; the avatar only reserves space on the
    /// first text lines (via exclusion path), then later lines/blocks run under it.
    static let bubbleLeadingPadding: CGFloat = 10
    static let bubbleTrailingPadding: CGFloat = 6
    static let bubbleVerticalPadding: CGFloat = 8
    static let avatarSize: CGFloat = 18
    static let avatarTopPadding: CGFloat = 10
    static let avatarContentGap: CGFloat = 8
    static var avatarContentClearance: CGFloat { avatarSize + avatarContentGap }
    /// Exclusion height relative to markdown top so line 1 clears the badge.
    /// That band sits only ~2pt below the 18pt avatar; block-first content needs
    /// extra air so media is not flush under the badge.
    static var avatarHangHeight: CGFloat {
        max(avatarSize, (avatarTopPadding - bubbleVerticalPadding) + avatarSize + 2)
    }
    /// Extra top margin when the first markdown segment is a block (audio,
    /// video, image, code, table) so it hangs below the avatar band.
    static let avatarBlockHangExtraTop: CGFloat = 10
    static var avatarBlockHangHeight: CGFloat {
        avatarHangHeight + avatarBlockHangExtraTop
    }

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

            // Avatar stays top-leading. Markdown is full-bleed inside the bubble
            // so multi-line prose, tables, and code reclaim the avatar column
            // after the first line.
            iconBadge.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            iconBadge.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            iconBadge.leadingAnchor.constraint(
                equalTo: bubbleContainer.leadingAnchor,
                constant: Self.bubbleLeadingPadding
            ),
            iconBadge.topAnchor.constraint(
                equalTo: bubbleContainer.topAnchor,
                constant: Self.avatarTopPadding
            ),

            markdownView.leadingAnchor.constraint(
                equalTo: bubbleContainer.leadingAnchor,
                constant: Self.bubbleLeadingPadding
            ),
            markdownView.topAnchor.constraint(
                equalTo: bubbleContainer.topAnchor,
                constant: Self.bubbleVerticalPadding
            ),
            markdownView.trailingAnchor.constraint(
                equalTo: bubbleContainer.trailingAnchor,
                constant: -Self.bubbleTrailingPadding
            ),
            markdownView.bottomAnchor.constraint(
                equalTo: bubbleContainer.bottomAnchor,
                constant: -Self.bubbleVerticalPadding
            ),
        ])

        bubbleContainer.bringSubviewToFront(iconBadge)
        markdownView.leadingHangClearance = Self.avatarContentClearance
        markdownView.leadingHangHeight = Self.avatarHangHeight
    }

    private func apply(configuration: AssistantTimelineRowConfiguration) {
        currentConfiguration = configuration
        accessibilityIdentifier = configuration.itemID.map { "chat.timeline.assistant.\($0)" }

        let palette = ThemeRuntimeState.currentPalette()
        iconBadge.configure(
            sessionId: configuration.sessionId,
            agentId: configuration.agentId,
            agentIcon: configuration.agentIcon,
            iconAssetCache: configuration.iconAssetCache,
            agentVisualScale: ChatAgentIconStyle.compactVisualScale
        )
        bubbleContainer.backgroundColor = UIColor(palette.purple).withAlphaComponent(TimelineBubbleStyle.subtleBgAlpha)

        let trimmedText = configuration.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Unified markdown path for both streaming and done states.
        // During streaming, the incremental parser (tail-only CommonMark parse
        // with FNV-1a prefix caching) keeps main-thread cost low. The segment
        // applier does structural diffing and only updates the growing tail.
        // The segment applier settles only the newly appended TextKit range.
        markdownView.fetchWorkspaceFile = configuration.fetchWorkspaceFile
        markdownView.fetchSessionFile = configuration.fetchSessionFile
        markdownView.fetchHostFile = configuration.fetchHostFile
        markdownView.makeMarkdownVideoSource = configuration.makeMarkdownVideoSource
        markdownView.makeMarkdownAudioSource = configuration.makeMarkdownAudioSource
        markdownView.makeTimedTextSidecar = configuration.makeTimedTextSidecar
        markdownView.audioPlayer = configuration.audioPlayer
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
            serverID: configuration.serverID,
            workspaceID: configuration.workspaceID,
            worktreeId: configuration.worktreeId,
            sessionID: configuration.sessionId,
            serverBaseURL: configuration.serverBaseURL,
            perfSurface: .inlineAssistant
        ))
    }

    func setMarkdownVideoPlaybackVisible(_ visible: Bool) {
        markdownView.setVideoPlaybackVisible(visible)
    }

    func prepareMarkdownVideosForRemoval() {
        markdownView.stopMarkdownVideoPlayback()
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
