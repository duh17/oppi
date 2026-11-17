import UIKit

/// A progress ring: a track and an arc from 12 o'clock, sized by its container.
/// A fraction draws its arc; no fraction draws a dashed full ring, "going on, no
/// position yet". Paint only; the view that owns the ring speaks its value.
///
/// Used by extension progress nodes and the composer's attachment chips.
final class ProgressRingGlyph: UIView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    init(lineWidth: CGFloat = 2.5) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        for shape in [track, arc] as [CAShapeLayer] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// On screen the arc moves to a new fraction with the layer's short implicit
    /// animation; off screen (a ring just built) it jumps, so it never sweeps in
    /// from a full circle.
    func apply(track trackColor: UIColor, arc arcColor: UIColor, fraction: Double?) {
        CATransaction.begin()
        CATransaction.setDisableActions(window == nil)
        track.strokeColor = trackColor.cgColor
        arc.strokeColor = arcColor.cgColor
        if let fraction {
            arc.lineDashPattern = nil
            arc.strokeEnd = CGFloat(min(1, max(0, fraction)))
        } else {
            arc.lineDashPattern = [2, 3]
            arc.strokeEnd = 1
        }
        CATransaction.commit()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: (side - arc.lineWidth) / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, arc] as [CAShapeLayer] {
            shape.path = path.cgPath
            shape.frame = bounds
        }
        CATransaction.commit()
    }
}
