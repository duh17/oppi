import UIKit

/// UIView wrapper that drives a `GameOfLifeLayer` with a repeating Timer.
///
/// Lifecycle:
/// - Animation starts when the view moves to a window.
/// - Animation pauses when the view leaves its window (battery-safe).
/// - Timer fires every 80ms (matching pi TUI cadence).
final class GameOfLifeUIView: UIView {

    // MARK: - Configuration

    /// Tick interval in seconds. Matches pi TUI Loader cadence (80ms).
    static let tickInterval: TimeInterval = 0.08

    /// Grid dimension.
    let gridSize: Int

    /// Fill color for live cells.
    var tintUIColor: UIColor = .label {
        didSet { golLayer.tintCGColor = tintUIColor.cgColor }
    }

    // MARK: - State

    private let golLayer: GameOfLifeLayer
    nonisolated(unsafe) private var timer: Timer?

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
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.timerFired()
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    private func timerFired() {
        golLayer.tick()
        golLayer.setNeedsDisplay()
    }
}
