import UIKit

/// The working spinner in the style chosen in Settings (Metal orbs, braille
/// dots, or Game of Life), drawn in the model's color. Only the chosen style's
/// view shows, and only while `isAnimating`, so the others' timers and the
/// Metal loop stop. It follows a style change in Settings itself.
final class WorkingSpinnerUIView: UIView {
    private let braille = BrailleSpinnerUIView()
    private let life = GameOfLifeUIView(gridSize: 6)
    private let orb = OrbMetalView(style: .working, sizeClass: .workingCompact)
    private(set) var style = SpinnerStyle.current

    var isAnimating = false {
        didSet { if isAnimating != oldValue { applyVisibility() } }
    }

    init(side: CGFloat) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        for view in [braille, life, orb] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
                view.widthAnchor.constraint(equalToConstant: side),
                view.heightAnchor.constraint(equalToConstant: side),
            ])
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(spinnerStyleDidChange),
            name: AppPreferenceStore.Appearance.spinnerDidChangeNotification,
            object: nil
        )
        applyVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func spinnerStyleDidChange() {
        MainActor.assumeIsolated {
            style = SpinnerStyle.current
            applyVisibility()
        }
    }

    /// Colors for `tint` (the model's color) over `palette`'s page.
    func apply(tint: UIColor, palette: ThemePalette) {
        braille.tintUIColor = tint
        life.tintUIColor = tint
        orb.tintUIColor = tint
        orb.accentUIColors = [palette.blue, palette.cyan, palette.purple, palette.orange].map { UIColor($0) }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(palette.bg).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        orb.isDarkBackground = OrbTint.isDarkBackground(red: red, green: green, blue: blue)
    }

    private func applyVisibility() {
        braille.isHidden = !isAnimating || style != .brailleDots
        life.isHidden = !isAnimating || style != .gameOfLife
        orb.isHidden = !isAnimating || style.orbStyle == nil
        if let orbStyle = style.orbStyle {
            orb.style = orbStyle
            orb.sizeClass = .workingCompact
        }
        orb.isAnimationEnabled = !orb.isHidden
    }
}
