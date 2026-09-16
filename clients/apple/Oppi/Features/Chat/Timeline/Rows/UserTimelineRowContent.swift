import SwiftUI
import UIKit

/// Non-scrollable UITextView that lets the outer timeline own vertical drags.
///
/// User rows enable text selection for the Comment action. A plain selectable
/// `UITextView` still wants to begin its internal pan gesture even when
/// scrolling is disabled, which prevents the outer chat timeline from entering
/// a user-drag state and can trigger detached-anchor snap-back.
private final class VerticalPanPassthroughTextView: UITextView {
    override func layoutSubviews() {
        super.layoutSubviews()

        if !isScrollEnabled {
            let desiredOffset = CGPoint(
                x: -adjustedContentInset.left,
                y: -adjustedContentInset.top
            )

            if abs(contentOffset.x - desiredOffset.x) > 0.5
                || abs(contentOffset.y - desiredOffset.y) > 0.5 {
                contentOffset = desiredOffset
            }
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, !isScrollEnabled {
            return false
        }

        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// Native UIKit user row — handles text, upload badges, repo-pointer badges, and image messages.
struct UserTimelineRowConfiguration: UIContentConfiguration {
    let text: String
    let images: [ImageAttachment]
    var fetchWorkspaceFileData: ((_ path: String) async throws -> Data)? = nil
    var onOpenPathPill: ((UserMessagePathPill, UIView) -> Void)? = nil
    let canFork: Bool
    let onFork: (() -> Void)?
    var itemID: String? = nil
    var interactionContext: TimelineInteractionContext? = nil

    func makeContentView() -> any UIView & UIContentView {
        UserTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class UserTimelineRowContentView: UIView, UIContentView, TimelineRowInteractionProvider {
    /// UIControl so the outer timeline can cancel the touch and take a vertical
    /// drag. A tap recognizer on the first-row commit chip ate pull-to-top.
    private final class PathPillControl: UIControl {
        override var isHighlighted: Bool {
            didSet { alpha = isHighlighted ? 0.72 : 1 }
        }
    }

    private final class PathPillTapHandler: NSObject {
        weak var owner: UserTimelineRowContentView?
        let pill: UserMessagePathPill

        init(owner: UserTimelineRowContentView, pill: UserMessagePathPill) {
            self.owner = owner
            self.pill = pill
        }

        @MainActor
        @objc func handleTap() {
            owner?.openPathPill(pill)
        }
    }

    private let outerStack = UIStackView()
    private let bubbleContainer = UIView()
    private let bubbleStack = UIStackView()
    private let attachmentBadgeRow = UIStackView()
    private let pathPillRow = UIStackView()
    private let textRow = UIStackView()
    private let iconLabel = UILabel()
    private let bodyStack = UIStackView()
    private let messageTextView = VerticalPanPassthroughTextView()
    private var extraMarkdownTextViews: [VerticalPanPassthroughTextView] = []
    private var tableBlockViews: [NativeTableBlockView] = []
    private let imageStrip = UIScrollView()
    private let imageStack = UIStackView()

    private static let thumbnailSize: CGFloat = 80
    private static let thumbnailCornerRadius: CGFloat = TimelineBubbleStyle.thumbnailCornerRadius
    private static let maxDisplayCharacters = 12_000
    private static let maxDisplayLines = 220
    private static let truncatedDisplaySuffix = "\n\n… message truncated for display. Use Copy for full content."
    private static let slowApplyThresholdMs = 120

    private var currentConfiguration: UserTimelineRowConfiguration
    private var decodeTasks: [Task<Void, Never>] = []
    private var thumbnailViews: [UIView] = []
    private var hasAppliedConfiguration = false
    private var previousThemeID: ThemeID?
    private var interactionHandlers: TimelineRowInteractionHandlers?
    private var pathPillTapHandlers: [PathPillTapHandler] = []

    // MARK: - TimelineRowInteractionProvider

    var copyableText: String? {
        let text = UserMessageAttachmentPresentation.parse(rawText: currentConfiguration.text).visibleText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    var interactionFeedbackView: UIView { bubbleContainer }

    var supportsFork: Bool {
        currentConfiguration.canFork && currentConfiguration.onFork != nil
    }

    var forkAction: (() -> Void)? { currentConfiguration.onFork }

    private var isReviewCommentSelectionEnabled: Bool {
        currentConfiguration.interactionContext?.reviewCommentSelectionContext != nil
    }

    init(configuration: UserTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? UserTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .clear

        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.axis = .vertical
        outerStack.alignment = .fill
        outerStack.spacing = 6

        // Image strip (horizontal scroll of thumbnails).
        imageStrip.translatesAutoresizingMaskIntoConstraints = false
        imageStrip.showsHorizontalScrollIndicator = false
        imageStrip.clipsToBounds = false

        imageStack.translatesAutoresizingMaskIntoConstraints = false
        imageStack.axis = .horizontal
        imageStack.spacing = 8
        imageStrip.addSubview(imageStack)

        NSLayoutConstraint.activate([
            imageStack.topAnchor.constraint(equalTo: imageStrip.contentLayoutGuide.topAnchor),
            imageStack.leadingAnchor.constraint(equalTo: imageStrip.contentLayoutGuide.leadingAnchor, constant: 24),
            imageStack.trailingAnchor.constraint(equalTo: imageStrip.contentLayoutGuide.trailingAnchor),
            imageStack.bottomAnchor.constraint(equalTo: imageStrip.contentLayoutGuide.bottomAnchor),
            imageStack.heightAnchor.constraint(equalTo: imageStrip.frameLayoutGuide.heightAnchor),
            imageStrip.heightAnchor.constraint(equalToConstant: Self.thumbnailSize),
        ])

        // Bubble container — subtle accent-tinted background.
        bubbleContainer.translatesAutoresizingMaskIntoConstraints = false
        bubbleContainer.layer.cornerRadius = TimelineBubbleStyle.bubbleCornerRadius
        bubbleContainer.clipsToBounds = true

        bubbleStack.translatesAutoresizingMaskIntoConstraints = false
        bubbleStack.axis = .vertical
        bubbleStack.alignment = .fill
        bubbleStack.spacing = 6

        attachmentBadgeRow.translatesAutoresizingMaskIntoConstraints = false
        attachmentBadgeRow.axis = .horizontal
        attachmentBadgeRow.alignment = .leading
        attachmentBadgeRow.spacing = 6

        pathPillRow.translatesAutoresizingMaskIntoConstraints = false
        pathPillRow.axis = .vertical
        pathPillRow.alignment = .leading
        pathPillRow.spacing = 6

        // Text row (❯ + message).
        textRow.translatesAutoresizingMaskIntoConstraints = false
        textRow.axis = .horizontal
        textRow.alignment = .top
        textRow.spacing = 6

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.text = "❯"
        iconLabel.font = AppFont.monoLargeSemibold
        iconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)

        messageTextView.translatesAutoresizingMaskIntoConstraints = false
        messageTextView.isEditable = false
        messageTextView.isScrollEnabled = false
        messageTextView.isSelectable = false
        messageTextView.delegate = self
        messageTextView.backgroundColor = .clear
        messageTextView.textContainerInset = .zero
        messageTextView.textContainer.lineFragmentPadding = 0
        messageTextView.textContainer.lineBreakMode = .byWordWrapping
        messageTextView.adjustsFontForContentSizeCategory = true
        messageTextView.font = AppFont.messageBody

        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.alignment = .fill
        bodyStack.spacing = 8
        bodyStack.addArrangedSubview(messageTextView)

        textRow.addArrangedSubview(iconLabel)
        textRow.addArrangedSubview(bodyStack)

        bubbleStack.addArrangedSubview(attachmentBadgeRow)
        bubbleStack.addArrangedSubview(pathPillRow)
        bubbleStack.addArrangedSubview(textRow)
        bubbleContainer.addSubview(bubbleStack)
        NSLayoutConstraint.activate([
            bubbleStack.topAnchor.constraint(equalTo: bubbleContainer.topAnchor, constant: 8),
            bubbleStack.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 10),
            bubbleStack.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -10),
            bubbleStack.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -8),
        ])

        outerStack.addArrangedSubview(imageStrip)
        outerStack.addArrangedSubview(bubbleContainer)

        addSubview(outerStack)

        // User row uses manual interaction wiring (not the shared installer)
        // because it needs custom context menu filtering for the selectable
        // text area. The protocol's buildContextMenu() is still used.
        let doubleTapHandler = TimelineRowDoubleTapHandler()
        doubleTapHandler.provider = self
        let gesture = DoubleTapCopyGesture.makeGesture(
            target: doubleTapHandler,
            action: #selector(TimelineRowDoubleTapHandler.handleDoubleTap)
        )
        bubbleContainer.addGestureRecognizer(gesture)
        addInteraction(UIContextMenuInteraction(delegate: self))

        // Store a placeholder handlers struct to keep the doubleTapHandler alive
        // and provide gesture access for selection policy updates.
        let contextMenuHandler = TimelineRowContextMenuHandler()
        contextMenuHandler.provider = self
        interactionHandlers = TimelineRowInteractionHandlers(
            doubleTapHandler: doubleTapHandler,
            contextMenuHandler: contextMenuHandler,
            gesture: gesture
        )

        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            outerStack.topAnchor.constraint(equalTo: topAnchor),
            outerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Apply

    private func apply(configuration: UserTimelineRowConfiguration) {
        let applyStartNs = ChatTimelinePerf.timestampNs()
        let previousConfiguration = currentConfiguration
        currentConfiguration = configuration

        let palette = ThemeRuntimeState.currentPalette()
        iconLabel.textColor = UIColor(palette.blue)
        messageTextView.textColor = UIColor(palette.userMessageText)
        messageTextView.font = AppFont.messageBody

        // User bubbles get their own semantic surface so theme authors can
        // push them warmer/cooler than the rest of the chrome.
        bubbleContainer.backgroundColor = UIColor(palette.userMessageBg)

        let parsed = UserMessageAttachmentPresentation.parse(rawText: configuration.text)
        let displayText = Self.displayText(for: parsed.visibleText)
        applyMarkdownBody(displayText.text, palette: palette)
        let inlineImagePathPills = parsed.pathPills.filter { pill in
            guard pill.supportsInlinePreview else { return false }
            // Uploaded image attachments can arrive in two forms for the same
            // user message: optimistic local image data plus the uploaded
            // workspace path pill. When both are present, prefer the real image
            // attachment and suppress the redundant inline file preview.
            if !configuration.images.isEmpty, pill.kind == .uploadedFile {
                return false
            }
            return true
        }
        let nonImagePathPills = parsed.pathPills.filter { !$0.supportsInlinePreview }
        let visibleBadges = filteredAttachmentBadges(
            parsed.badges,
            images: configuration.images,
            inlineImagePathPills: inlineImagePathPills,
            pathPills: parsed.pathPills
        )

        updateAttachmentBadges(visibleBadges, palette: palette)
        updatePathPills(nonImagePathPills, palette: palette)
        textRow.isHidden = displayText.text.isEmpty
        bubbleContainer.isHidden = displayText.text.isEmpty && configuration.images.isEmpty && visibleBadges.isEmpty && parsed.pathPills.isEmpty
        iconLabel.isHidden = displayText.text.isEmpty

        updateReviewCommentSelectionPolicy()

        let currentThemeID = ThemeRuntimeState.currentThemeID()
        let imagesChanged = previousConfiguration.images != configuration.images
        let inlineImagePillsChanged = UserMessageAttachmentPresentation.parse(rawText: previousConfiguration.text).pathPills.filter(\.supportsInlinePreview) != inlineImagePathPills
        let fetchChanged = previousConfiguration.fetchWorkspaceFileData == nil && configuration.fetchWorkspaceFileData != nil
        let paletteChanged = previousThemeID != currentThemeID
        let shouldRefreshImages = !hasAppliedConfiguration || imagesChanged || inlineImagePillsChanged || fetchChanged || paletteChanged
        if shouldRefreshImages {
            updateImageStrip(images: configuration.images, inlineImagePathPills: inlineImagePathPills, palette: palette)
        }

        previousThemeID = currentThemeID
        hasAppliedConfiguration = true

        let durationMs = ChatTimelinePerf.elapsedMs(since: applyStartNs)
        if durationMs >= Self.slowApplyThresholdMs {
            ClientLog.info(
                "ChatPerf",
                "Slow user row apply",
                metadata: [
                    "durationMs": String(durationMs),
                    "textChars": String(configuration.text.count),
                    "displayChars": String(displayText.text.count),
                    "displayTruncated": displayText.wasTruncated ? "true" : "false",
                    "imageCount": String(configuration.images.count),
                    "imageBase64Chars": String(Self.totalBase64CharacterCount(for: configuration.images)),
                    "imagesChanged": imagesChanged ? "true" : "false",
                    "paletteChanged": paletteChanged ? "true" : "false",
                ]
            )
        }
    }

    private static func displayText(for rawText: String) -> (text: String, wasTruncated: Bool) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("", false)
        }

        var text = trimmed
        var wasTruncated = false

        if text.count > Self.maxDisplayCharacters {
            text = String(text.prefix(Self.maxDisplayCharacters))
            wasTruncated = true
        }

        if let lineTrimmed = truncatedToMaxLines(text, maxLines: Self.maxDisplayLines) {
            text = lineTrimmed
            wasTruncated = true
        }

        guard wasTruncated else {
            return (text, false)
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (normalized + Self.truncatedDisplaySuffix, true)
    }

    private static func truncatedToMaxLines(_ text: String, maxLines: Int) -> String? {
        guard maxLines > 0 else {
            return ""
        }

        var lineCount = 1
        var index = text.startIndex

        while index < text.endIndex {
            if text[index].isNewline {
                lineCount += 1
                if lineCount > maxLines {
                    return String(text[..<index])
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    private static func totalBase64CharacterCount(for images: [ImageAttachment]) -> Int {
        images.reduce(into: 0) { partialResult, image in
            partialResult += image.data.count
        }
    }

    private var markdownTextViews: [UITextView] {
        [messageTextView] + extraMarkdownTextViews
    }

    private func applyMarkdownBody(_ text: String, palette: ThemePalette) {
        guard !text.isEmpty else {
            resetMarkdownBodyToSingleTextView()
            messageTextView.attributedText = nil
            messageTextView.isHidden = true
            return
        }

        let pieces = FlatSegment.renderMarkdownPieces(
            text,
            defaultTextColor: UIColor(palette.userMessageText),
            palette: palette
        )
        let hasTable = pieces.contains {
            if case .table = $0 { return true }
            return false
        }
        guard hasTable else {
            resetMarkdownBodyToSingleTextView()
            if case .attributed(let attributed) = pieces.first {
                messageTextView.attributedText = attributed
            } else {
                messageTextView.attributedText = nil
            }
            messageTextView.isHidden = (messageTextView.attributedText?.length ?? 0) == 0
            return
        }

        clearExtraMarkdownViews()
        messageTextView.removeFromSuperview()
        messageTextView.attributedText = nil
        messageTextView.isHidden = true

        var usedPrimaryTextView = false
        for piece in pieces {
            switch piece {
            case .attributed(let attributed):
                if !usedPrimaryTextView {
                    messageTextView.attributedText = attributed
                    messageTextView.isHidden = false
                    bodyStack.addArrangedSubview(messageTextView)
                    usedPrimaryTextView = true
                } else {
                    let extra = makeExtraMarkdownTextView()
                    extra.attributedText = attributed
                    extra.textColor = UIColor(palette.userMessageText)
                    bodyStack.addArrangedSubview(extra)
                    extraMarkdownTextViews.append(extra)
                }

            case .table(let headers, let rows):
                let table = NativeTableBlockView()
                table.apply(headers: headers, rows: rows, palette: palette)
                bodyStack.addArrangedSubview(table)
                tableBlockViews.append(table)
            }
        }
    }

    private func resetMarkdownBodyToSingleTextView() {
        clearExtraMarkdownViews()
        if messageTextView.superview !== bodyStack {
            bodyStack.insertArrangedSubview(messageTextView, at: 0)
        }
    }

    private func clearExtraMarkdownViews() {
        for view in extraMarkdownTextViews {
            bodyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in tableBlockViews {
            bodyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        extraMarkdownTextViews.removeAll()
        tableBlockViews.removeAll()
    }

    private func makeExtraMarkdownTextView() -> VerticalPanPassthroughTextView {
        let textView = VerticalPanPassthroughTextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.adjustsFontForContentSizeCategory = true
        textView.font = AppFont.messageBody
        return textView
    }

    private func updateReviewCommentSelectionPolicy() {
        let selectionEnabled = isReviewCommentSelectionEnabled
        messageTextView.isSelectable = selectionEnabled && !messageTextView.isHidden
        for textView in extraMarkdownTextViews {
            textView.isSelectable = selectionEnabled && !textView.isHidden
        }
        let anySelectable = messageTextView.isSelectable
            || extraMarkdownTextViews.contains(where: \.isSelectable)
        interactionHandlers?.gesture.isEnabled = !anySelectable

        let tableContext = currentConfiguration.interactionContext?.sourceContext(
            surface: .userMessage,
            timelineItemId: currentConfiguration.itemID
        )
        for table in tableBlockViews {
            table.configureReviewCommentSelection(
                router: currentConfiguration.interactionContext?.reviewCommentSelectionRouter,
                sourceContext: tableContext
            )
        }
    }

    private func filteredAttachmentBadges(
        _ badges: [UserMessageAttachmentBadge],
        images: [ImageAttachment],
        inlineImagePathPills: [UserMessagePathPill],
        pathPills: [UserMessagePathPill]
    ) -> [UserMessageAttachmentBadge] {
        let hasVisibleInlineImages = !images.isEmpty || !inlineImagePathPills.isEmpty
        let hasVisibleUploadedFilePills = pathPills.contains { $0.kind == .uploadedFile }

        return badges.filter { badge in
            switch badge.kind {
            case .photos:
                return !hasVisibleInlineImages
            case .uploadedFiles:
                return !hasVisibleUploadedFilePills
            }
        }
    }

    private func updateAttachmentBadges(_ badges: [UserMessageAttachmentBadge], palette: ThemePalette) {
        clearArrangedSubviews(in: attachmentBadgeRow)

        attachmentBadgeRow.isHidden = badges.isEmpty
        guard !badges.isEmpty else { return }

        for badge in badges {
            attachmentBadgeRow.addArrangedSubview(
                makeCapsuleView(
                    prefix: nil,
                    text: badge.label,
                    symbolName: badge.symbolName,
                    tint: UIColor(palette.userMessageText).withAlphaComponent(0.72),
                    background: UIColor(palette.bg).withAlphaComponent(0.35),
                    textColor: UIColor(palette.userMessageText).withAlphaComponent(0.9),
                    font: AppFont.systemSmall,
                    monospaced: false
                )
            )
        }
    }

    private func updatePathPills(_ pathPills: [UserMessagePathPill], palette: ThemePalette) {
        clearArrangedSubviews(in: pathPillRow)

        pathPillRow.isHidden = pathPills.isEmpty
        guard !pathPills.isEmpty else { return }

        for pill in pathPills {
            let tint: UIColor = switch pill.kind {
            case .uploadedFile:
                UIColor(palette.blue)
            case .reviewFile:
                UIColor(palette.cyan)
            case .repoFile:
                UIColor(palette.purple)
            case .gitCommit:
                UIColor(palette.orange)
            }

            let pillView = makeCapsuleView(
                prefix: pill.prefix,
                text: pill.label,
                symbolName: pill.symbolName,
                tint: tint,
                background: tint.withAlphaComponent(0.10),
                textColor: UIColor(palette.userMessageText),
                font: AppFont.monoSmall,
                monospaced: true,
                tappable: true
            )
            pillView.accessibilityIdentifier = "chat.user.path-pill.\(pill.path)"
            pillView.accessibilityLabel = "\(pill.prefix) \(pill.label)"
            pillView.accessibilityTraits = .button
            pillView.isAccessibilityElement = true
            if let control = pillView as? UIControl {
                let capturedPill = pill
                control.addAction(UIAction { [weak self] _ in
                    self?.openPathPill(capturedPill)
                }, for: .touchUpInside)
            }
            pathPillRow.addArrangedSubview(pillView)
        }
    }

    private func clearArrangedSubviews(in stackView: UIStackView) {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func openPathPill(_ pill: UserMessagePathPill) {
        currentConfiguration.onOpenPathPill?(pill, self)
    }

    private func makeCapsuleView(
        prefix: String?,
        text: String,
        symbolName: String,
        tint: UIColor,
        background: UIColor,
        textColor: UIColor,
        font: UIFont,
        monospaced: Bool,
        tappable: Bool = false
    ) -> UIView {
        let container: UIView = tappable ? PathPillControl() : UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = background
        container.layer.cornerRadius = 11
        container.layer.borderWidth = 1
        container.layer.borderColor = tint.withAlphaComponent(0.22).cgColor
        container.clipsToBounds = true

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4

        let icon = UIImageView(image: UIImage(systemName: symbolName))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
        ])
        stack.addArrangedSubview(icon)

        if let prefix, !prefix.isEmpty {
            let prefixLabel = UILabel()
            prefixLabel.translatesAutoresizingMaskIntoConstraints = false
            prefixLabel.font = AppFont.systemSmall
            prefixLabel.textColor = tint
            prefixLabel.text = prefix
            prefixLabel.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(prefixLabel)
        }

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = textColor
        label.text = text
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.adjustsFontForContentSizeCategory = true
        if monospaced {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        stack.addArrangedSubview(label)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
        ])
        return container
    }

    // MARK: - Image strip

    private func updateImageStrip(
        images: [ImageAttachment],
        inlineImagePathPills: [UserMessagePathPill],
        palette: ThemePalette
    ) {
        // Cancel outstanding decodes.
        for task in decodeTasks { task.cancel() }
        decodeTasks.removeAll()

        // Clear previous thumbnails.
        for view in thumbnailViews {
            imageStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        thumbnailViews.removeAll()
        pathPillTapHandlers.removeAll()

        let hasAnyInlineMedia = !images.isEmpty || !inlineImagePathPills.isEmpty
        imageStrip.isHidden = !hasAnyInlineMedia
        guard hasAnyInlineMedia else { return }

        let borderColor = UIColor(palette.comment).withAlphaComponent(TimelineBubbleStyle.thumbnailBorderAlpha).cgColor

        for (index, attachment) in images.enumerated() {
            let container = makeThumbnailContainer(
                borderColor: borderColor,
                accessibilityIdentifier: "chat.user.thumbnail.\(index)",
                accessibilityLabel: "Attached image \(index + 1)"
            )

            container.isUserInteractionEnabled = true

            imageStack.addArrangedSubview(container)
            thumbnailViews.append(container)

            if let data = Data(base64Encoded: attachment.data, options: .ignoreUnknownCharacters) {
                installThumbnail(data: data, mimeType: attachment.mimeType, in: container, allowsFullscreen: true)
            } else {
                container.subviews.forEach { $0.removeFromSuperview() }
                let fallback = UIImageView(image: UIImage(systemName: "photo.badge.exclamationmark"))
                fallback.translatesAutoresizingMaskIntoConstraints = false
                fallback.tintColor = UIColor(palette.comment)
                fallback.contentMode = .scaleAspectFit
                container.addSubview(fallback)
                pinThumbnailContent(fallback, in: container, inset: 18)
            }
        }

        for (offset, pill) in inlineImagePathPills.enumerated() {
            let container = makeThumbnailContainer(
                borderColor: borderColor,
                accessibilityIdentifier: "chat.user.inline-path-thumbnail.\(offset)",
                accessibilityLabel: pill.label
            )
            let tapHandler = PathPillTapHandler(owner: self, pill: pill)
            let tap = UITapGestureRecognizer(target: tapHandler, action: #selector(PathPillTapHandler.handleTap))
            container.addGestureRecognizer(tap)
            container.isUserInteractionEnabled = true
            pathPillTapHandlers.append(tapHandler)

            imageStack.addArrangedSubview(container)
            thumbnailViews.append(container)

            guard let fetch = currentConfiguration.fetchWorkspaceFileData else { continue }
            let ext = (pill.path as NSString).pathExtension.lowercased()
            let mimeType = MediaMimeType.imageMimeType(forPathExtension: ext) ?? "application/octet-stream"
            let task = Task { [weak self, weak container] in
                do {
                    let data = try await fetch(pill.path)
                    guard !Task.isCancelled, let self, let container else { return }
                    self.installThumbnail(data: data, mimeType: mimeType, in: container, allowsFullscreen: false)
                } catch {
                    guard !Task.isCancelled, let container else { return }
                    container.subviews.forEach { $0.removeFromSuperview() }
                    let fallback = UIImageView(image: UIImage(systemName: "photo"))
                    fallback.translatesAutoresizingMaskIntoConstraints = false
                    fallback.tintColor = UIColor(palette.comment)
                    fallback.contentMode = .scaleAspectFit
                    container.addSubview(fallback)
                    self?.pinThumbnailContent(fallback, in: container, inset: 18)
                }
            }
            decodeTasks.append(task)
        }
    }

    private func installThumbnail(data: Data, mimeType: String, in container: UIView, allowsFullscreen: Bool) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let thumbnail = UserTimelineImageThumbnailView()
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(thumbnail)
        pinThumbnailContent(thumbnail, in: container)
        let task = Task { [weak thumbnail] in
            let content = await Task.detached(priority: .userInitiated) {
                UserTimelineImageThumbnailView.decode(data: data, mimeType: mimeType)
            }.value
            guard !Task.isCancelled, let thumbnail else { return }
            thumbnail.apply(content, data: data, mimeType: mimeType, allowsFullscreen: allowsFullscreen)
        }
        decodeTasks.append(task)
    }

    private func makeThumbnailContainer(
        borderColor: CGColor,
        accessibilityIdentifier: String,
        accessibilityLabel: String
    ) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = Self.thumbnailCornerRadius
        container.layer.borderWidth = 1
        container.layer.borderColor = borderColor
        container.clipsToBounds = true
        container.backgroundColor = UIColor(ThemeRuntimeState.currentPalette().bgHighlight)
        container.isAccessibilityElement = true
        container.accessibilityIdentifier = accessibilityIdentifier
        container.accessibilityLabel = accessibilityLabel
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        container.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.thumbnailSize),
            container.heightAnchor.constraint(equalToConstant: Self.thumbnailSize),
        ])
        return container
    }

    private func pinThumbnailContent(_ view: UIView, in container: UIView, inset: CGFloat = 0) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }

    // Note: double-tap copy and context menu are handled by
    // TimelineRowInteractionProvider + TimelineRowInteractionInstaller.
    // The UIContextMenuInteractionDelegate override below filters out
    // taps inside the selectable text area.
}

/// UIKit-only thumbnail; the row owns decode cancellation and path-pill taps.
@MainActor
private final class UserTimelineImageThumbnailView: UIView {
    enum Content: Sendable {
        case image(UIImage)
        case web(String)
        case failure
    }

    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let spinner = UIActivityIndicatorView(style: .medium)
        install(spinner)
        spinner.startAnimating()
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated static func decode(data: Data, mimeType: String) -> Content {
        let info = ImageMediaInspector.inspect(data: data, mimeType: mimeType)
        if info.prefersWebRenderer {
            let mime = MediaMimeType.safeImageMimeType(info.normalizedMimeType, fallback: "image/gif")
            return .web("data:\(mime);base64,\(data.base64EncodedString())")
        }
        if let image = ImageMediaInspector.downsampledImage(data: data, maxPixelSize: 512) {
            return .image(image)
        }
        if MediaMimeType.isSupportedImageMimeType(info.normalizedMimeType) {
            let mime = MediaMimeType.safeImageMimeType(info.normalizedMimeType)
            return .web("data:\(mime);base64,\(data.base64EncodedString())")
        }
        return .failure
    }

    func apply(_ content: Content, data: Data, mimeType: String, allowsFullscreen: Bool) {
        subviews.forEach { $0.removeFromSuperview() }
        switch content {
        case .image(let image):
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            install(imageView)
            onTap = { [weak self] in
                guard let self else { return }
                let resolved = UIImage(data: data) ?? image
                if ChatReaderOpenLookup.open(.image(resolved), from: self) {
                    return
                }
                ToolTimelineRowPresentationHelpers.presentFullScreenImage(resolved, from: self)
            }
        case .web(let dataURL):
            let web = AnimatedImageWebContainerView()
            web.isUserInteractionEnabled = false
            install(web)
            web.apply(dataURLString: dataURL)
            onTap = { [weak self] in
                if let self, ChatReaderOpenLookup.open(
                    .imageData(data, mimeType: mimeType),
                    from: self
                ) {
                    return
                }
                FullScreenImageDataPreviewPresenter.present(data: data, mimeType: mimeType)
            }
        case .failure:
            let label = UILabel()
            label.text = String(localized: "Image preview unavailable")
            label.font = .preferredFont(forTextStyle: .caption2)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = UIColor(ThemeRuntimeState.currentPalette().comment)
            label.textAlignment = .center
            label.numberOfLines = 3
            let icon = UIImageView(image: UIImage(systemName: "photo.badge.exclamationmark"))
            icon.tintColor = label.textColor
            icon.contentMode = .scaleAspectFit
            let stack = UIStackView(arrangedSubviews: [icon, label])
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                icon.heightAnchor.constraint(equalToConstant: 16),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            ])
            onTap = nil
        }
        // Path-pill containers alone own their tap, for static AND animated data.
        isUserInteractionEnabled = allowsFullscreen && onTap != nil
        if isUserInteractionEnabled {
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        }
    }

    @objc private func tapped() { onTap?() }

    private func install(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

// MARK: - Context Menu

extension UserTimelineRowContentView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: currentConfiguration.interactionContext?.reviewCommentSelectionContext?.dispatcher,
            sourceContext: currentConfiguration.interactionContext?.sourceContext(
                surface: .userMessage,
                timelineItemId: currentConfiguration.itemID
            )
        )
    }
}

extension UserTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        // Don't show context menu when tapping inside the selectable text area.
        for textView in markdownTextViews where textView.isSelectable {
            let pointInText = textView.convert(location, from: self)
            if textView.bounds.contains(pointInText) {
                return nil
            }
        }

        guard let menu = buildContextMenu() else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            menu
        }
    }
}
