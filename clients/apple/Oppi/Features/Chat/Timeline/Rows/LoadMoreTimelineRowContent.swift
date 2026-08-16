import UIKit

struct LoadMoreTimelineRowConfiguration: UIContentConfiguration {
    let hiddenCount: Int
    let hasOlderServerPage: Bool
    let renderWindowStep: Int
    let onTap: () -> Void

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
        button.titleLabel?.font = AppFont.monoMedium
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func apply(configuration: LoadMoreTimelineRowConfiguration) {
        currentConfiguration = configuration

        let title: String
        if configuration.hiddenCount > 0 {
            let revealCount = min(configuration.renderWindowStep, configuration.hiddenCount)
            title = "Show \(revealCount) earlier messages (\(configuration.hiddenCount) hidden)"
        } else if configuration.hasOlderServerPage {
            title = "Load earlier messages"
        } else {
            title = "No earlier messages"
        }
        button.setTitle(title, for: .normal)
        button.setTitleColor(UIColor(ThemeRuntimeState.currentPalette().blue), for: .normal)
    }

    @objc
    private func handleTap() {
        currentConfiguration.onTap()
    }
}
