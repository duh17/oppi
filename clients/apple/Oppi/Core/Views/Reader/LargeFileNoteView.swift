import UIKit

/// The reader's note over a file too large to format when it opens
/// (`FullScreenCodeContent.opensPlain`): why it shows plain text, and the
/// action that formats it anyway.
final class LargeFileNoteView: UIView {
    init(message: String, action: String, palette: ThemePalette, onAction: @escaping () -> Void) {
        super.init(frame: .zero)
        accessibilityIdentifier = "reader.largeFileNote"

        let surface = ThemeSurfaceStyle.resolve(.elevatedPanel, palette: palette)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.backgroundColor = surface.fill
        addSubview(blur)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = palette.ui.fgDim
        label.numberOfLines = 0

        var configuration = UIButton.Configuration.plain()
        configuration.title = action
        configuration.contentInsets = .zero
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            // Footnote's default size, scaled with Dynamic Type like the label.
            attributes.font = UIFontMetrics(forTextStyle: .footnote)
                .scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in onAction() })
        button.tintColor = palette.ui.syntaxKeyword
        button.accessibilityIdentifier = "reader.largeFileNote.format"
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
