import UIKit

/// Top-of-timeline marker for rows that are not rendered yet. Scrolling up
/// toward it reveals them automatically (see the timeline scroll delegate),
/// so the row is only a progress affordance. Accessibility activation keeps
/// the same owner action for readers who cannot drive a scroll gesture.
struct LoadMoreTimelineRowConfiguration: UIContentConfiguration {
    let onRequestEarlier: () -> Void

    func makeContentView() -> any UIView & UIContentView {
        LoadMoreTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class LoadMoreTimelineRowContentView: UIView, UIContentView {
    private static let rowHeight: CGFloat = 44

    private let spinner = UIActivityIndicatorView(style: .medium)
    private var currentConfiguration: LoadMoreTimelineRowConfiguration

    init(configuration: LoadMoreTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? LoadMoreTimelineRowConfiguration else { return }
            currentConfiguration = config
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = false
        spinner.startAnimating()
        addSubview(spinner)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.rowHeight),
        ])

        isAccessibilityElement = true
        accessibilityLabel = "Load earlier messages"
        accessibilityTraits = .button
    }

    /// Reused cells stop animating when they leave the window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            spinner.startAnimating()
        }
    }

    override func accessibilityActivate() -> Bool {
        currentConfiguration.onRequestEarlier()
        return true
    }
}
