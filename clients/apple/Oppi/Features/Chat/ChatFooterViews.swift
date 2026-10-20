import UIKit

// The chat's own chrome around the composer and in the bar: the rows above
// and below the composer, the stopped session's footer, the jump-to-bottom
// hint, and the session title. Each view holds the chat weakly and reads it
// in `updateProperties()`, so UIKit observation repaints it when what it
// shows changes; their heights follow from Auto Layout in the footer stack.

private extension ChatViewController {
    var chromeThemeID: ThemeID {
        root?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
    }
}

/// A view inset 16pt from the chat's safe edges, as the footer rows are.
private func footerInset(_ view: UIView, top: CGFloat = 0) -> UIView {
    let box = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: box.topAnchor, constant: top),
        view.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
        view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
    ])
    return box
}

// MARK: - Above the composer

/// The rows above the composer: the extension strip with the review-comment
/// and now-playing pills and the notification chip, their drawers, the
/// reconnect failure, and session warnings. Each row is 8pt from the next,
/// and from the composer.
final class ChatFooterAboveView: UIView {
    weak var chat: ChatViewController?
    /// The now-playing pill stays SwiftUI for now (its session-list sibling is
    /// converting separately); the chat adds this host as its child.
    let nowPlayingPill: HostedContentController

    private let stack = UIStackView()
    private let panel = ExtensionSurfacePanelView(placement: .aboveEditor)
    private let reviewPill = ReviewCommentStripPillView()
    private let notifyChip = ExtensionNotifyChipView()
    private let reviewDrawer = ReviewCommentStashDrawerView()
    private let nowPlayingDrawer = ChatNowPlayingDrawerView()
    private let notifyDrawer = ExtensionNotifyDrawerView()
    private let notices = UIStackView()
    private lazy var panelRow = footerInset(panel)
    private lazy var reviewDrawerRow = footerInset(reviewDrawer)
    private lazy var nowPlayingDrawerRow = footerInset(nowPlayingDrawer)
    private lazy var notifyDrawerRow = footerInset(notifyDrawer)

