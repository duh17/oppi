import UIKit

/// A spinner over a one-line status ("Creating session...", "Starting new
/// session…") in an elevated panel floating over a screen. VoiceOver reads
/// the status as it changes.
final class FloatingProgressPanel: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    /// The border's width; nil draws the elevated surface's own stroke width.
    private let borderWidth: CGFloat?

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    init(borderWidth: CGFloat? = nil) {
        self.borderWidth = borderWidth
        super.init(frame: .zero)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var accessibilityLabel: String? {
        get { label.text }
        set {}
    }

    func apply(_ palette: ThemePalette) {
        let surface = ThemeSurfaceStyle.resolve(.elevatedPanel, palette: palette)
        backgroundColor = UIColor(surface.fill)
        layer.borderColor = surface.stroke.map { UIColor($0).cgColor }
        layer.borderWidth = surface.stroke == nil ? 0 : borderWidth ?? surface.strokeLineWidth
        spinner.color = UIColor(palette.cyan)
        label.textColor = UIColor(palette.fg)
    }
}
