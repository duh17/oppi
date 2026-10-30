import UIKit

// MARK: - Stopped fold row

/// The last row of an open thread: "N Stopped" with a chevron, folding the
/// thread's stopped members open and closed (`SessionThreadStoppedFold`).
/// A stopped member is history, so it stays behind this row until asked for;
/// the live members list above it.
///
/// The row sits on the thread's grid, not a card of its own: it starts on the
/// root row's title column and ends on its trailing text column, one title
/// column in for its depth, as an open thread's child rows do.
///
/// The whole row is one button. A touch and accessibility activation reach the
/// same list action, `SessionListRowActions.toggleStoppedMembers`, and the
/// list owner keeps the open or closed choice. The list never selects this row.
struct SessionThreadStoppedFoldConfiguration: UIContentConfiguration {
    let fold: SessionThreadStoppedFold
    /// Indent level, level with the thread's member rows.
    let depth: Int
    let themeID: ThemeID
    let actions: SessionListRowActions

    func makeContentView() -> any UIView & UIContentView {
        SessionThreadStoppedFoldContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class SessionThreadStoppedFoldContentView: UIView, UIContentView {
    private let control = SessionThreadStoppedFoldControl()
    private let chevron = UIImageView()
    private let titleLabel = UILabel()
    private var applied: SessionThreadStoppedFoldConfiguration
    private var leadingConstraint: NSLayoutConstraint?

    var configuration: UIContentConfiguration {
        get { applied }
        set {
            guard let configuration = newValue as? SessionThreadStoppedFoldConfiguration else { return }
            apply(configuration)
        }
    }

    init(configuration: SessionThreadStoppedFoldConfiguration) {
        applied = configuration
        super.init(frame: .zero)
        control.onActivate = { [weak self] in
            guard let self else { return }
            applied.actions.toggleStoppedMembers(applied.fold)
        }
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = UIFont.scaled(.footnote, .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [chevron, titleLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(stack)
        addSubview(control)

        directionalLayoutMargins = .zero
        preservesSuperviewLayoutMargins = true
        let margins = layoutMarginsGuide
        let leading = control.leadingAnchor.constraint(equalTo: margins.leadingAnchor)
        leadingConstraint = leading
        // A fixed gap above and below keeps the row apart from its neighbors. The horizontal inset
        // inside the card matches the strip's, so the two rows' words share a column.
        NSLayoutConstraint.activate([
            leading,
            control.trailingAnchor.constraint(
                equalTo: margins.trailingAnchor, constant: -SessionRowView.trailingTextInset
            ),
            control.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: 4),
            stack.topAnchor.constraint(equalTo: control.topAnchor, constant: 10),
            control.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 8),
            control.trailingAnchor.constraint(greaterThanOrEqualTo: stack.trailingAnchor, constant: 8),
        ])
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Everything the row shows or announces is set here, so a reused cell keeps nothing of
    /// its last thread: identifier, label, value, hint, and indent.
    private func apply(_ configuration: SessionThreadStoppedFoldConfiguration) {
        applied = configuration
        let fold = configuration.fold
        let colors = SessionRowStyle.for(configuration.themeID).colors
        leadingConstraint?.constant = CGFloat(min(configuration.depth, SessionListEntryContentView.maxIndentLevels))
            * SessionListEntryContentView.indentPerLevel
        control.backgroundColor = colors.bgHighlight.withAlphaComponent(0.45)
        chevron.image = UIImage.scaledSymbol(
            fold.isOpen ? "chevron.down" : "chevron.right", style: .caption1, weight: .semibold
        )
        chevron.tintColor = colors.comment
        let title = String(localized: "\(fold.count) Stopped")
        titleLabel.text = title
        titleLabel.textColor = colors.comment

        control.accessibilityIdentifier = "thread.stopped.\(fold.rootId)"
        control.accessibilityLabel = title
        control.accessibilityValue = fold.isOpen ? String(localized: "Expanded") : String(localized: "Collapsed")
        control.accessibilityHint = fold.isOpen
            ? String(localized: "Hides the thread's stopped sessions")
            : String(localized: "Shows the thread's stopped sessions")
        accessibilityElements = [control]
    }
}

/// The row's button: a touch inside it and accessibility activation both run `onActivate`.
final class SessionThreadStoppedFoldControl: UIControl {
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        addAction(UIAction { [weak self] _ in self?.onActivate?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}