    init(chat: ChatViewController, nowPlayingPill: HostedContentController) {
        self.chat = chat
        self.nowPlayingPill = nowPlayingPill
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        notices.axis = .vertical
        notices.spacing = 8
        for row in [panelRow, reviewDrawerRow, nowPlayingDrawerRow, notifyDrawerRow, notices] {
            stack.addArrangedSubview(row)
        }

        panel.onExpandedEntryChange = { [weak chat] in chat?.handleExtensionDrawerExpansion($0) }
        reviewPill.onToggle = { [weak chat] in chat?.toggleReviewCommentDrawer() }
        reviewPill.onOpenFullScreen = { [weak chat] in chat?.presentReviewCommentStashSheet() }
        reviewDrawer.onEdit = { [weak chat] in chat?.presentReviewCommentStashSheet(editing: $0) }
        reviewDrawer.onDelete = { [weak chat] in chat?.deleteReviewComment($0) }
        notifyChip.onToggleExpanded = { [weak self] in
            self?.animated { self?.chat?.toggleNotifyChip() }
        }
        notifyDrawer.onCollapse = { [weak self] in
            self?.animated { self?.chat?.collapseNotifyChip() }
        }
        notifyDrawer.onDismiss = { [weak chat] in
            guard let chat else { return }
            chat.connection.extensionNotifyChipStore.dismiss(sessionId: chat.sessionId)
        }
        notifyDrawer.onOpenURL = { [weak chat] in chat?.openExtensionSurfaceURL($0) ?? false }
        nowPlayingDrawer.onOpen = { [weak chat] in
            guard let chat else { return }
            chat.openTimelineReader(.nowPlaying(chat.audioPlayer))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func animated(_ change: () -> Void) {
        change()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(withDuration: 0.10, delay: 0, options: .curveEaseOut) {
            self.updatePropertiesIfNeeded()
            self.window?.layoutIfNeeded()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        guard let chat, !chat.isStopped else {
            setHiddenIfChanged(true)
            return
        }
        let themeID = chat.chromeThemeID
        let palette = themeID.palette
        let surface = chat.extensionSurfaceState
        let showsReviewPill = chat.showsReviewCommentPill
        let showsNowPlayingPill = chat.showsNowPlayingPill
        let showsMessageQueue = chat.showsMessageQueue
        let notifyState = chat.notifyChipState
        let showsStrip = !chat.hasBlockingExtensionInput && ReviewCommentStripChrome.shouldShowAboveEditorStrip(
            showsReviewCommentPill: showsReviewPill,
            showsNowPlayingPill: showsNowPlayingPill,
            hasAboveEditorSurface: surface.hasVisibleContent(in: .aboveEditor),
            showsMessageQueue: showsMessageQueue,
            showsNotifyChip: notifyState != nil
        )
        let reconnectFailure = chat.actionHandler.reconnectFailureMessage
        let warnings = ChatSessionWarningChrome.messages(from: chat.session?.warnings)

        panelRow.setHiddenIfChanged(!showsStrip)
        if showsStrip {
            var leading: [UIView] = []
            if showsReviewPill {
                reviewPill.apply(
                    count: chat.reviewComments.stagedCount,
                    isExpanded: chat.model.reviewCommentDrawerExpanded,
                    palette: palette
                )
                leading.append(reviewPill)
            }
            if showsNowPlayingPill {
                chat.updateNowPlayingPill(nowPlayingPill)
                leading.append(nowPlayingPill.view)
            }
            var trailing: [UIView] = []
            if let notifyState {
                notifyChip.apply(notifyState, palette: palette)
                trailing.append(notifyChip)
            }
            panel.actions = ExtensionSurfaceDrawerActions(
                linkContext: chat.extensionSurfaceLinkContext,
                onOpenURL: { [weak chat] in chat?.openExtensionSurfaceURL($0) ?? false },
                openReader: { [weak chat] in chat?.openTimelineReader($0) },
                liveSurface: Self.liveSurfaceLookup(chat)
            )
            panel.setStripAccessories(leading: leading, trailing: trailing)
            panel.apply(ExtensionSurfacePanelView.Content(
                surface: surface,
                messageQueue: showsMessageQueue ? chat.messageQueueSurfaceConfiguration : nil,
                themeID: themeID,
                collapseRequestID: chat.model.extensionDrawerCollapseRequestID
            ))
        }

        let showsReviewDrawer = showsStrip && showsReviewPill && chat.model.reviewCommentDrawerExpanded
        reviewDrawerRow.setHiddenIfChanged(!showsReviewDrawer)
        if showsReviewDrawer {
            reviewDrawer.apply(comments: chat.reviewComments.stagedComments, themeID: themeID)
        }
        let showsNowPlayingDrawer = showsStrip && showsNowPlayingPill && chat.model.nowPlayingDrawerExpanded
        nowPlayingDrawerRow.setHiddenIfChanged(!showsNowPlayingDrawer)
        if showsNowPlayingDrawer {
            nowPlayingDrawer.apply(audioPlayer: chat.audioPlayer, palette: palette)
        }
        let showsNotifyDrawer = showsStrip && notifyState?.isExpanded == true
        notifyDrawerRow.setHiddenIfChanged(!showsNotifyDrawer)
        if showsNotifyDrawer, let notifyState {
            notifyDrawer.apply(notifyState, themeID: themeID)
        }

        let messages: [(String, UIColor)] = (reconnectFailure.map { [($0, UIColor(palette.red))] } ?? [])
            + warnings.map { ($0, UIColor(palette.yellow)) }
        for view in notices.arrangedSubviews { view.removeFromSuperview() }
        for (text, color) in messages {
            notices.addArrangedSubview(ChatFooterNoticeView(text: text, color: color, palette: palette))
        }
        notices.setHiddenIfChanged(messages.isEmpty)
        setHiddenIfChanged(!showsStrip && messages.isEmpty)
    }

    /// Looks a native surface up by protocol id each time the reader renders,
    /// so a reader opened from the drawer follows the same updates.
    private static func liveSurfaceLookup(_ chat: ChatViewController) -> (String) -> ExtensionUINativeSurface? {
        let sessionId = chat.sessionId
        let connection = chat.connection
        return { [weak connection] id in
            connection?.extensionSurfaces.surface(for: sessionId).layout.nativeSurfaces[id]?.surface
        }
    }
}

/// A reconnect failure or session warning above the composer.
private final class ChatFooterNoticeView: UIView {
    init(text: String, color: UIColor, palette: ThemePalette) {
        super.init(frame: .zero)
        let card = UIView()
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = color.withAlphaComponent(0.35).cgColor
        card.clipsToBounds = true
        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.contentView.backgroundColor = color.withAlphaComponent(0.08)
        let icon = UIImageView(image: ExtensionChromeFont.symbol(
            "exclamationmark.triangle.fill", .caption1, .regular, color: color
        ))
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = ExtensionChromeFont.label(.caption1, lines: 0)
        label.text = text
        label.textColor = UIColor(palette.fg)
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 8
        for view in [glass, row] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        let content = footerInset(card)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: card.topAnchor),
            glass.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            icon.topAnchor.constraint(equalTo: label.topAnchor, constant: 1),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// The expanded now-playing drawer: the track, its current lyric (double tap
/// opens the full-screen player), and the transport.
final class ChatNowPlayingDrawerView: ExtensionDrawerPanelView {
    var onOpen: (() -> Void)?
    private let header = UIControl()
    private let titleLabel = ExtensionChromeFont.label(.caption1, .semibold)
    private let lyricLabel = UILabel()
    private let loading = UIStackView()
    private let loadingSpinner = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = ExtensionChromeFont.label(.callout)
    private let transport = AudioPlaybackTransportView(density: .drawer, accessibilityPrefix: "chat.nowPlaying.drawer")

    init() {
        super.init(spacing: 12)
        accessibilityIdentifier = "chat.nowPlaying.drawer"
        titleLabel.lineBreakMode = .byTruncatingMiddle
        lyricLabel.numberOfLines = 0
        lyricLabel.adjustsFontForContentSizeCategory = true
        loadingSpinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        loadingSpinner.startAnimating()
        loadingLabel.text = "Loading lyrics…"
        loading.addArrangedSubview(loadingSpinner)
        loading.addArrangedSubview(loadingLabel)
        loading.axis = .horizontal
        loading.spacing = 6
        loading.alignment = .center

        let titles = UIStackView(arrangedSubviews: [titleLabel, lyricLabel, loading])
        titles.axis = .vertical
        titles.alignment = .leading
        titles.spacing = 3
        titles.isUserInteractionEnabled = false
        titles.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titles)
        header.isAccessibilityElement = true
        header.accessibilityHint = "Double tap to open the full-screen audio player"
        header.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Open Full Screen") { [weak self] _ in
                self?.onOpen?()
                return true
            },
        ]
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(open))
        doubleTap.numberOfTapsRequired = 2
        header.addGestureRecognizer(doubleTap)
        NSLayoutConstraint.activate([
            titles.topAnchor.constraint(greaterThanOrEqualTo: header.topAnchor),
            titles.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titles.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(transport)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func open() { onOpen?() }

    /// Reads the player's observable state: call from `updateProperties()`.
    func apply(audioPlayer: AudioPlayerService, palette: ThemePalette) {
        surface.apply(palette: palette)
        let title = audioPlayer.nowPlayingPresentation?.title ?? "Now Playing"
        titleLabel.text = title
        titleLabel.textColor = UIColor(palette.comment)
        loadingLabel.textColor = UIColor(palette.comment)
        let presentation = InAppNowPlayingChrome.subtitlePresentation(
            in: audioPlayer.nowPlayingTimedText,
            at: audioPlayer.currentTime,
            isLoading: audioPlayer.isNowPlayingTimedTextLoading
        )
        loading.isHidden = presentation != .loading
        lyricLabel.isHidden = presentation == .loading
        lyricLabel.accessibilityLabel = nil
        switch presentation {
        case .cue(let text):
            lyricLabel.text = text
            lyricLabel.font = ExtensionChromeFont.text(.body, .medium)
            lyricLabel.textColor = UIColor(palette.fg)
        case .gap:
            lyricLabel.text = "…"
            lyricLabel.font = ExtensionChromeFont.text(.body, .medium)
            lyricLabel.textColor = UIColor(palette.comment)
            lyricLabel.accessibilityLabel = "No lyric at the current position"
        case .unavailable:
            lyricLabel.text = "No lyrics"
            lyricLabel.font = ExtensionChromeFont.text(.callout)
            lyricLabel.textColor = UIColor(palette.comment)
        case .loading:
            break
        }
        header.accessibilityLabel = [title, lyricLabel.isHidden ? loadingLabel.text : (lyricLabel.accessibilityLabel ?? lyricLabel.text)]
            .compactMap(\.self)
            .joined(separator: ", ")
        transport.apply(.init(
            itemID: audioPlayer.playingItemID ?? audioPlayer.loadingItemID ?? "",
            audioPlayer: audioPlayer,
            play: { [weak audioPlayer] in
                if audioPlayer?.isPaused == true { audioPlayer?.resume() }
            },
            openFile: nil
        ))
    }
}

// MARK: - Below the composer

/// The extension panel below the composer, 8pt under it.
final class ChatFooterBelowView: UIView {
    weak var chat: ChatViewController?
    private let panel = ExtensionSurfacePanelView(placement: .belowEditor)

    init(chat: ChatViewController) {
        self.chat = chat
        super.init(frame: .zero)
        let row = footerInset(panel, top: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        panel.onExpandedEntryChange = { [weak chat] in chat?.handleExtensionDrawerExpansion($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateProperties() {
        super.updateProperties()
        guard let chat, !chat.isStopped, !chat.hasBlockingExtensionInput,
              chat.extensionSurfaceState.hasVisibleContent(in: .belowEditor) else {
            setHiddenIfChanged(true)
            return
        }
        setHiddenIfChanged(false)
        panel.actions = ExtensionSurfaceDrawerActions(
            linkContext: chat.extensionSurfaceLinkContext,
            onOpenURL: { [weak chat] in chat?.openExtensionSurfaceURL($0) ?? false },
            openReader: { [weak chat] in chat?.openTimelineReader($0) },
            liveSurface: nil
        )
        panel.apply(ExtensionSurfacePanelView.Content(
            surface: chat.extensionSurfaceState,
            messageQueue: nil,
            themeID: chat.chromeThemeID,
            collapseRequestID: chat.model.extensionDrawerCollapseRequestID
        ))
    }
}

// MARK: - Stopped session

/// A stopped session's footer, in place of the composer: a rule, "Session
/// ended" with its token and cost totals, and Resume Session.
final class ChatStoppedFooterView: UIView {
    weak var chat: ChatViewController?
    private let rule = UIView()
    private let icon = UIImageView()
    private let endedLabel = ExtensionChromeFont.label(.subheadline)
    private let tokensLabel = UILabel()
    private let costLabel = UILabel()
    private let resumeButton = UIButton(type: .custom)

    init(chat: ChatViewController) {
        self.chat = chat
        super.init(frame: .zero)
        endedLabel.text = "Session ended"
        for label in [tokensLabel, costLabel] {
            let base = UIFont.preferredFont(
                forTextStyle: .caption1,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
            )
            label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                for: .monospacedDigitSystemFont(ofSize: base.pointSize, weight: .regular)
            )
            label.adjustsFontForContentSizeCategory = true
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let summary = UIStackView(arrangedSubviews: [icon, endedLabel, spacer, tokensLabel, costLabel])
        summary.axis = .horizontal
        summary.alignment = .center
        summary.spacing = 8
        summary.isLayoutMarginsRelativeArrangement = true
        summary.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

        resumeButton.layer.cornerRadius = 10
        resumeButton.clipsToBounds = true
        resumeButton.addAction(UIAction { [weak chat] _ in chat?.resumeSession() }, for: .touchUpInside)
        let resumeRow = footerInset(resumeButton)

        let stack = UIStackView(arrangedSubviews: [rule, summary, resumeRow])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            rule.heightAnchor.constraint(equalToConstant: 1 / max(1, UIScreen.main.scale)),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateProperties() {
        super.updateProperties()
        guard let chat, chat.isStopped else {
            setHiddenIfChanged(true)
            return
        }
        setHiddenIfChanged(false)
        let palette = chat.chromeThemeID.palette
        let comment = UIColor(palette.comment)
        rule.backgroundColor = comment.withAlphaComponent(0.3)
        icon.image = ExtensionChromeFont.symbol("checkmark.circle", .subheadline, .regular, color: comment)
        endedLabel.textColor = comment
        tokensLabel.textColor = comment
        costLabel.textColor = comment
        let session = chat.session
        let totalTokens = session.map { $0.tokens.input + $0.tokens.output } ?? 0
        tokensLabel.text = SessionFormatting.tokenCount(totalTokens) + " tokens"
        tokensLabel.isHidden = totalTokens <= 0
        costLabel.text = session.map { SessionFormatting.costString($0.cost) }
        costLabel.isHidden = (session?.cost ?? 0) <= 0

        let isResuming = chat.actionHandler.isResuming
        let onGreen = UIColor(ThemeColorContrast.foreground(for: palette.green))
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = UIColor(palette.green)
        configuration.baseForegroundColor = onGreen
        configuration.background.cornerRadius = 10
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
        var title = AttributedString(isResuming ? "Resuming…" : "Resume Session")
        title.font = ExtensionChromeFont.text(.subheadline, .medium)
        configuration.attributedTitle = title
        configuration.imagePadding = 6
        configuration.showsActivityIndicator = isResuming
        configuration.activityIndicatorColorTransformer = UIConfigurationColorTransformer { _ in onGreen }
        configuration.image = isResuming ? nil : UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline)
        )
        resumeButton.configuration = configuration
        resumeButton.isEnabled = !isResuming
    }
}

// MARK: - Jump to bottom

/// The jump-to-bottom hint in its 44pt slot at the timeline's bottom trailing
/// corner: a plain arrow, or while the agent works a spinner in the model's
/// color with an arrow badge. It scales and fades in and out.
final class ChatJumpToBottomView: UIView {
    weak var chat: ChatViewController?
    private let button = UIControl()
    private let idleGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let idleArrow = UIImageView()
    private let busyGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let busyRing = CAShapeLayer()
    private let spinner = ChatJumpSpinnerView()
    private let badge = UIImageView()
    private var shownVisible: Bool?
    private var shownBusy: Bool?

    init(chat: ChatViewController) {
        self.chat = chat
        super.init(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityIdentifier = "chat.jumpToBottom"
        button.addAction(UIAction { [weak chat] _ in chat?.scrollController.requestScrollToBottom() }, for: .touchUpInside)
        addSubview(button)
        idleGlass.layer.cornerRadius = 17
        idleGlass.clipsToBounds = true
        idleArrow.contentMode = .center
        busyGlass.layer.cornerRadius = 18
        busyGlass.clipsToBounds = true
        busyRing.fillColor = UIColor.clear.cgColor
        busyRing.lineWidth = 1.5
        badge.contentMode = .center
        badge.layer.cornerRadius = 7
        badge.clipsToBounds = true
        for view in [idleGlass, idleArrow, busyGlass, spinner, badge] as [UIView] {
            view.isUserInteractionEnabled = false
            view.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(view)
        }
        busyGlass.layer.addSublayer(busyRing)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36),
            idleGlass.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            idleGlass.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            idleGlass.widthAnchor.constraint(equalToConstant: 34),
            idleGlass.heightAnchor.constraint(equalToConstant: 34),
            idleArrow.centerXAnchor.constraint(equalTo: idleGlass.centerXAnchor),
            idleArrow.centerYAnchor.constraint(equalTo: idleGlass.centerYAnchor),
            busyGlass.topAnchor.constraint(equalTo: button.topAnchor),
            busyGlass.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            busyGlass.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            busyGlass.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 20),
            spinner.heightAnchor.constraint(equalToConstant: 20),
            badge.widthAnchor.constraint(equalToConstant: 14),
            badge.heightAnchor.constraint(equalToConstant: 14),
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 2),
            badge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: 2),
        ])
        button.alpha = 0
        button.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        busyRing.path = UIBezierPath(ovalIn: busyGlass.bounds.insetBy(dx: 0.75, dy: 0.75)).cgPath
        busyRing.frame = busyGlass.bounds
    }

    override func updateProperties() {
        super.updateProperties()
        guard let chat else { return }
        let visible = chat.scrollController.isJumpToBottomHintVisible
        let busy = chat.isBusy
        let palette = chat.chromeThemeID.palette
        let provider = UIColor(ProviderColor.color(for: chat.session?.model, palette: palette))
        idleArrow.image = ExtensionChromeFont.symbol("arrow.down", .caption1, .bold, color: UIColor(palette.fg))
        badge.backgroundColor = provider
        badge.image = UIImage(
            systemName: "arrow.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .black)
        )?.withTintColor(
            UIColor(ThemeColorContrast.foreground(for: ProviderColor.color(for: chat.session?.model, palette: palette))),
            renderingMode: .alwaysOriginal
        )
        busyRing.strokeColor = provider.cgColor
        spinner.apply(tint: provider, palette: palette)
        button.accessibilityLabel = busy ? "Agent working, jump to bottom" : "Jump to latest message"
        setBusy(busy, animated: shownBusy != nil)
        setVisible(visible, animated: shownVisible != nil)
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    private func setBusy(_ busy: Bool, animated: Bool) {
        guard busy != shownBusy else { return }
        shownBusy = busy
        let apply = {
            for view in [self.busyGlass, self.spinner, self.badge] as [UIView] {
                view.alpha = busy ? 1 : 0
                view.transform = busy || self.reduceMotion ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
            }
            for view in [self.idleGlass, self.idleArrow] as [UIView] {
                view.alpha = busy ? 0 : 1
                view.transform = !busy || self.reduceMotion ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
            }
        }
        if animated, !reduceMotion {
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut, animations: apply)
        } else {
            apply()
        }
        spinner.isAnimating = busy
        if busy, !reduceMotion {
            let pulse = CABasicAnimation(keyPath: "strokeColor")
            pulse.fromValue = busyRing.strokeColor.map { UIColor(cgColor: $0).withAlphaComponent(0.15).cgColor }
            pulse.toValue = busyRing.strokeColor.map { UIColor(cgColor: $0).withAlphaComponent(0.45).cgColor }
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            busyRing.add(pulse, forKey: "pulse")
        } else {
            busyRing.removeAnimation(forKey: "pulse")
            busyRing.strokeColor = busyRing.strokeColor.map { UIColor(cgColor: $0).withAlphaComponent(0.15).cgColor }
        }
    }

    /// The slot stays laid out so the button can animate; it takes touches
    /// only while the button shows.
    private func setVisible(_ visible: Bool, animated: Bool) {
        isUserInteractionEnabled = visible
        guard visible != shownVisible else { return }
        shownVisible = visible
        let hiddenTransform = reduceMotion ? CGAffineTransform.identity : Self.scale(0.96, anchoredAt: button)
        if visible { button.isHidden = false }
        let change = {
            self.button.alpha = visible ? 1 : 0
            self.button.transform = visible ? .identity : hiddenTransform
        }
        let finish: (Bool) -> Void = { _ in
            if self.shownVisible == false { self.button.isHidden = true }
        }
        if animated {
            UIView.animate(
                withDuration: reduceMotion ? 0 : 0.18,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: change,
                completion: finish
            )
        } else {
            change()
            finish(true)
        }
    }

    /// A scale toward the button's bottom trailing corner.
    private static func scale(_ factor: CGFloat, anchoredAt view: UIView) -> CGAffineTransform {
        let size = CGSize(width: 36, height: 36)
        let dx = size.width / 2 * (1 - factor)
        let dy = size.height / 2 * (1 - factor)
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: factor, y: factor)
    }
}

