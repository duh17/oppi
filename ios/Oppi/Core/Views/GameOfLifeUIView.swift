import UIKit

/// UIView wrapper that drives a `GameOfLifeLayer` with a `CADisplayLink`.
///
/// Lifecycle:
/// - Animation starts when the view moves to a window.
/// - Animation pauses when the view leaves its window (battery-safe).
/// - CADisplayLink targets ~8 FPS via `preferredFrameRateRange`.
final class GameOfLifeUIView: UIView {

    // MARK: - Configuration

    /// Grid dimension.
    let gridSize: Int

    /// Fill color for live cells.
    var tintUIColor: UIColor = .label {
        didSet { golLayer.tintCGColor = tintUIColor.cgColor }
    }

    // MARK: - State

    private let golLayer: GameOfLifeLayer
    private var displayLink: CADisplayLink?

    // MARK: - Init

    init(gridSize: Int = 6) {
        self.gridSize = gridSize
        self.golLayer = GameOfLifeLayer(gridSize: gridSize)
        super.init(frame: .zero)
        layer.addSublayer(golLayer)
        isOpaque = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    deinit {
        stopAnimation()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        golLayer.frame = bounds
        golLayer.contentsScale = traitCollection.displayScale
        CATransaction.commit()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    // MARK: - Window Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    // MARK: - Animation

    private func startAnimation() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 6, maximum: 10, preferred: 8)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        golLayer.tick()
        golLayer.setNeedsDisplay()
    }
}
