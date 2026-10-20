import UIKit

/// A list row's content built as a view: rows whose layout a list content
/// configuration does not cover (a schedule card, a run, a prompt preview).
/// `make` builds the row's view each time the row is configured; the view is
/// pinned inside `insets`.
struct ControlViewContent: UIContentConfiguration {
    var insets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
    /// Insets relative to the cell's layout margins (the list's text inset),
    /// or to its edges.
    var followsLayoutMargins = true
    let make: @MainActor () -> UIView

    func makeContentView() -> UIView & UIContentView {
        ControlViewContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> Self { self }
}

private final class ControlViewContentView: UIView, UIContentView {
    private var content: UIView?
    var configuration: UIContentConfiguration {
        didSet { rebuild() }
    }

    init(configuration: ControlViewContent) {
        self.configuration = configuration
        super.init(frame: .zero)
        // A stack that is not `.fill` aligned bounds its height only from
        // below (its items) and hugs at a priority under the list's fitting
        // priority, so self-sizing grew it without limit and UIKit threw.
        // Pull the row to its smallest height just above that priority.
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = UILayoutPriority(UILayoutPriority.fittingSizeLevel.rawValue + 1)
        hug.isActive = true
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func rebuild() {
        content?.removeFromSuperview()
        guard let configuration = configuration as? ControlViewContent else { return }
        let view = configuration.make()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        content = view
        let insets = configuration.insets
        let leading = configuration.followsLayoutMargins ? layoutMarginsGuide.leadingAnchor : leadingAnchor
        let trailing = configuration.followsLayoutMargins ? layoutMarginsGuide.trailingAnchor : trailingAnchor
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            view.leadingAnchor.constraint(equalTo: leading, constant: insets.leading),
            view.trailingAnchor.constraint(equalTo: trailing, constant: -insets.trailing),
        ])
    }
}

/// Small builders for row views.
@MainActor
enum ControlRowViews {
    static func label(
        _ text: String?,
        style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        color: UIColor,
        lines: Int = 0
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.scaled(style, weight)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = lines
        return label
    }

    /// Read-only text the user can select and copy (SwiftUI
    /// `.textSelection(.enabled)`): a text view that does not scroll or
    /// edit, as the extension surfaces' text blocks are.
    static func selectableText(
        _ text: String,
        style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        color: UIColor
    ) -> UITextView {
        let view = UITextView()
        view.text = text
        view.font = UIFont.scaled(style, weight)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = color
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    /// A symbol before a label (SwiftUI `Label`).
    static func symbolLabel(
        _ text: String,
        systemImage: String,
        style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        color: UIColor,
        symbolColor: UIColor? = nil,
        lines: Int = 0
    ) -> UILabel {
        let font = UIFont.scaled(style, weight)
        let attributed = NSMutableAttributedString()
        if let image = UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(symbolColor ?? color, renderingMode: .alwaysOriginal) {
            attributed.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            attributed.append(NSAttributedString(string: " "))
        }
        attributed.append(NSAttributedString(string: text))
        attributed.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: attributed.length))
        let label = UILabel()
        label.attributedText = attributed
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = lines
        return label
    }

    static func stack(
        _ views: [UIView],
        axis: NSLayoutConstraint.Axis = .vertical,
        spacing: CGFloat,
        alignment: UIStackView.Alignment = .fill
    ) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = axis
        stack.spacing = spacing
        stack.alignment = alignment
        return stack
    }

    /// Takes the free width of a horizontal row that is not `.fill`
    /// aligned. It has no height: an unconstrained one left the row's fitting
    /// height unbounded, which UIKit rejects for a list cell's content.
    static func spacer() -> UIView {
        let view = UIView()
        view.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        view.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        view.heightAnchor.constraint(equalToConstant: 0).isActive = true
        return view
    }

    static func divider(_ palette: ThemePalette) -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.3)
        view.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return view
    }

    /// A title and its value side by side, the value trailing (SwiftUI `LabeledContent`).
    static func valueRow(_ title: String, _ value: String, palette: ThemePalette, style: UIFont.TextStyle = .subheadline) -> UIView {
        let titleLabel = label(title, style: style, color: UIColor(palette.comment), lines: 1)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        let valueText = selectableText(value, style: style, color: UIColor(palette.fg))
        valueText.textAlignment = .right
        let row = stack([titleLabel, valueText], axis: .horizontal, spacing: 12, alignment: .top)
        row.isAccessibilityElement = true
        row.accessibilityLabel = title
        row.accessibilityValue = value
        return row
    }
}

/// A small capsule label: a schedule's status, an Agent's version (SwiftUI
/// `StatusPill` at its mini size).
final class ControlStatusPill: UIView {
    enum Emphasis { case quiet, tinted }

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = UIFont.scaled(.caption2, .medium)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.cornerCurve = .continuous
    }

    func apply(text: String, tone: UIColor, emphasis: Emphasis, palette: ThemePalette, monospacedDigit: Bool = false) {
        label.text = text
        label.textColor = tone
        if monospacedDigit {
            label.font = UIFont.scaled(.caption2, .medium, monospacedDigits: true)
        }
        backgroundColor = emphasis == .quiet
            ? UIColor(palette.fg).withAlphaComponent(0.08)
            : tone.withAlphaComponent(0.14)
    }
}