/// The working spinner in the jump hint, in the style chosen in Settings:
/// Metal orbs, braille dots, or Game of Life.
private final class ChatJumpSpinnerView: UIView {
    private let braille = BrailleSpinnerUIView()
    private let life = GameOfLifeUIView(gridSize: 6)
    private let orb = OrbMetalView(style: .working, sizeClass: .workingCompact)
    var isAnimating = false {
        didSet { orb.isAnimationEnabled = isAnimating && !orb.isHidden }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [braille, life, orb] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(tint: UIColor, palette: ThemePalette) {
        let style = SpinnerStyle.current
        braille.isHidden = style != .brailleDots
        life.isHidden = style != .gameOfLife
        orb.isHidden = style.orbStyle == nil
        braille.tintUIColor = tint
        life.tintUIColor = tint
        orb.tintUIColor = tint
        orb.accentUIColors = [palette.blue, palette.cyan, palette.purple, palette.orange].map { UIColor($0) }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(palette.bg).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        orb.isDarkBackground = OrbTint.isDarkBackground(red: red, green: green, blue: blue)
        if let orbStyle = style.orbStyle { orb.style = orbStyle }
        orb.isAnimationEnabled = isAnimating && !orb.isHidden
    }
}

// MARK: - Title

/// The session title in the bar: the assistant's avatar, the session name,
/// its cost, the pi-tui mirror and Durable marks, and in the Conversation
/// layout the model and thinking level under it. `ChatTitleControl` owns
/// the tap, the menu, and accessibility.
final class ChatTitleView: UIView {
    weak var chat: ChatViewController?
    private let avatar = UIImageView()
    private let emoji = UILabel()
    private let avatarSlot = UIView()
    private let nameLabel = ExtensionChromeFont.label(.subheadline, .semibold)
    private let costLabel = UILabel()
    private let mirror = TerminalMirrorGlyphView()
    private let durableLabel = ExtensionChromeFont.label(.caption2, .semibold)
    private let subtitleLabel = ExtensionChromeFont.label(.caption2)
    private var avatarSize: [NSLayoutConstraint] = []
    private var maxWidth: NSLayoutConstraint?
    private var genmojiTask: Task<Void, Never>?
    private var genmojiAssetID: String?
    nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?

