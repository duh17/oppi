import UIKit

/// The glass jump-to-bottom button: a 36pt circle with an arrow, or while its
/// owner says it is busy a spinner ringed in `busyTint` with an arrow badge.
/// It scales and fades in and out and honors Reduce Motion. The chat timeline
/// and the SSH terminal's history view own one each.
///
/// The owner sets `accessibilityLabel` and `accessibilityIdentifier`, calls
/// `apply(palette:busyTint:)` before `setBusy(_:)`, and drives `setVisible(_:)`;
/// the first of each call lands without animation. While hidden or fading out
/// the button takes no touches.
final class JumpToBottomButton: UIControl {
    static let side: CGFloat = 36

    /// Runs on touch and on accessibility activation.
    var onTap: (() -> Void)?

    private let idleGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let idleArrow = UIImageView()
    private let busyGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let busyRing = CAShapeLayer()
    private let spinner = WorkingSpinnerUIView(side: 20)
    private let badge = UIImageView()
    private var shownVisible: Bool?
    private var shownBusy: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
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
            addSubview(view)
        }
        busyGlass.layer.addSublayer(busyRing)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            idleGlass.centerXAnchor.constraint(equalTo: centerXAnchor),
            idleGlass.centerYAnchor.constraint(equalTo: centerYAnchor),
            idleGlass.widthAnchor.constraint(equalToConstant: 34),
            idleGlass.heightAnchor.constraint(equalToConstant: 34),
            idleArrow.centerXAnchor.constraint(equalTo: idleGlass.centerXAnchor),
            idleArrow.centerYAnchor.constraint(equalTo: idleGlass.centerYAnchor),
            busyGlass.topAnchor.constraint(equalTo: topAnchor),
            busyGlass.bottomAnchor.constraint(equalTo: bottomAnchor),
            busyGlass.leadingAnchor.constraint(equalTo: leadingAnchor),
            busyGlass.trailingAnchor.constraint(equalTo: trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 20),
            spinner.heightAnchor.constraint(equalToConstant: 20),
            badge.widthAnchor.constraint(equalToConstant: 14),
            badge.heightAnchor.constraint(equalToConstant: 14),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 2),
        ])
        showFaces(busy: false)
        alpha = 0
        isHidden = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A 36pt circle answers a 44pt touch, like the terminal's bar buttons;
    /// an owner whose bounds are tighter (the chat's 44pt slot) clips it.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let outset = (44 - Self.side) / 2
        return bounds.insetBy(dx: -outset, dy: -outset).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        busyRing.path = UIBezierPath(ovalIn: busyGlass.bounds.insetBy(dx: 0.75, dy: 0.75)).cgPath
        busyRing.frame = busyGlass.bounds
    }

    /// The arrow reads in `palette`'s foreground; `busyTint` colors the ring,
    /// the spinner, and the badge.
    func apply(palette: ThemePalette, busyTint: UIColor) {
        idleArrow.image = UIImage.scaledSymbol("arrow.down", style: .caption1, weight: .bold, color: palette.ui.fg)
        badge.backgroundColor = busyTint
        badge.image = UIImage(
            systemName: "arrow.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .black)
        )?.withTintColor(
            ThemeColorContrast.foreground(for: busyTint),
            renderingMode: .alwaysOriginal
        )
        busyRing.strokeColor = busyTint.cgColor
        spinner.apply(tint: busyTint, palette: palette)
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Shows the busy face (ring, spinner, badge) or the idle one (glass, arrow).
    private func showFaces(busy: Bool) {
        for view in [busyGlass, spinner, badge] as [UIView] {
            view.alpha = busy ? 1 : 0
            view.transform = busy || reduceMotion ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
        }
        for view in [idleGlass, idleArrow] as [UIView] {
            view.alpha = busy ? 0 : 1
            view.transform = !busy || reduceMotion ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
        }
    }

    func setBusy(_ busy: Bool) {
        guard busy != shownBusy else { return }
        let animated = shownBusy != nil
        shownBusy = busy
        let apply = { self.showFaces(busy: busy) }
        if animated, !reduceMotion {
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut, animations: apply)
        } else {
            apply()
        }
        updateSpinnerAnimation()
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

    /// The spinner runs only while the button shows it: busy and on screen.
    private func updateSpinnerAnimation() {
        spinner.isAnimating = shownBusy == true && shownVisible == true
    }

    func setVisible(_ visible: Bool) {
        isUserInteractionEnabled = visible
        guard visible != shownVisible else { return }
        let animated = shownVisible != nil
        shownVisible = visible
        let hiddenTransform = reduceMotion ? CGAffineTransform.identity : Self.shrunkTowardTrailingBottom
        if visible {
            isHidden = false
            updateSpinnerAnimation()
        }
        let change = {
            self.alpha = visible ? 1 : 0
            self.transform = visible ? .identity : hiddenTransform
        }
        let finish: (Bool) -> Void = { _ in
            // The spinner keeps turning through the fade, then stops.
            guard self.shownVisible == false else { return }
            self.isHidden = true
            self.updateSpinnerAnimation()
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

    /// A 0.96 scale toward the button's bottom trailing corner.
    private static let shrunkTowardTrailingBottom: CGAffineTransform = {
        let factor: CGFloat = 0.96
        let inset = side / 2 * (1 - factor)
        return CGAffineTransform(translationX: inset, y: inset).scaledBy(x: factor, y: factor)
    }()
}
