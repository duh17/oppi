import SwiftUI
import UIKit

struct SystemTimelineRowConfiguration: UIContentConfiguration {
    let message: String
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        SystemTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class SystemTimelineRowContentView: UIView, UIContentView {
    private let stackView = UIStackView()
    private let iconImageView = UIImageView()
    private let messageLabel = UILabel()

    private var currentConfiguration: SystemTimelineRowConfiguration

    init(configuration: SystemTimelineRowConfiguration) {
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
            guard let config = newValue as? SystemTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.image = UIImage(systemName: "info.circle")
        iconImageView.contentMode = .scaleAspectFit

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .preferredFont(forTextStyle: .caption1)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        addSubview(stackView)
        stackView.addArrangedSubview(iconImageView)
        stackView.addArrangedSubview(messageLabel)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),

            iconImageView.widthAnchor.constraint(equalToConstant: 13),
            iconImageView.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    private func apply(configuration: SystemTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        iconImageView.tintColor = UIColor(palette.comment)
        messageLabel.textColor = UIColor(palette.comment)
        messageLabel.text = configuration.message
    }
}
