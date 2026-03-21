import UIKit

struct WorkingIndicatorTimelineRowConfiguration: UIContentConfiguration {
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        WorkingIndicatorTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

/// Unified "agent is working" indicator — a Game of Life grid.
/// Replaces the old π + 3 bouncing dots with a single living animation
/// that conveys "something intelligent is happening."
final class WorkingIndicatorTimelineRowContentView: UIView, UIContentView {
    private let golView: GameOfLifeUIView

    private var currentConfiguration: WorkingIndicatorTimelineRowConfiguration

    init(configuration: WorkingIndicatorTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        self.golView = GameOfLifeUIView(gridSize: 6)
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? WorkingIndicatorTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        golView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(golView)

        NSLayoutConstraint.activate([
            golView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            golView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            golView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            golView.widthAnchor.constraint(equalToConstant: 16),
            golView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func apply(configuration: WorkingIndicatorTimelineRowConfiguration) {
        currentConfiguration = configuration
        golView.tintUIColor = .label
    }
}
