import UIKit

/// Show a flash overlay + floating "Copied" pill centered on the given view.
@MainActor
func showCopiedOverlay(on view: UIView) {
    let palette = ThemeRuntimeState.currentPalette()
    let overlay = UIView()
    overlay.backgroundColor = palette.ui.fg.withAlphaComponent(0.08)
    overlay.frame = view.bounds
    overlay.layer.cornerRadius = view.layer.cornerRadius
    overlay.isUserInteractionEnabled = false
    view.addSubview(overlay)

    let pill = CopiedPillView()
    pill.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pill)
    NSLayoutConstraint.activate([
        pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        pill.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        // A one-line block is narrow: the pill stays inside it.
        pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
    ])
    pill.alpha = 0
    pill.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)

    UIView.animate(withDuration: 0.15) {
        pill.alpha = 1
        pill.transform = .identity
    }

    UIView.animate(withDuration: 0.3, delay: 0.8, options: .curveEaseOut) {
        pill.alpha = 0
        pill.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        overlay.alpha = 0
    } completion: { _ in
        pill.removeFromSuperview()
        overlay.removeFromSuperview()
    }
}

private final class CopiedPillView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let palette = ThemeRuntimeState.currentPalette()

        let icon = UIImageView(image: UIImage(systemName: "checkmark"))
        icon.tintColor = palette.ui.fg
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)

        let label = UILabel()
        label.text = "Copied"
        // Capped: a short, transient pill over a block that may be one line tall.
        label.font = AppFont.scaledSystem(13, .semibold, relativeTo: .footnote, maximumPointSize: 22)
        label.textColor = palette.ui.fg
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Transient pill over code content with no blur behind it, so it
        // takes the near-opaque card role.
        backgroundColor = ThemeSurfaceStyle.resolve(.opaqueCard, palette: palette).fill
        layer.cornerRadius = 16
        isUserInteractionEnabled = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
