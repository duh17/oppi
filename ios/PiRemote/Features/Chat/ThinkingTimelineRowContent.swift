import SwiftUI
import UIKit

/// Native UIKit thinking row used by Phase-1/2 chat rendering migration.
///
/// This renderer targets collapsed thinking rows. Expanded thinking content
/// remains on the existing SwiftUI path for parity.
struct ThinkingTimelineRowConfiguration: UIContentConfiguration {
    let isDone: Bool
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        ThinkingTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> ThinkingTimelineRowConfiguration {
        self
    }
}

final class ThinkingTimelineRowContentView: UIView, UIContentView {
    private let containerStack = UIStackView()
    private let statusHostView = UIView()
    private let statusImageView = UIImageView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let spacerView = UIView()
    private let chevronImageView = UIImageView()

    private var currentConfiguration: ThinkingTimelineRowConfiguration

    init(configuration: ThinkingTimelineRowConfiguration) {
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
            guard let config = newValue as? ThinkingTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.axis = .horizontal
        containerStack.alignment = .center
        containerStack.spacing = 6

        statusHostView.translatesAutoresizingMaskIntoConstraints = false

        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.image = UIImage(systemName: "brain")
        statusImageView.tintColor = UIColor(Color.tokyoPurple)
        statusImageView.contentMode = .scaleAspectFit

        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.color = UIColor(Color.tokyoPurple)
        statusSpinner.hidesWhenStopped = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = UIColor(Color.tokyoComment)
        titleLabel.numberOfLines = 1

        spacerView.translatesAutoresizingMaskIntoConstraints = false

        chevronImageView.translatesAutoresizingMaskIntoConstraints = false
        chevronImageView.image = UIImage(systemName: "chevron.right")
        chevronImageView.tintColor = UIColor(Color.tokyoComment)
        chevronImageView.contentMode = .scaleAspectFit

        addSubview(containerStack)

        containerStack.addArrangedSubview(statusHostView)
        containerStack.addArrangedSubview(titleLabel)
        containerStack.addArrangedSubview(spacerView)
        containerStack.addArrangedSubview(chevronImageView)

        statusHostView.addSubview(statusImageView)
        statusHostView.addSubview(statusSpinner)

        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerStack.topAnchor.constraint(equalTo: topAnchor),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusHostView.widthAnchor.constraint(equalToConstant: 14),
            statusHostView.heightAnchor.constraint(equalToConstant: 14),

            statusImageView.leadingAnchor.constraint(equalTo: statusHostView.leadingAnchor),
            statusImageView.trailingAnchor.constraint(equalTo: statusHostView.trailingAnchor),
            statusImageView.topAnchor.constraint(equalTo: statusHostView.topAnchor),
            statusImageView.bottomAnchor.constraint(equalTo: statusHostView.bottomAnchor),

            statusSpinner.centerXAnchor.constraint(equalTo: statusHostView.centerXAnchor),
            statusSpinner.centerYAnchor.constraint(equalTo: statusHostView.centerYAnchor),

            chevronImageView.widthAnchor.constraint(equalToConstant: 10),
            chevronImageView.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    private func apply(configuration: ThinkingTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        statusImageView.tintColor = UIColor(palette.purple)
        statusSpinner.color = UIColor(palette.purple)
        titleLabel.textColor = UIColor(palette.comment)
        chevronImageView.tintColor = UIColor(palette.comment)

        if configuration.isDone {
            titleLabel.text = "Thought"
            statusImageView.isHidden = false
            statusSpinner.stopAnimating()
            statusSpinner.isHidden = true
            chevronImageView.isHidden = false
        } else {
            titleLabel.text = "Thinking…"
            statusImageView.isHidden = true
            statusSpinner.isHidden = false
            statusSpinner.startAnimating()
            chevronImageView.isHidden = true
        }
    }
}
