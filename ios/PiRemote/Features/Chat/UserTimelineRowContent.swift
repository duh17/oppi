import SwiftUI
import UIKit

/// Native UIKit user row used by Phase-1/2 chat rendering migration.
///
/// This renderer currently targets text-only user rows. Rows with image
/// attachments continue to use the existing SwiftUI path for parity.
struct UserTimelineRowConfiguration: UIContentConfiguration {
    let text: String
    let canFork: Bool
    let onFork: (() -> Void)?
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        UserTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> UserTimelineRowConfiguration {
        self
    }
}

final class UserTimelineRowContentView: UIView, UIContentView {
    private let iconLabel = UILabel()
    private let messageLabel = UILabel()
    private let stackView = UIStackView()

    private var currentConfiguration: UserTimelineRowConfiguration

    init(configuration: UserTimelineRowConfiguration) {
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
            guard let config = newValue as? UserTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.text = "❯"
        iconLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        iconLabel.textColor = UIColor(Color.tokyoBlue)
        iconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0
        messageLabel.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        messageLabel.textColor = UIColor(Color.tokyoFg)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .top
        stackView.distribution = .fill
        stackView.spacing = 8
        stackView.addArrangedSubview(iconLabel)
        stackView.addArrangedSubview(messageLabel)

        addSubview(stackView)
        addInteraction(UIContextMenuInteraction(delegate: self))

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func apply(configuration: UserTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        iconLabel.textColor = UIColor(palette.blue)
        messageLabel.textColor = UIColor(palette.fg)

        messageLabel.text = configuration.text
        messageLabel.isHidden = configuration.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension UserTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let text = currentConfiguration.text
        let hasCopyText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasForkAction = currentConfiguration.canFork && currentConfiguration.onFork != nil

        guard hasCopyText || hasForkAction else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }

            var actions: [UIMenuElement] = []

            if hasCopyText {
                actions.append(
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.string = text
                    }
                )
            }

            if hasForkAction, let onFork = self.currentConfiguration.onFork {
                actions.append(
                    UIAction(title: "Fork from here", image: UIImage(systemName: "arrow.triangle.branch")) { _ in
                        onFork()
                    }
                )
            }

            return UIMenu(title: "", children: actions)
        }
    }
}