    init(chat: ChatViewController) {
        self.chat = chat
        super.init(frame: .zero)
        clipsToBounds = true
        isUserInteractionEnabled = false
        avatar.contentMode = .scaleAspectFit
        emoji.textAlignment = .center
        for view in [avatar, emoji] {
            view.translatesAutoresizingMaskIntoConstraints = false
            avatarSlot.addSubview(view)
        }
        avatarSlot.clipsToBounds = true
        avatarSlot.layer.cornerCurve = .continuous
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let base = UIFont.preferredFont(
            forTextStyle: .caption2,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        costLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: base.pointSize, weight: .regular)
        )
        costLabel.adjustsFontForContentSizeCategory = true
        durableLabel.text = "Durable"
        durableLabel.accessibilityIdentifier = "chat.title.durable"
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.accessibilityIdentifier = "chat.title.subtitle"
        for label in [costLabel, durableLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        let row = UIStackView(arrangedSubviews: [avatarSlot, nameLabel, costLabel, mirror, durableLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        let column = UIStackView(arrangedSubviews: [row, subtitleLabel])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let maxWidth = widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        self.maxWidth = maxWidth
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            avatar.centerXAnchor.constraint(equalTo: avatarSlot.centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: avatarSlot.centerYAnchor),
            emoji.centerXAnchor.constraint(equalTo: avatarSlot.centerXAnchor),
            emoji.centerYAnchor.constraint(equalTo: avatarSlot.centerYAnchor),
            maxWidth,
        ])
        // The Durable mark follows the experiment switch in Settings. Defaults
        // post from any thread; the title updates on main.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsUpdateProperties() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        genmojiTask?.cancel()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    override func updateProperties() {
        super.updateProperties()
        guard let chat else { return }
        let session = chat.session
        let palette = chat.chromeThemeID.palette
        maxWidth?.constant = chat.model.titleMaxWidth
        nameLabel.text = chat.sessionDisplayName
        nameLabel.textColor = UIColor(palette.fg)
        if let cost = session?.cost, cost > 0 {
            costLabel.text = SessionFormatting.costString(cost)
            costLabel.isHidden = false
        } else {
            costLabel.isHidden = true
        }
        costLabel.textColor = UIColor(palette.comment)
        let mirrorPresentation = TerminalMirrorIndicatorPresentation(session: session)
        mirror.isHidden = mirrorPresentation == nil
        if let mirrorPresentation { mirror.apply(mirrorPresentation) }
        durableLabel.isHidden = !(session?.engine == .durable && AppPreferences.Experiments.durableSessionsEnabled)
        durableLabel.textColor = UIColor(palette.comment)
        let subtitle = chat.conversationTitleSubtitle
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle == nil
        subtitleLabel.textColor = UIColor(palette.comment)
        applyAvatar(chat: chat, palette: palette)
    }

