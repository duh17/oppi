import SwiftUI
import UIKit

struct CustomTimelineRowConfiguration: UIContentConfiguration {
    let message: String
    let presentation: TraceEventPresentation

    func makeContentView() -> any UIView & UIContentView {
        CustomTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class CustomTimelineRowContentView: UIView, UIContentView, TimelineRowInteractionProvider {
    private let containerView = UIView()
    private let stackView = UIStackView()
    private let headerStack = UIStackView()
    private let iconImageView = UIImageView()
    private let titleStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = CustomTimelinePillLabel()
    private let bodyLabel = UILabel()
    private let fieldsLabel = UILabel()

    private var currentConfiguration: CustomTimelineRowConfiguration
    private var interactionHandlers: TimelineRowInteractionHandlers?

    var copyableText: String? {
        let message = currentConfiguration.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    var interactionFeedbackView: UIView { containerView }

    init(configuration: CustomTimelineRowConfiguration) {
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
            guard let config = newValue as? CustomTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = TimelineBubbleStyle.bubbleCornerRadius
        containerView.layer.borderWidth = 1

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 8

        headerStack.axis = .horizontal
        headerStack.alignment = .top
        headerStack.spacing = 10

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit

        titleStack.axis = .vertical
        titleStack.alignment = .fill
        titleStack.spacing = 2

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2

        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 2

        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.layer.cornerRadius = 8
        statusLabel.layer.masksToBounds = true
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        bodyLabel.font = .preferredFont(forTextStyle: .caption1)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.numberOfLines = 0

        fieldsLabel.font = .preferredFont(forTextStyle: .caption1)
        fieldsLabel.adjustsFontForContentSizeCategory = true
        fieldsLabel.numberOfLines = 0

        addSubview(containerView)
        containerView.addSubview(stackView)

        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(subtitleLabel)
        headerStack.addArrangedSubview(iconImageView)
        headerStack.addArrangedSubview(titleStack)
        headerStack.addArrangedSubview(statusLabel)

        stackView.addArrangedSubview(headerStack)
        stackView.addArrangedSubview(bodyLabel)
        stackView.addArrangedSubview(fieldsLabel)

        interactionHandlers = TimelineRowInteractionInstaller.install(
            on: containerView,
            provider: self
        )

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),

            iconImageView.widthAnchor.constraint(equalToConstant: 17),
            iconImageView.heightAnchor.constraint(equalToConstant: 17),
        ])
    }

    private func apply(configuration: CustomTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = ThemeRuntimeState.currentPalette()
        let accent = accentColor(for: configuration.presentation.accent, palette: palette)

        containerView.backgroundColor = UIColor(palette.bgHighlight).withAlphaComponent(0.55)
        containerView.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.22).cgColor

        iconImageView.image = UIImage(systemName: iconName(for: configuration.presentation.accent))
        iconImageView.tintColor = accent

        titleLabel.textColor = UIColor(palette.fg)
        titleLabel.text = configuration.presentation.title

        let subtitle = configuration.presentation.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        subtitleLabel.textColor = UIColor(palette.fgDim)
        subtitleLabel.text = subtitle

        let status = configuration.presentation.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.isHidden = status?.isEmpty ?? true
        statusLabel.text = status?.lowercased()
        statusLabel.textColor = accent
        statusLabel.backgroundColor = accent.withAlphaComponent(0.16)

        let body = configuration.presentation.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        bodyLabel.isHidden = body?.isEmpty ?? true
        bodyLabel.textColor = UIColor(palette.fg).withAlphaComponent(0.9)
        bodyLabel.text = body

        let fields = formattedFields(configuration.presentation.fields ?? [])
        fieldsLabel.isHidden = fields == nil
        fieldsLabel.textColor = UIColor(palette.fgDim)
        fieldsLabel.attributedText = fields
    }

    private func formattedFields(_ fields: [TraceEventPresentationField]) -> NSAttributedString? {
        let visibleFields = fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !visibleFields.isEmpty else { return nil }

        let palette = ThemeRuntimeState.currentPalette()
        let result = NSMutableAttributedString()
        for (index, field) in visibleFields.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(NSAttributedString(
                string: "\(field.label): ",
                attributes: [
                    .foregroundColor: UIColor(palette.comment),
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                ]
            ))
            result.append(NSAttributedString(
                string: field.value,
                attributes: [
                    .foregroundColor: UIColor(palette.fgDim),
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                ]
            ))
        }
        return result
    }

    private func iconName(for accent: String?) -> String {
        switch accent {
        case "success":
            return "checkmark.circle.fill"
        case "warning":
            return "exclamationmark.triangle.fill"
        case "error":
            return "xmark.circle.fill"
        default:
            return "info.circle.fill"
        }
    }

    private func accentColor(for accent: String?, palette: ThemePalette) -> UIColor {
        switch accent {
        case "success":
            return UIColor(palette.green)
        case "warning":
            return UIColor(palette.orange)
        case "error":
            return UIColor(palette.red)
        default:
            return UIColor(palette.blue)
        }
    }
}

private final class CustomTimelinePillLabel: UILabel {
    var insets = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
}
