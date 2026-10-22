import UIKit

/// The OSC 9;4 progress ring drawn around the bottom bar's status symbol.
///
/// - determinate: an arc from 12 o'clock filled to the percentage;
/// - indeterminate, or an error with no percentage: a short arc that spins;
/// - reduced motion: no spin; a dotted full ring says "in progress, no
///   position" without moving;
/// - paused: the same arc, dashed, so the state does not rest on colour alone.
///
/// Colour carries the state too (blue, red for an error, orange paused), and
/// the owner speaks it through the glyph button's value.
final class SSHTerminalProgressRingView: UIView {
    static let diameter: CGFloat = 28
    static let lineWidth: CGFloat = 2.5
    private static let spinKey = "sshTerminal.progress.spin"
    /// Length of the spinning arc, as a share of the ring.
    private static let spinnerArc: CGFloat = 0.28

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var spins = false
    /// Times the arc was set turning from 12 o'clock, for tests: a report that
    /// repeats must not count.
    private(set) var spinStarts = 0
    private var activeObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        for layer in [track, arc] {
            layer.fillColor = nil
            layer.lineWidth = Self.lineWidth
            self.layer.addSublayer(layer)
        }
        track.strokeEnd = 1
        // iOS drops running animations when the app goes to the background.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartSpin() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    /// The arc's end as a share of the ring, and whether it is turning. What the ring shows, for tests.
    var drawnFraction: CGFloat { arc.strokeEnd }
    var isSpinning: Bool { arc.animation(forKey: Self.spinKey) != nil }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.diameter, height: Self.diameter) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: (min(bounds.width, bounds.height) - Self.lineWidth) / 2,
            startAngle: -.pi / 2, endAngle: .pi * 3 / 2, clockwise: true
        ).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [track, arc] {
            layer.bounds = bounds
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            layer.path = path
        }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restartSpin() }
    }

    func apply(_ report: SSHTerminalProgressReport?, color: UIColor, reduceMotion: Bool) {
        guard let report else {
            isHidden = true
            spins = false
            arc.removeAnimation(forKey: Self.spinKey)
            return
        }
        isHidden = false
        track.strokeColor = color.withAlphaComponent(0.25).cgColor
        arc.strokeColor = color.cgColor
        let dashed = report.state == .paused

        // A report moving the arc animates; reduced motion jumps.
        let wasSpinning = spins
        CATransaction.begin()
        CATransaction.setDisableActions(reduceMotion)
        if let fraction = report.fraction {
            spins = false
            arc.strokeEnd = fraction
        } else if reduceMotion {
            spins = false
            arc.strokeEnd = 1
        } else {
            spins = true
            arc.strokeEnd = Self.spinnerArc
        }
        CATransaction.commit()

        let dotted = report.fraction == nil && reduceMotion
        arc.lineCap = dashed ? .butt : .round
        arc.lineDashPattern = if dotted {
            [0.1, 4.7]
        } else if dashed {
            [4, 3]
        } else {
            nil
        }
        // Every report passes through here; only the start of a spin turns the
        // arc from 12 o'clock again. A spin already going keeps its phase.
        if !spins {
            arc.removeAnimation(forKey: Self.spinKey)
        } else if !wasSpinning {
            restartSpin()
        }
    }

    private func restartSpin() {
        arc.removeAnimation(forKey: Self.spinKey)
        guard spins, window != nil else { return }
        spinStarts += 1
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 2
        spin.duration = 1
        spin.repeatCount = .infinity
        arc.add(spin, forKey: Self.spinKey)
    }
}
