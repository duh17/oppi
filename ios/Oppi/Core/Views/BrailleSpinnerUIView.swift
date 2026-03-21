import UIKit

/// UIView that cycles through braille spinner frames via a repeating Timer.
///
/// Lifecycle mirrors `GameOfLifeUIView`:
/// - Animation starts when the view moves to a window.
/// - Animation stops when the view leaves its window or on deinit.
/// - Timer fires every 80ms (matching pi TUI Loader cadence).
final class BrailleSpinnerUIView: UIView {

    // MARK: - Configuration

    private static let brailleFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// Tick interval in seconds. Matches pi TUI Loader cadence (80ms).
    static let tickInterval: TimeInterval = 0.08

    /// Text color for the braille character.
    var tintUIColor: UIColor = .label {
        didSet { label.textColor = tintUIColor }
    }

    // MARK: - State

    private let label = UILabel()
    nonisolated(unsafe) private var timer: Timer?
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
        timer?.invalidate()
        timer = nil
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
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIndex = (self.frameIndex + 1) % Self.brailleFrames.count
            self.label.text = Self.brailleFrames[self.frameIndex]
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
}
