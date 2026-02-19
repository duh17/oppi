import SwiftUI
import UIKit

struct ErrorTimelineRowConfiguration: UIContentConfiguration {
    let message: String
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        ErrorTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class ErrorTimelineRowContentView: UIView, UIContentView {
    private let containerView = UIView()
    private let stackView = UIStackView()
    private let iconImageView = UIImageView()
    private let messageLabel = UILabel()

    private var currentConfiguration: ErrorTimelineRowConfiguration

    private lazy var copyDoubleTapGesture: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleContainerDoubleTapCopy))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    init(configuration: ErrorTimelineRowConfiguration) {
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
            guard let config = newValue as? ErrorTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = 12
        containerView.addGestureRecognizer(copyDoubleTapGesture)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .top
        stackView.spacing = 8

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.image = UIImage(systemName: "exclamationmark.triangle.fill")
        iconImageView.contentMode = .scaleAspectFit

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.numberOfLines = 0

        addSubview(containerView)
        containerView.addSubview(stackView)
        stackView.addArrangedSubview(iconImageView)
        stackView.addArrangedSubview(messageLabel)

        addInteraction(UIContextMenuInteraction(delegate: self))

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),

            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func apply(configuration: ErrorTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        let red = UIColor(palette.red)

        iconImageView.tintColor = red
        messageLabel.textColor = UIColor(palette.fg)
        messageLabel.text = configuration.message

        containerView.backgroundColor = red.withAlphaComponent(0.18)
    }

    private func copyValue() -> String? {
        let message = currentConfiguration.message
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return message
    }

    @objc private func handleContainerDoubleTapCopy() {
        guard let message = copyValue() else {
            return
        }

        TimelineCopyFeedback.copy(message, feedbackView: containerView)
    }

    func contextMenu() -> UIMenu? {
        guard let message = copyValue() else {
            return nil
        }

        return UIMenu(title: "", children: [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                TimelineCopyFeedback.copy(message, feedbackView: self?.containerView)
            },
        ])
    }
}

extension ErrorTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard contextMenu() != nil else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.contextMenu()
        }
    }
}
