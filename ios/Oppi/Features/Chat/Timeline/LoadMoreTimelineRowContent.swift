import UIKit

struct LoadMoreTimelineRowConfiguration: UIContentConfiguration {
    let hiddenCount: Int
    let renderWindowStep: Int
    let onTap: () -> Void
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        LoadMoreTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class LoadMoreTimelineRowContentView: UIView, UIContentView {
    private let button = UIButton(type: .system)
    private var currentConfiguration: LoadMoreTimelineRowConfiguration

    init(configuration: LoadMoreTimelineRowConfiguration) {
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
            guard let config = newValue as? LoadMoreTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    private func apply(configuration: LoadMoreTimelineRowConfiguration) {
        currentConfiguration = configuration

        let revealCount = min(configuration.renderWindowStep, configuration.hiddenCount)
        button.setTitle(
            "Show \(revealCount) earlier messages (\(configuration.hiddenCount) hidden)",
            for: .normal
        )
        button.setTitleColor(UIColor(configuration.themeID.palette.blue), for: .normal)
    }

    @objc
    private func handleTap() {
        currentConfiguration.onTap()
    }
}
