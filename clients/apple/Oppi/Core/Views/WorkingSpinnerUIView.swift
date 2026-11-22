import UIKit

/// The working spinner in the style chosen in Settings (Metal orbs, braille
/// dots, or Game of Life), drawn in the model's color. Only the chosen style's
/// view shows, and only while `isAnimating`, so the others' timers and the
/// Metal loop stop. It follows a style change in Settings itself.
///
/// While `MotionPolicy` allows no loops (Animations at Short or Off, or
/// Reduce Motion) every style holds one still frame: braille and Game of Life
/// stop ticking here, and the orb paints its own still frame.
final class WorkingSpinnerUIView: UIView {
    private let braille = BrailleSpinnerUIView()
    private let life = GameOfLifeUIView(gridSize: 6)
    private let orb = OrbMetalView(style: .working, sizeClass: .workingCompact)
    private(set) var style = SpinnerStyle.current
    nonisolated(unsafe) private var styleObserver: NSObjectProtocol?
    private var motionObservers: [NSObjectProtocol] = []

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
        // "queue: .main" so a style change posted from any thread runs this view's
        // main-actor work on the main thread; a selector observer would run it on the
        // posting thread and trap in `MainActor.assumeIsolated`.
        styleObserver = NotificationCenter.default.addObserver(
            forName: AppPreferenceStore.Appearance.spinnerDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyStyleFromPreferences() }
        }
        motionObservers = MotionPolicy.observe { [weak self] in self?.applyMotion() }
        applyMotion()
        applyVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for observer in [styleObserver].compactMap({ $0 }) + motionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func applyMotion() {
        let still = !MotionPolicy.playsLoops
        braille.isFrozen = still
        life.isFrozen = still
        orb.forceReduceMotion = still
    }

    private func applyStyleFromPreferences() {
        style = SpinnerStyle.current
        applyVisibility()
    }

    /// Colors for `tint` (the model's color) over `palette`'s page.
    func apply(tint: UIColor, palette: ThemePalette) {
        braille.tintUIColor = tint
        life.tintUIColor = tint
        orb.tintUIColor = tint
        orb.accentUIColors = [palette.blue, palette.cyan, palette.purple, palette.orange]
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        palette.ui.bg.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
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
