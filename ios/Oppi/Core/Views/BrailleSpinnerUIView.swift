import UIKit

/// UIView that cycles through braille spinner frames via CADisplayLink.
///
/// Lifecycle mirrors `GameOfLifeUIView`:
/// - Animation starts when the view moves to a window.
/// - Animation stops when the view leaves its window or on deinit.
final class BrailleSpinnerUIView: UIView {

    // MARK: - Configuration

    private static let brailleFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// Text color for the braille character.
    var tintUIColor: UIColor = .label {
        didSet { label.textColor = tintUIColor }
    }

    // MARK: - State

    private let label = UILabel()
    nonisolated(unsafe) private var displayLink: CADisplayLink?
    private var frameIndex = 0

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear

        label.text = Self.brailleFrames[0]
        label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        label.textColor = tintUIColor
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Layout

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
        // ~12 FPS → ~83ms per frame, close to the 80ms braille interval
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 14, preferred: 12)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        frameIndex = (frameIndex + 1) % Self.brailleFrames.count
        label.text = Self.brailleFrames[frameIndex]
    }
}
