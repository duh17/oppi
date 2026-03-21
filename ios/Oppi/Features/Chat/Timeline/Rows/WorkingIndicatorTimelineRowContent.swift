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

/// Working indicator row: [10pt leading][16x16 spinner][6pt gap]["Working..." label]
/// Supports braille dots and Game of Life spinner styles via Settings.
final class WorkingIndicatorTimelineRowContentView: UIView, UIContentView {
    private let brailleView = BrailleSpinnerUIView()
    private let golView = GameOfLifeUIView(gridSize: 6)
    private let workingLabel = UILabel()

    private var currentConfiguration: WorkingIndicatorTimelineRowConfiguration

    init(configuration: WorkingIndicatorTimelineRowConfiguration) {
        self.currentConfiguration = configuration
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

        brailleView.translatesAutoresizingMaskIntoConstraints = false
        golView.translatesAutoresizingMaskIntoConstraints = false
        workingLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(brailleView)
        addSubview(golView)
        addSubview(workingLabel)

        workingLabel.text = "Working..."
        workingLabel.font = .preferredFont(forTextStyle: .callout)

        let spinnerConstraints: [NSLayoutConstraint] = [
            // Braille spinner
            brailleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            brailleView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            brailleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            brailleView.widthAnchor.constraint(equalToConstant: 16),
            brailleView.heightAnchor.constraint(equalToConstant: 16),

            // GoL spinner (same position)
            golView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            golView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            golView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            golView.widthAnchor.constraint(equalToConstant: 16),
            golView.heightAnchor.constraint(equalToConstant: 16),

            // Working label
            workingLabel.leadingAnchor.constraint(equalTo: brailleView.trailingAnchor, constant: 6),
            workingLabel.centerYAnchor.constraint(equalTo: brailleView.centerYAnchor),
        ]

        NSLayoutConstraint.activate(spinnerConstraints)
    }

    private func apply(configuration: WorkingIndicatorTimelineRowConfiguration) {
        currentConfiguration = configuration

        let style = SpinnerStyle.current
        brailleView.isHidden = style != .brailleDots
        golView.isHidden = style != .gameOfLife

        let palette = ThemeRuntimeState.currentPalette()
        let commentColor = UIColor(palette.comment).withAlphaComponent(0.6)

        brailleView.tintUIColor = commentColor
        golView.tintUIColor = .label
        workingLabel.textColor = commentColor
    }
}
