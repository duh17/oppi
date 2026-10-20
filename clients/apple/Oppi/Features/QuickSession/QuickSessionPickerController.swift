import UIKit

/// One choice in a Quick Session picker.
struct QuickSessionPickerRow: Equatable {
    var id: String
    var icon: QuickSessionIconView.Content
    var iconAssetCache: IconAssetCache?
    var title: String
    var subtitle: String?
    var isSelected: Bool
    var accessibilityIdentifier: String
    var accessibilityLabel: String
    var accessibilityValue: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.icon == rhs.icon
            && lhs.iconAssetCache === rhs.iconAssetCache
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.isSelected == rhs.isSelected
            && lhs.accessibilityIdentifier == rhs.accessibilityIdentifier
            && lhs.accessibilityLabel == rhs.accessibilityLabel
            && lhs.accessibilityValue == rhs.accessibilityValue
    }
}

/// A line below a section's rows: its list still loading, or why it is empty.
enum QuickSessionPickerNote: Equatable {
    case loading(String)
    case message(String)
}

/// Rows under an optional header (a server, when there is more than one).
struct QuickSessionPickerSection: Equatable {
    var title: String?
    var rows: [QuickSessionPickerRow]
    var note: QuickSessionPickerNote?
}

enum QuickSessionPickerContent: Equatable {
    case loading(String)
    case empty(title: String, systemImage: String, message: String)
    case sections([QuickSessionPickerSection])
}

/// The look of one picker: its popover's width and height cap and its rows.
struct QuickSessionPickerStyle {
    var width: CGFloat
    var maxHeight: CGFloat
    var iconSize: CGFloat
    var iconFrame: CGFloat
    var titleStyle: UIFont.TextStyle
    var titleWeight: UIFont.Weight
    var checkmarkStyle: UIFont.TextStyle
    var rowInsets: NSDirectionalEdgeInsets
    var rowSpacing: CGFloat
    var minimumRowHeight: CGFloat
    var subtitleLines: Int
    /// The selected row sits on a tinted rounded rectangle (the workspace list).
    var highlightsSelection: Bool

    /// Workspaces: the runtime icon, the name, a tinted selected row.
    static let workspace = Self(
        width: 320,
        maxHeight: 430,
        iconSize: 18,
        iconFrame: 30,
        titleStyle: .body,
        titleWeight: .regular,
        checkmarkStyle: .body,
        rowInsets: NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12),
        rowSpacing: 0,
        minimumRowHeight: 46,
        subtitleLines: 1,
        highlightsSelection: true
    )

    /// Worktrees: Main or a branch, with the session count or path below.
    static let worktree = Self(
        width: 260,
        maxHeight: 320,
        iconSize: 12,
        iconFrame: 22,
        titleStyle: .subheadline,
        titleWeight: .semibold,
        checkmarkStyle: .subheadline,
        rowInsets: NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14),
        rowSpacing: 2,
        minimumRowHeight: 0,
        subtitleLines: 1,
        highlightsSelection: false
    )

    /// Agents, at accessibility text sizes: Pi, then each saved Agent with
    /// its description below.
    static let agent = Self(
        width: 280,
        maxHeight: 320,
        iconSize: 16,
        iconFrame: 22,
        titleStyle: .subheadline,
        titleWeight: .semibold,
        checkmarkStyle: .subheadline,
        rowInsets: NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14),
        rowSpacing: 2,
        minimumRowHeight: 0,
        subtitleLines: 2,
        highlightsSelection: false
    )
}

/// A Quick Session picker (workspace, worktree, and the accessibility-size
/// Agent list) in a popover on its pill. It refreshes in place while open: a
/// list that finishes loading replaces its spinner. Its colors are the
/// theme's when it opened, as the composer's other pickers.
@MainActor
final class QuickSessionPickerController: UIViewController, RouterModalContainer {
    var onDismissed: (() -> Void)?

