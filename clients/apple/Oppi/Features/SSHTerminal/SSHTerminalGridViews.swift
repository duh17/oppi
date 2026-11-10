import UIKit

/// History scroller. Touches begin here, so a sticky long-press tap ignore
/// can clear before the next independent tap is recognized. Until its pan
/// starts (and cancels these touches), moves report vertical finger travel.
final class SSHTerminalHistoryScrollView: UIScrollView {
    var touchBegan: (() -> Void)?
    var touchMoved: ((CGFloat) -> Void)?
    var touchEnded: (() -> Void)?
    /// Where the first finger of this touch went down, in the grid's
    /// coordinates, which do not scroll.
    var firstTouchY: CGFloat?
    /// That finger. A second finger neither moves the lead nor resets
    /// `firstTouchY`.
    private var firstTouch: UITouch?

    private func track(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Every finger on this view is new: a fresh touch, even if a lost
        // end left an old one tracked.
        let fresh = event?.touches(for: self).map { $0.isSubset(of: touches) } ?? true
        guard firstTouch == nil || fresh, let touch = touches.first else { return }
        firstTouch = touch
        firstTouchY = touch.location(in: superview).y
    }

    /// True when the tracked finger is among `touches`, which then ends it.
    private func untrack(_ touches: Set<UITouch>) -> Bool {
        guard let firstTouch, touches.contains(firstTouch) else { return false }
        self.firstTouch = nil
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        track(touches, with: event)
        touchBegan?()
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let firstTouch, touches.contains(firstTouch), let firstTouchY {
            touchMoved?(firstTouch.location(in: superview).y - firstTouchY)
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if untrack(touches) { touchEnded?() }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if untrack(touches) { touchEnded?() }
        super.touchesCancelled(touches, with: event)
    }

    override func touchesShouldBegin(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) -> Bool {
        track(touches, with: event)
        touchBegan?()
        return super.touchesShouldBegin(touches, with: event, in: view)
    }
}

/// Metal drawable host. Kept as a child so history rubber-band can translate
/// the grid without moving the native scroll view on top of it.
final class SSHTerminalMetalHostView: UIView {
    let metalLayer = CAMetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
    }
}

final class SSHTerminalSelectionOverlay: UIView {
    var spans: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }
    /// The theme's selection color; nil keeps the system blue.
    var fill: UIColor? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        // The overlay sits over the text, so a theme's own (opaque) color is
        // laid down translucent enough to read through.
        (fill?.withAlphaComponent(0.55) ?? UIColor.systemBlue.withAlphaComponent(0.28)).setFill()
        for span in spans {
            UIBezierPath(rect: span).fill()
        }
    }
}
