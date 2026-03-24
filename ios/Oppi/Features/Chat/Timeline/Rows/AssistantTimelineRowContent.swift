import UIKit

/// Native UIKit assistant row — unified renderer for all assistant content.
///
/// Handles both plain text and rich markdown (headings, lists, code blocks,
/// tables, inline formatting) via `AssistantMarkdownContentView`.
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

    /// Lightweight streaming text view — plain UITextView with no markdown.
    /// Shown during streaming, hidden when done. Avoids the full segment
    /// pipeline cost on every 33ms tick.
    private let streamingTextView: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    /// Character reveal for streaming text — fades in new characters.
    private let streamingRevealer = StreamingTextRevealer()
    /// Character count from the last streaming apply cycle.
    private var streamingCharCount: Int = 0
    /// Whether we're currently showing the streaming text view.
    private var isShowingStreamingView = false

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
        bubbleContainer.addSubview(streamingTextView)
        interactionHandlers = TimelineRowInteractionInstaller.install(
            on: bubbleContainer,
            provider: self
        )

        // Streaming text view shares the same frame as markdown view.
        // Only one is visible at a time.
        streamingTextView.isHidden = true
        streamingTextView.font = AppFont.messageBody
        streamingTextView.textColor = UIColor(ThemeRuntimeState.currentPalette().fg)

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

            streamingTextView.leadingAnchor.constraint(equalTo: markdownView.leadingAnchor),
            streamingTextView.topAnchor.constraint(equalTo: markdownView.topAnchor),
            streamingTextView.trailingAnchor.constraint(equalTo: markdownView.trailingAnchor),
            streamingTextView.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -8),
        ])
    }

    private func apply(configuration: AssistantTimelineRowConfiguration) {
        let wasStreaming = currentConfiguration.isStreaming
        currentConfiguration = configuration

        let palette = ThemeRuntimeState.currentPalette()
        iconLabel.textColor = UIColor(palette.purple)
        bubbleContainer.backgroundColor = UIColor(palette.purple).withAlphaComponent(TimelineBubbleStyle.subtleBgAlpha)

        let trimmedText = configuration.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if configuration.isStreaming {
            // Streaming phase: use the lightweight text view (no markdown parsing).
            applyStreamingText(trimmedText, palette: palette)
        } else if wasStreaming && isShowingStreamingView {
            // Transition: streaming just ended. Build final markdown and crossfade.
            applyStreamingToMarkdownTransition(trimmedText, configuration: configuration, palette: palette)
        } else {
            // Idle: full markdown rendering (history load, re-entry).
            showMarkdownView()
            markdownView.fetchWorkspaceFile = configuration.fetchWorkspaceFile
            markdownView.apply(configuration: .init(
                content: trimmedText,
                isStreaming: false,
                themeID: ThemeRuntimeState.currentThemeID(),
                selectedTextPiRouter: configuration.interactionContext?.selectedTextPiRouter,
                selectedTextSourceContext: configuration.interactionContext?.sourceContext(
                    surface: .assistantProse
                ),
                workspaceID: configuration.workspaceID,
                serverBaseURL: configuration.serverBaseURL
            ))
        }
    }

    // MARK: - Streaming / Markdown Switch

    private func applyStreamingText(_ text: String, palette: ThemePalette) {
        showStreamingView()

        let fgColor = UIColor(palette.fg)
        streamingTextView.font = AppFont.messageBody
        streamingTextView.textColor = fgColor

        let attrText = NSAttributedString(
            string: text,
            attributes: [
                .font: AppFont.messageBody,
                .foregroundColor: fgColor,
            ]
        )
        let prevCount = streamingCharCount
        streamingTextView.attributedText = attrText

        // Reveal new characters with a gentle fade.
        let currentCount = attrText.length
        if currentCount > prevCount {
            streamingRevealer.reveal(
                in: streamingTextView,
                normalizedText: attrText,
                previousVisibleCount: prevCount
            )
        }
        streamingCharCount = currentCount
    }

    private func applyStreamingToMarkdownTransition(
        _ text: String,
        configuration: AssistantTimelineRowConfiguration,
        palette: ThemePalette
    ) {
        // Build final markdown while streaming view is still visible.
        markdownView.fetchWorkspaceFile = configuration.fetchWorkspaceFile
        markdownView.apply(configuration: .init(
            content: text,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID(),
            selectedTextPiRouter: configuration.interactionContext?.selectedTextPiRouter,
            selectedTextSourceContext: configuration.interactionContext?.sourceContext(
                surface: .assistantProse
            ),
            workspaceID: configuration.workspaceID,
            serverBaseURL: configuration.serverBaseURL
        ))

        // Quick crossfade from streaming text to rendered markdown.
        markdownView.alpha = 0
        markdownView.isHidden = false

        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseInOut) {
            self.markdownView.alpha = 1
            self.streamingTextView.alpha = 0
        } completion: { _ in
            self.streamingTextView.isHidden = true
            self.streamingTextView.alpha = 1
            self.streamingTextView.attributedText = nil
            self.isShowingStreamingView = false
            self.streamingCharCount = 0
            self.streamingRevealer.reset()
        }
    }

    private func showStreamingView() {
        guard !isShowingStreamingView else { return }
        isShowingStreamingView = true
        streamingTextView.isHidden = false
        streamingTextView.alpha = 1
        markdownView.isHidden = true
        markdownView.clearContent()
    }

    private func showMarkdownView() {
        if isShowingStreamingView {
            isShowingStreamingView = false
            streamingTextView.isHidden = true
            streamingTextView.attributedText = nil
            streamingCharCount = 0
            streamingRevealer.reset()
        }
        markdownView.isHidden = false
        markdownView.alpha = 1
    }

}