    private let style: QuickSessionPickerStyle
    private var content: QuickSessionPickerContent
    private let colors: ComposerThemeColors
    private var onSelect: (String) -> Void
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    init(
        style: QuickSessionPickerStyle,
        content: QuickSessionPickerContent,
        colors: ComposerThemeColors,
        onSelect: @escaping (String) -> Void
    ) {
        self.style = style
        self.content = content
        self.colors = colors
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        rebuild()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }

    /// Rows are rebuilt only when the content changed: the presenter applies
    /// on each of its updates, and a rebuild under a finger drops its tap.
    func apply(content: QuickSessionPickerContent, onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        guard content != self.content else { return }
        self.content = content
        if isViewLoaded { rebuild() }
    }

    private func rebuild() {
        view.backgroundColor = colors.bg
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch content {
        case .loading(let message):
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = colors.comment
            spinner.startAnimating()
            let label = label(message, style: .subheadline, color: colors.comment)
            let row = UIStackView(arrangedSubviews: [spinner, label])
            row.spacing = 8
            row.alignment = .center
            stack.addArrangedSubview(padded(row, insets: NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)))
        case .empty(let title, let systemImage, let message):
            let icon = UIImageView(image: quickSessionSymbol(systemImage, style: .body, weight: .semibold, color: colors.fg))
            let titleLabel = label(title, style: .body, weight: .semibold, color: colors.fg)
            let titleRow = UIStackView(arrangedSubviews: [icon, titleLabel])
            titleRow.spacing = 8
            titleRow.alignment = .firstBaseline
            let column = UIStackView(arrangedSubviews: [titleRow, label(message, style: .caption1, color: colors.comment)])
            column.axis = .vertical
            column.alignment = .leading
            column.spacing = 8
            stack.addArrangedSubview(padded(column, insets: NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)))
        case .sections(let sections):
            let showsHeaders = sections.contains { $0.title != nil }
            stack.addArrangedSubview(spacer(showsHeaders ? 0 : 8))
            var first = true
            for section in sections where !section.rows.isEmpty || section.note != nil {
                if let title = section.title {
                    if !first {
                        stack.addArrangedSubview(divider())
                    }
                    let header = label(title, style: .caption1, weight: .semibold, color: colors.comment)
                    header.accessibilityTraits = .header
                    stack.addArrangedSubview(padded(header, insets: NSDirectionalEdgeInsets(
                        top: first ? 8 : 0, leading: 16, bottom: 4, trailing: 16
                    )))
                }
                for (index, row) in section.rows.enumerated() {
                    if index > 0, style.rowSpacing > 0 { stack.addArrangedSubview(spacer(style.rowSpacing)) }
                    stack.addArrangedSubview(rowButton(row))
                }
                if let note = section.note {
                    stack.addArrangedSubview(noteView(note))
                }
                first = false
            }
            stack.addArrangedSubview(spacer(8))
        }
        let fitting = stack.systemLayoutSizeFitting(
            CGSize(width: style.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        preferredContentSize = CGSize(width: style.width, height: min(style.maxHeight, ceil(fitting.height)))
    }

    private func noteView(_ note: QuickSessionPickerNote) -> UIView {
        let insets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        switch note {
        case .loading(let message):
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = colors.comment
            spinner.startAnimating()
            let row = UIStackView(arrangedSubviews: [spinner, label(message, style: .subheadline, color: colors.comment)])
            row.spacing = 8
            row.alignment = .center
            return padded(row, insets: insets)
        case .message(let message):
            return padded(label(message, style: .subheadline, color: colors.comment), insets: insets)
        }
    }

    private func rowButton(_ row: QuickSessionPickerRow) -> UIView {
        let button = QuickSessionPickerRowButton(row: row, style: style, colors: colors)
        let id = row.id
        button.addAction(UIAction { [weak self] _ in self?.onSelect(id) }, for: .primaryActionTriggered)
        guard style.highlightsSelection else { return button }
        return padded(button, insets: NSDirectionalEdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
    }

    private func label(
        _ text: String,
        style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        color: UIColor
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .quickSessionFont(style, weight: weight)
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func padded(_ view: UIView, insets: NSDirectionalEdgeInsets) -> UIView {
        let wrap = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: insets.leading),
            view.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -insets.trailing),
            view.topAnchor.constraint(equalTo: wrap.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -insets.bottom),
        ])
        return wrap
    }

    private func spacer(_ height: CGFloat) -> UIView {
        let view = UIView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = colors.comment.withAlphaComponent(0.22)
        line.heightAnchor.constraint(equalToConstant: 1 / max(view.traitCollection.displayScale, 1)).isActive = true
        return padded(line, insets: NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
    }
}

