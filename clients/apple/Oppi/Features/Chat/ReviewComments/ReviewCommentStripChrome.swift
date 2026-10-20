import UIKit

enum ReviewCommentStripChrome {
    static let pillAccessibilityIdentifier = "chat.reviewComments.pill"
    static let drawerAccessibilityIdentifier = "chat.reviewComments.drawer"

    struct ExpansionState: Equatable {
        var commentsExpanded: Bool
        var nowPlayingExpanded: Bool
    }

    static func stashTitle(count: Int) -> String {
        "\(count) review \(count == 1 ? "comment" : "comments") staged"
    }

    static func pillAccessibilityLabel(count: Int) -> String {
        stashTitle(count: count)
    }

    static func pillAccessibilityValue(count: Int) -> String {
        stashTitle(count: count)
    }

    static func pillCountText(count: Int) -> String {
        "\(count) \(count == 1 ? "comment" : "comments")"
    }

    enum PillAction: Equatable {
        case peek
        case sheet
    }

    /// Chat and control-session pills: tap peeks the drawer, double-tap opens the stash sheet.
    static func pillAction(tapCount: Int) -> PillAction? {
        switch tapCount {
        case 1: return .peek
        case 2: return .sheet
        default: return nil
        }
    }

    /// Fresh identity per present so list vs already-editing cannot reuse `@State`.
    struct StashPresentation: Identifiable, Equatable {
        let id: UUID
        let initialEditingComment: ReviewComment?

        init(editing comment: ReviewComment? = nil) {
            id = UUID()
            initialEditingComment = comment
        }
    }

    static func shouldShowPill(stagedCount: Int, isDraftingComment: Bool) -> Bool {
        stagedCount > 0 && !isDraftingComment
    }

    static func shouldShowAboveEditorStrip(
        showsReviewCommentPill: Bool,
        showsNowPlayingPill: Bool,
        hasAboveEditorSurface: Bool,
        showsMessageQueue: Bool,
        showsNotifyChip: Bool
    ) -> Bool {
        showsReviewCommentPill
            || showsNowPlayingPill
            || hasAboveEditorSurface
            || showsMessageQueue
            || showsNotifyChip
    }

    static func toggleComments(_ state: ExpansionState) -> ExpansionState {
        let commentsExpanded = !state.commentsExpanded
        return ExpansionState(
            commentsExpanded: commentsExpanded,
            nowPlayingExpanded: commentsExpanded ? false : state.nowPlayingExpanded
        )
    }

    static func toggleNowPlaying(_ state: ExpansionState) -> ExpansionState {
        let nowPlayingExpanded = !state.nowPlayingExpanded
        return ExpansionState(
            commentsExpanded: nowPlayingExpanded ? false : state.commentsExpanded,
            nowPlayingExpanded: nowPlayingExpanded
        )
    }
}

/// The staged-comment pill on the strip: its count over the strip-pill
/// surface. A tap peeks the drawer, a double tap opens the stash sheet. One
/// accessibility element, activated like the tap, with Open Full Screen as a
/// custom action. Touches land across a 44pt band.
final class ReviewCommentStripPillView: ExtensionStripPillControl {
    var onToggle: (() -> Void)?
    var onOpenFullScreen: (() -> Void)?
    private let icon = UIImageView()
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.spacing = 8
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
        countLabel.font = ExtensionChromeFont.monospacedDigits(.subheadline, .semibold)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(countLabel)
        accessibilityIdentifier = ReviewCommentStripChrome.pillAccessibilityIdentifier

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(singleTap)
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Open Full Screen") { [weak self] _ in
                self?.onOpenFullScreen?()
                return true
            },
        ]
    }

    func apply(count: Int, isExpanded: Bool, palette: ThemePalette) {
        icon.image = ExtensionChromeFont.symbol("text.bubble", .subheadline, .semibold, color: UIColor(palette.cyan))
        countLabel.text = ReviewCommentStripChrome.pillCountText(count: count)
        countLabel.textColor = UIColor(palette.fg)
        surface.apply(palette: palette, active: isExpanded ? UIColor(palette.cyan) : nil)
        accessibilityLabel = ReviewCommentStripChrome.pillAccessibilityLabel(count: count)
        accessibilityValue = ReviewCommentStripChrome.pillAccessibilityValue(count: count)
        accessibilityHint = isExpanded
            ? "Collapses the staged review comments"
            : "Shows the review comments staged for the next message"
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let band = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: 0, dy: -band).contains(point)
    }

    override func accessibilityActivate() -> Bool {
        handleTaps(1)
        return true
    }

    @objc private func handleSingleTap() { handleTaps(1) }
    @objc private func handleDoubleTap() { handleTaps(2) }

    private func handleTaps(_ count: Int) {
        switch ReviewCommentStripChrome.pillAction(tapCount: count) {
        case .peek: onToggle?()
        case .sheet: onOpenFullScreen?()
        case nil: break
        }
    }
}

/// The staged comments under the strip: their count, then the rows in a
/// viewport capped like an extension drawer's. Edit opens the stash sheet on
/// that comment.
final class ReviewCommentStashDrawerView: ExtensionDrawerPanelView {
    var onEdit: ((ReviewComment) -> Void)? {
        get { list.onRequestEdit }
        set { list.onRequestEdit = newValue }
    }
    var onDelete: ((ReviewComment) -> Void)? {
        get { list.onDelete }
        set { list.onDelete = newValue }
    }
    private let titleLabel = ExtensionChromeFont.label(.caption1, .semibold)
    private let list = ReviewCommentStashListView(chrome: .drawer)

    init() {
        super.init(spacing: 10)
        let viewport = CappedScrollView(content: list, maxHeight: ExtensionNativeSurfaceLayout.expandedMaxHeight)
        viewport.scrollView.accessibilityIdentifier = ReviewCommentStripChrome.drawerAccessibilityIdentifier
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(viewport)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(comments: [ReviewComment], themeID: ThemeID) {
        let palette = themeID.palette
        surface.apply(palette: palette)
        titleLabel.text = ReviewCommentStripChrome.stashTitle(count: comments.count)
        titleLabel.textColor = UIColor(palette.comment)
        list.apply(comments: comments, themeID: themeID)
    }
}
