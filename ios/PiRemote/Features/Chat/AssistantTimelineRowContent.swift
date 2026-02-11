import SwiftUI
import UIKit

/// Native UIKit assistant row used by the chat timeline migration.
///
/// This renderer is optimized for plain-text assistant content. Rich markdown
/// content is routed through the existing SwiftUI markdown renderer for parity.
struct AssistantTimelineRowConfiguration: UIContentConfiguration {
    let text: String
    let isStreaming: Bool
    let canFork: Bool
    let onFork: (() -> Void)?
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        AssistantTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> AssistantTimelineRowConfiguration {
        self
    }
}

final class AssistantTimelineRowContentView: UIView, UIContentView {
    private let iconLabel = UILabel()
    private let messageTextView = UITextView()
    private let cursorView = UIView()

    private var currentConfiguration: AssistantTimelineRowConfiguration

    init(configuration: AssistantTimelineRowConfiguration) {
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
            guard let config = newValue as? AssistantTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        iconLabel.textColor = UIColor(Color.tokyoPurple)
        iconLabel.text = "π"
        iconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconLabel.isUserInteractionEnabled = true

        messageTextView.translatesAutoresizingMaskIntoConstraints = false
        messageTextView.isEditable = false
        messageTextView.isSelectable = true
        messageTextView.isScrollEnabled = false
        messageTextView.backgroundColor = .clear
        messageTextView.textContainerInset = .zero
        messageTextView.textContainer.lineFragmentPadding = 0
        messageTextView.textColor = UIColor(Color.tokyoFg)
        messageTextView.font = .preferredFont(forTextStyle: .body)
        messageTextView.adjustsFontForContentSizeCategory = true

        cursorView.translatesAutoresizingMaskIntoConstraints = false
        cursorView.backgroundColor = UIColor(Color.tokyoPurple)
        cursorView.layer.cornerRadius = 1

        addSubview(iconLabel)
        addSubview(messageTextView)
        addSubview(cursorView)
        iconLabel.addInteraction(UIContextMenuInteraction(delegate: self))

        NSLayoutConstraint.activate([
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconLabel.topAnchor.constraint(equalTo: topAnchor),

            messageTextView.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 8),
            messageTextView.topAnchor.constraint(equalTo: topAnchor),
            messageTextView.trailingAnchor.constraint(equalTo: trailingAnchor),

            cursorView.leadingAnchor.constraint(equalTo: messageTextView.leadingAnchor),
            cursorView.topAnchor.constraint(equalTo: messageTextView.bottomAnchor, constant: 4),
            cursorView.widthAnchor.constraint(equalToConstant: 8),
            cursorView.heightAnchor.constraint(equalToConstant: 14),
            cursorView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func apply(configuration: AssistantTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        iconLabel.textColor = UIColor(palette.purple)
        messageTextView.textColor = UIColor(palette.fg)
        cursorView.backgroundColor = UIColor(palette.purple)

        messageTextView.text = configuration.text

        if configuration.isStreaming {
            cursorView.isHidden = false
            startCursorAnimationIfNeeded()
        } else {
            cursorView.isHidden = true
            cursorView.layer.removeAnimation(forKey: "opacityPulse")
        }
    }

    private func startCursorAnimationIfNeeded() {
        guard cursorView.layer.animation(forKey: "opacityPulse") == nil else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.55
        pulse.toValue = 0.4
        pulse.duration = 1.4
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        cursorView.layer.add(pulse, forKey: "opacityPulse")
    }

    private func copyToPasteboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        UIPasteboard.general.string = trimmed
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred(intensity: 0.82)
    }

}

extension AssistantTimelineRowContentView: UIContextMenuInteractionDelegate {
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
                    UIAction(title: "Copy Full Response", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                        self?.copyToPasteboard(text)
                    }
                )

                actions.append(
                    UIAction(title: "Copy Full Response as Markdown", image: UIImage(systemName: "text.document")) { [weak self] _ in
                        self?.copyToPasteboard(text)
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