/// A picker row: icon, title and optional subtitle, and a checkmark on the
/// selected row. A `UIButton`, so touch and VoiceOver send its primary action.
@MainActor
private final class QuickSessionPickerRowButton: UIButton {
    private let pressedOverlay = UIView()
    private let colors: ComposerThemeColors

    init(row: QuickSessionPickerRow, style: QuickSessionPickerStyle, colors: ComposerThemeColors) {
        self.colors = colors
        super.init(frame: .zero)
        accessibilityTraits = row.isSelected ? [.button, .selected] : .button
        accessibilityLabel = row.accessibilityLabel
        accessibilityValue = row.accessibilityValue
        accessibilityIdentifier = row.accessibilityIdentifier
        if style.highlightsSelection {
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
            backgroundColor = row.isSelected ? colors.blue.withAlphaComponent(0.10) : .clear
        }
        pressedOverlay.isUserInteractionEnabled = false
        pressedOverlay.backgroundColor = colors.fg.withAlphaComponent(0.06)
        pressedOverlay.layer.cornerRadius = style.highlightsSelection ? 12 : 0
        pressedOverlay.layer.cornerCurve = .continuous
        pressedOverlay.isHidden = true

        let icon = QuickSessionIconView(size: style.iconSize, frameSize: style.iconFrame)
        icon.apply(row.icon, colors: colors, assetCache: row.iconAssetCache)
        let title = UILabel()
        title.text = row.title
        title.font = .quickSessionFont(style.titleStyle, weight: style.titleWeight)
        title.textColor = colors.fg
        title.lineBreakMode = .byTruncatingTail
        let labels = UIStackView(arrangedSubviews: [title])
        labels.axis = .vertical
        labels.spacing = 2
        if let subtitle = row.subtitle, !subtitle.isEmpty {
            let detail = UILabel()
            detail.text = subtitle
            detail.font = .preferredFont(forTextStyle: .caption1)
            detail.textColor = colors.comment
            detail.lineBreakMode = .byTruncatingTail
            detail.numberOfLines = style.subtitleLines
            labels.addArrangedSubview(detail)
        }
        let check = UIImageView(image: quickSessionSymbol(
            "checkmark",
            style: style.checkmarkStyle,
            weight: .semibold,
            color: colors.blue
        ))
        check.contentMode = .center
        check.alpha = row.isSelected ? 1 : 0
        check.setContentHuggingPriority(.required, for: .horizontal)
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        let rowStack = UIStackView(arrangedSubviews: [icon, labels, check])
        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = style.highlightsSelection ? 12 : 10
        rowStack.isUserInteractionEnabled = false
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        pressedOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pressedOverlay)
        addSubview(rowStack)
        let insets = style.rowInsets
        NSLayoutConstraint.activate([
            pressedOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            pressedOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            pressedOverlay.topAnchor.constraint(equalTo: topAnchor),
            pressedOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.leading),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.trailing),
            rowStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: insets.top),
            rowStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: style.minimumRowHeight),
            heightAnchor.constraint(greaterThanOrEqualTo: rowStack.heightAnchor, constant: insets.top + insets.bottom),
        ])
        let fit = heightAnchor.constraint(equalTo: rowStack.heightAnchor, constant: insets.top + insets.bottom)
        fit.priority = .defaultLow
        fit.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Sized by the row's constraints, not the empty button's title.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override var isHighlighted: Bool {
        didSet { pressedOverlay.isHidden = !isHighlighted }
    }
}
