import SwiftUI
import UIKit

struct CustomTimelineRowConfiguration: UIContentConfiguration {
    let message: String
    let presentation: TraceEventPresentation
    let isExpanded: Bool
    let bodyWidth: CGFloat
    var openFullScreen: ((ChatReaderPayload) -> Void)?
    var onToggleExpand: (() -> Void)?

    var canExpand: Bool {
        guard let body = presentation.body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else { return false }
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let height = (body as NSString).boundingRect(
            with: CGSize(width: max(1, bodyWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
        return height > font.lineHeight * 2 + 1
    }

    func makeContentView() -> any UIView & UIContentView {
        CustomTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class CustomTimelineRowContentView: UIView, UIContentView, TimelineRowInteractionProvider, UIGestureRecognizerDelegate {
    private let containerView = UIView()
    private let stackView = UIStackView()
    private let headerStack = UIStackView()
    private let iconImageView = UIImageView()
    private let titleStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = CustomTimelinePillLabel()
    private let bodyLabel = UILabel()
    private let bashBodyView = BashToolRowView()
    private let terminalHitControl = UIButton(type: .custom)
    private let fieldsLabel = UILabel()

    private var currentConfiguration: CustomTimelineRowConfiguration
    private var contextMenuHandler: TimelineRowContextMenuHandler?
    private lazy var cardTap = UITapGestureRecognizer(target: self, action: #selector(toggleExpand))

    var copyableText: String? {
        let message = currentConfiguration.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    var additionalMenuActions: [UIAction] {
        guard currentConfiguration.canExpand,
              let body = currentConfiguration.presentation.body?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else { return [] }
        return [
            UIAction(
                title: String(localized: "Open Full Screen"),
                image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
            ) { [weak self] _ in
                self?.openBodyFullScreen()
            }
        ]
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
        bodyLabel.numberOfLines = 2
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.accessibilityIdentifier = "custom.preview"
        terminalHitControl.translatesAutoresizingMaskIntoConstraints = false
        terminalHitControl.accessibilityIdentifier = "custom.terminal"
        terminalHitControl.accessibilityLabel = String(localized: "Command output")
        terminalHitControl.addTarget(self, action: #selector(openBodyFullScreen), for: .touchUpInside)
        cardTap.delegate = self
        containerView.addGestureRecognizer(cardTap)

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
        stackView.addArrangedSubview(bashBodyView)
        stackView.addArrangedSubview(fieldsLabel)
        bashBodyView.addSubview(terminalHitControl)

        let handler = TimelineRowContextMenuHandler()
        handler.provider = self
        containerView.addInteraction(UIContextMenuInteraction(delegate: handler))
        contextMenuHandler = handler

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),

            terminalHitControl.leadingAnchor.constraint(equalTo: bashBodyView.leadingAnchor),
            terminalHitControl.trailingAnchor.constraint(equalTo: bashBodyView.trailingAnchor),
            terminalHitControl.topAnchor.constraint(equalTo: bashBodyView.topAnchor),
            terminalHitControl.bottomAnchor.constraint(equalTo: bashBodyView.bottomAnchor),

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
        let showTerminal = configuration.canExpand && configuration.isExpanded
        bodyLabel.isHidden = body?.isEmpty ?? true || showTerminal
        bodyLabel.textColor = UIColor(palette.fg).withAlphaComponent(0.9)
        bodyLabel.text = body
        bashBodyView.isHidden = !showTerminal
        terminalHitControl.isHidden = !showTerminal
        if showTerminal, let body {
            bashBodyView.outputShouldAutoFollow = false
            bashBodyView.applyTheme(palette)
            let result = bashBodyView.apply(
                input: BashRenderInput(command: nil, output: body, unwrapped: false,
                                       isError: false, isStreaming: false),
                outputColor: UIColor(palette.fg),
                wasOutputVisible: false
            )
            bashBodyView.outputContainer.isHidden = !result.showOutput
            bashBodyView.outputLabel.isUserInteractionEnabled = false
            bashBodyView.outputScrollView.isScrollEnabled = true
            bashBodyView.outputScrollView.delaysContentTouches = false
            let mode = ToolRowViewportCalculator.ViewportMode.output
            let geometry = ToolRowViewportCalculator.GeometryContext(
                windowHeight: window?.bounds.height ?? bounds.height,
                safeAreaInsets: safeAreaInsets,
                cellWidth: configuration.bodyWidth + 12
            )
            bashBodyView.outputViewportHeightConstraint?.constant = ToolRowViewportCalculator.preferredViewportHeight(
                for: bashBodyView.outputLabel,
                in: bashBodyView.outputContainer,
                mode: mode,
                expandedScrollView: nil,
                expandedLabelWidthConstraint: nil,
                outputScrollView: bashBodyView.outputScrollView,
                outputUsesUnwrappedLayout: false,
                outputLabelWidthConstraint: bashBodyView.outputLabelWidthConstraint,
                geometry: geometry
            )
        } else {
            bashBodyView.resetOutputState(outputColor: UIColor(palette.fg))
        }
        if showTerminal {
            bashBodyView.bringSubviewToFront(terminalHitControl)
        }

        let fields = formattedFields(configuration.presentation.fields ?? [])
        fieldsLabel.isHidden = fields == nil
        fieldsLabel.textColor = UIColor(palette.fgDim)
        fieldsLabel.attributedText = fields
    }

    @objc private func toggleExpand() {
        guard currentConfiguration.canExpand else { return }
        currentConfiguration.onToggleExpand?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === cardTap else { return true }
        guard currentConfiguration.canExpand else { return false }
        var current = touch.view
        while let candidate = current {
            if candidate === bashBodyView
                || candidate === terminalHitControl
                || candidate === bashBodyView.outputContainer {
                return false
            }
            current = candidate.superview
        }
        return true
    }

    @objc private func openBodyFullScreen() {
        guard let body = currentConfiguration.presentation.body?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else { return }
        let content = FullScreenCodeContent.terminal(content: body, command: nil)
        let payload = ChatReaderPayload(content: content)
        if let openFullScreen = currentConfiguration.openFullScreen {
            openFullScreen(payload)
            return
        }
        if ChatReaderOpenLookup.open(payload, from: self) {
            return
        }
        ToolTimelineRowPresentationHelpers.presentFullScreenContent(content, from: self)
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