    private func setAvatarSize(_ side: CGFloat, imageSide: CGFloat) {
        NSLayoutConstraint.deactivate(avatarSize)
        avatarSize = [
            avatarSlot.widthAnchor.constraint(equalToConstant: side),
            avatarSlot.heightAnchor.constraint(equalToConstant: side),
            avatar.widthAnchor.constraint(equalToConstant: imageSide),
            avatar.heightAnchor.constraint(equalToConstant: imageSide),
        ]
        NSLayoutConstraint.activate(avatarSize)
    }

    private func applyAvatar(chat: ChatViewController, palette: ThemePalette) {
        switch chat.assistantIdentityPresentation {
        case .globalAvatar:
            setAvatarSize(20, imageSide: 20)
            avatarSlot.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.10)
            avatarSlot.layer.cornerRadius = 20 * 0.32
            avatar.image = PiAvatarRenderer.render(size: 40, themeID: chat.chromeThemeID)
            avatar.isHidden = false
            emoji.isHidden = true
            cancelGenmoji()
        case .agent(let content):
            let envelope = AgentIconSizingPolicy.titleVisualEnvelope
            setAvatarSize(AgentIconSizingPolicy.titleSlotSize, imageSide: envelope)
            avatarSlot.backgroundColor = .clear
            avatarSlot.layer.cornerRadius = 0
            let blue = UIColor(palette.blue)
            switch content {
            case .symbol(let name):
                avatar.image = UIImage(
                    systemName: name,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: envelope, weight: .medium)
                )?.withTintColor(blue, renderingMode: .alwaysOriginal)
                showImage()
            case .text(let text):
                let size = AgentIconSizingPolicy.titleTextSize(
                    for: UIFontMetrics(forTextStyle: .body).scaledValue(for: AgentIconSizingPolicy.titleTextMinimum)
                )
                emoji.font = .systemFont(ofSize: size)
                emoji.text = text
                avatar.isHidden = true
                emoji.isHidden = false
                cancelGenmoji()
            case .genmoji(let assetId, _):
                loadGenmoji(assetId: assetId, chat: chat, fallback: blue)
            case .fallback:
                avatar.image = UIImage(
                    systemName: IconChoiceRenderPurpose.agent.defaultSymbolName,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: envelope, weight: .medium)
                )?.withTintColor(blue, renderingMode: .alwaysOriginal)
                showImage()
            }
        }
    }

    private func showImage() {
        avatar.isHidden = false
        emoji.isHidden = true
        cancelGenmoji()
    }

    private func cancelGenmoji() {
        genmojiTask?.cancel()
        genmojiTask = nil
        genmojiAssetID = nil
    }

    private func loadGenmoji(assetId: String, chat: ChatViewController, fallback: UIColor) {
        avatar.isHidden = false
        emoji.isHidden = true
        guard genmojiAssetID != assetId else { return }
        genmojiTask?.cancel()
        genmojiAssetID = assetId
        avatar.image = UIImage(
            systemName: IconChoiceRenderPurpose.agent.defaultSymbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: AgentIconSizingPolicy.titleVisualEnvelope, weight: .medium)
        )?.withTintColor(fallback, renderingMode: .alwaysOriginal)
        guard let cache = chat.connection.iconAssetCache else { return }
        genmojiTask = Task { [weak self] in
            let image = try? await cache.image(assetId: assetId, size: AgentIconSizingPolicy.titleVisualEnvelope * 2)
            guard let self, !Task.isCancelled, self.genmojiAssetID == assetId, let image else { return }
            self.avatar.image = image
        }
    }
}

/// The pi-tui mirror mark: a terminal glyph, green and breathing while the
/// mirror is connected, gray while it is offline.
private final class TerminalMirrorGlyphView: UIImageView {
    private var breathing = false

    init() {
        super.init(frame: .zero)
        contentMode = .right
        isAccessibilityElement = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ presentation: TerminalMirrorIndicatorPresentation) {
        image = ExtensionChromeFont.symbol("terminal.fill", .caption2, .semibold, color: UIColor(presentation.color))
        accessibilityLabel = presentation.accessibilityLabel
        let animates = presentation.isAnimated && !UIAccessibility.isReduceMotionEnabled
        guard animates != breathing || layer.animation(forKey: "breathing") == nil else { return }
        breathing = animates
        layer.removeAnimation(forKey: "breathing")
        if animates {
            alpha = 0.90
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.90
            pulse.toValue = 0.98
            pulse.duration = 2.4
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "breathing")
        } else {
            alpha = 0.88
        }
    }
}
