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

        guard !isScrollEnabled else { return }

        let desiredOffset = CGPoint(
            x: -adjustedContentInset.left,
            y: -adjustedContentInset.top
        )

        guard abs(contentOffset.x - desiredOffset.x) > 0.5
                || abs(contentOffset.y - desiredOffset.y) > 0.5 else {
            return
        }

        contentOffset = desiredOffset
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
    var interactionContext: TimelineInteractionContext? = nil

    func makeContentView() -> any UIView & UIContentView {
        UserTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class UserTimelineRowContentView: UIView, UIContentView, TimelineRowInteractionProvider {
    private final class PathPillTapHandler: NSObject {
        weak var owner: UserTimelineRowContentView?
        let pill: UserMessagePathPill

        init(owner: UserTimelineRowContentView, pill: UserMessagePathPill) {
            self.owner = owner
            self.pill = pill
        }

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
    private let messageTextView = VerticalPanPassthroughTextView()
    private let imageStrip = UIScrollView()
    private let imageStack = UIStackView()

    private static let thumbnailSize: CGFloat = 80
    private static let thumbnailCornerRadius: CGFloat = TimelineBubbleStyle.thumbnailCornerRadius
    private static let maxDisplayCharacters = 12_000
    private static let maxDisplayLines = 220
    private static let truncatedDisplaySuffix = "\n… message truncated for display. Use Copy for full content."
    private static let slowApplyThresholdMs = 120

    private var currentConfiguration: UserTimelineRowConfiguration
    private var decodeTasks: [Task<Void, Never>] = []
    private var thumbnailViews: [UIView] = []
    private var thumbnailHostingControllers: [UIHostingController<DataImagePreviewView>] = []
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

    private var isSelectedTextPiEnabled: Bool {
        currentConfiguration.interactionContext?.selectedTextActionContext != nil
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

        textRow.addArrangedSubview(iconLabel)
        textRow.addArrangedSubview(messageTextView)

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
        if displayText.text.isEmpty {
            messageTextView.attributedText = nil
        } else {
            messageTextView.attributedText = FlatSegment.renderMarkdownInline(
                displayText.text,
                defaultTextColor: UIColor(palette.userMessageText),
                palette: palette
            )
        }
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
        messageTextView.isHidden = displayText.text.isEmpty
        textRow.isHidden = displayText.text.isEmpty
        bubbleContainer.isHidden = displayText.text.isEmpty && configuration.images.isEmpty && visibleBadges.isEmpty && parsed.pathPills.isEmpty
        iconLabel.isHidden = displayText.text.isEmpty

        updateSelectedTextInteractionPolicy()

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
            ClientLog.error(
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

    private func updateSelectedTextInteractionPolicy() {
        let selectionEnabled = isSelectedTextPiEnabled && !messageTextView.isHidden
        messageTextView.isSelectable = selectionEnabled
        interactionHandlers?.gesture.isEnabled = !selectionEnabled
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
        pathPillTapHandlers.removeAll()

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
            }

            let pillView = makeCapsuleView(
                prefix: pill.prefix,
                text: pill.label,
                symbolName: pill.symbolName,
                tint: tint,
                background: tint.withAlphaComponent(0.10),
                textColor: UIColor(palette.userMessageText),
                font: AppFont.monoSmall,
                monospaced: true
            )
            pillView.accessibilityIdentifier = "chat.user.path-pill.\(pill.path)"
            pillView.isUserInteractionEnabled = true
            let tapHandler = PathPillTapHandler(owner: self, pill: pill)
            let tap = UITapGestureRecognizer(target: tapHandler, action: #selector(PathPillTapHandler.handleTap))
            pillView.addGestureRecognizer(tap)
            pathPillTapHandlers.append(tapHandler)
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
        monospaced: Bool
    ) -> UIView {
        let container = UIView()
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
        thumbnailHostingControllers.removeAll()

        // Clear previous thumbnails.
        for view in thumbnailViews {
            imageStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        thumbnailViews.removeAll()

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

            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            container.addSubview(imageView)
            pinThumbnailContent(imageView, in: container)

            let tap = UITapGestureRecognizer(target: self, action: #selector(thumbnailTapped(_:)))
            container.addGestureRecognizer(tap)
            container.isUserInteractionEnabled = true

            imageStack.addArrangedSubview(container)
            thumbnailViews.append(container)

            let task = Task { [weak imageView] in
                let decoded = await Task.detached(priority: .userInitiated) {
                    guard let data = Data(base64Encoded: attachment.data, options: .ignoreUnknownCharacters) else {
                        return nil as UIImage?
                    }
                    return UIImage(data: data)
                }.value
                guard !Task.isCancelled, let imageView else { return }
                imageView.image = decoded
            }
            decodeTasks.append(task)
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
                    await MainActor.run {
                        let host = UIHostingController(
                            rootView: DataImagePreviewView(
                                data: data,
                                mimeType: mimeType,
                                maxPixelSize: 512,
                                maxHeight: Self.thumbnailSize,
                                allowsFullscreenStaticImage: false
                            )
                        )
                        host.view.translatesAutoresizingMaskIntoConstraints = false
                        host.view.backgroundColor = .clear
                        container.addSubview(host.view)
                        self.pinThumbnailContent(host.view, in: container)
                        self.thumbnailHostingControllers.append(host)
                    }
                } catch {
                    guard !Task.isCancelled, let container else { return }
                    await MainActor.run {
                        let fallback = UIImageView(image: UIImage(systemName: "photo"))
                        fallback.translatesAutoresizingMaskIntoConstraints = false
                        fallback.tintColor = UIColor(palette.comment)
                        fallback.contentMode = .scaleAspectFit
                        container.addSubview(fallback)
                        self?.pinThumbnailContent(fallback, in: container, inset: 18)
                    }
                }
            }
            decodeTasks.append(task)
        }
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

    @objc private func thumbnailTapped(_ gesture: UITapGestureRecognizer) {
        guard let container = gesture.view,
              let imageView = container.subviews.compactMap({ $0 as? UIImageView }).first,
              let image = imageView.image else { return }

        presentFullScreenImage(image)
    }

    private func presentFullScreenImage(_ image: UIImage) {
        ToolTimelineRowPresentationHelpers.presentFullScreenImage(image, from: self)
    }

    // Note: double-tap copy and context menu are handled by
    // TimelineRowInteractionProvider + TimelineRowInteractionInstaller.
    // The UIContextMenuInteractionDelegate override below filters out
    // taps inside the selectable text area.
}

// MARK: - Context Menu

extension UserTimelineRowContentView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        SelectedTextPiEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: currentConfiguration.interactionContext?.selectedTextActionContext?.dispatcher,
            sourceContext: currentConfiguration.interactionContext?.sourceContext(
                surface: .userMessage
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
        if messageTextView.isSelectable {
            let pointInMessageText = messageTextView.convert(location, from: self)
            if messageTextView.bounds.contains(pointInMessageText) {
                return nil
            }
        }

        guard let menu = buildContextMenu() else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            menu
        }
    }
}
