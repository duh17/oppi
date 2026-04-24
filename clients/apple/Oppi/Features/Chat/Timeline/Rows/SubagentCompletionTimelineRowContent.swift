import SwiftUI
import UIKit

struct SubagentCompletionTimelineRowConfiguration: UIContentConfiguration {
    let presentation: SubagentCompletionPresentation
    let rawMessage: String

    func makeContentView() -> any UIView & UIContentView {
        SubagentCompletionTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

struct SubagentCompletionPresentation: Equatable {
    let agentName: String
    let agentId: String
    let status: String
    let meta: String?
    let warning: String?
    let changesSummary: String?
    let changedFiles: [String]
    let lastResponse: String?

    static func parse(from rawMessage: String) -> SubagentCompletionPresentation? {
        let normalized = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("Agent \"") else { return nil }

        let lines = normalized.components(separatedBy: .newlines)
        guard let header = lines.first,
              let nameStart = header.firstIndex(of: "\"") else { return nil }

        let afterNameStart = header.index(after: nameStart)
        guard let nameEnd = header[afterNameStart...].firstIndex(of: "\"") else { return nil }
        let agentName = String(header[afterNameStart..<nameEnd])

        guard let idOpen = header[nameEnd...].firstIndex(of: "("),
              let idClose = header[idOpen...].firstIndex(of: ")") else { return nil }
        let agentId = String(header[header.index(after: idOpen)..<idClose])

        let statusMarker = "finished:"
        guard let statusRange = header.range(of: statusMarker) else { return nil }
        let status = header[statusRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var meta: String?
        var warning: String?
        var changesSummary: String?
        var changedFiles: [String] = []
        var responseLines: [String] = []
        var isInLastResponse = false

        for (index, line) in lines.dropFirst().enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if isInLastResponse {
                responseLines.append(line)
                continue
            }

            if trimmed == "Last response:" || trimmed == "Last message:" {
                isInLastResponse = true
                continue
            }

            if trimmed.isEmpty { continue }

            if index == 0 {
                meta = trimmed
            } else if trimmed.hasPrefix("WARNING:") {
                warning = String(trimmed.dropFirst("WARNING:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("Changes:") {
                changesSummary = trimmed
            } else if line.hasPrefix("  ") {
                changedFiles.append(trimmed)
            }
        }

        let lastResponse = responseLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SubagentCompletionPresentation(
            agentName: agentName,
            agentId: agentId,
            status: status.isEmpty ? "UNKNOWN" : status,
            meta: meta,
            warning: warning,
            changesSummary: changesSummary,
            changedFiles: changedFiles,
            lastResponse: lastResponse.isEmpty ? nil : lastResponse
        )
    }
}

final class SubagentCompletionTimelineRowContentView: UIView, UIContentView, TimelineRowInteractionProvider {
    private let containerView = UIView()
    private let headerStack = UIStackView()
    private let iconImageView = UIImageView()
    private let titleStack = UIStackView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let badgeLabel = PaddingLabel()
    private let warningLabel = UILabel()
    private let changesLabel = UILabel()
    private let responseContainer = UIView()
    private let responseTitleLabel = UILabel()
    private let responseLabel = UILabel()

    private var currentConfiguration: SubagentCompletionTimelineRowConfiguration
    private var interactionHandlers: TimelineRowInteractionHandlers?

    var copyableText: String? { currentConfiguration.rawMessage }
    var interactionFeedbackView: UIView { containerView }

    init(configuration: SubagentCompletionTimelineRowConfiguration) {
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
            guard let config = newValue as? SubagentCompletionTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = TimelineBubbleStyle.bubbleCornerRadius
        containerView.layer.borderWidth = 1

        let mainStack = UIStackView()
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.alignment = .fill
        mainStack.spacing = 10

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

        metaLabel.font = .preferredFont(forTextStyle: .caption1)
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.numberOfLines = 2

        badgeLabel.font = .preferredFont(forTextStyle: .caption2)
        badgeLabel.adjustsFontForContentSizeCategory = true
        badgeLabel.layer.cornerRadius = 8
        badgeLabel.layer.masksToBounds = true
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        warningLabel.font = .preferredFont(forTextStyle: .caption1)
        warningLabel.adjustsFontForContentSizeCategory = true
        warningLabel.numberOfLines = 0

        changesLabel.font = .preferredFont(forTextStyle: .caption1)
        changesLabel.adjustsFontForContentSizeCategory = true
        changesLabel.numberOfLines = 0

        responseContainer.layer.cornerRadius = 10
        responseContainer.layer.masksToBounds = true

        let responseStack = UIStackView()
        responseStack.translatesAutoresizingMaskIntoConstraints = false
        responseStack.axis = .vertical
        responseStack.alignment = .fill
        responseStack.spacing = 5

        responseTitleLabel.font = .preferredFont(forTextStyle: .caption2)
        responseTitleLabel.adjustsFontForContentSizeCategory = true
        responseTitleLabel.text = "Last response preview"

        responseLabel.font = .preferredFont(forTextStyle: .caption1)
        responseLabel.adjustsFontForContentSizeCategory = true
        responseLabel.numberOfLines = 14
        responseLabel.lineBreakMode = .byTruncatingTail

        addSubview(containerView)
        containerView.addSubview(mainStack)

        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(metaLabel)
        headerStack.addArrangedSubview(iconImageView)
        headerStack.addArrangedSubview(titleStack)
        headerStack.addArrangedSubview(badgeLabel)

        responseContainer.addSubview(responseStack)
        responseStack.addArrangedSubview(responseTitleLabel)
        responseStack.addArrangedSubview(responseLabel)

        mainStack.addArrangedSubview(headerStack)
        mainStack.addArrangedSubview(warningLabel)
        mainStack.addArrangedSubview(changesLabel)
        mainStack.addArrangedSubview(responseContainer)

        interactionHandlers = TimelineRowInteractionInstaller.install(
            on: containerView,
            provider: self
        )

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            mainStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            mainStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            mainStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            mainStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),

            iconImageView.widthAnchor.constraint(equalToConstant: 17),
            iconImageView.heightAnchor.constraint(equalToConstant: 17),

            responseStack.leadingAnchor.constraint(equalTo: responseContainer.leadingAnchor, constant: 10),
            responseStack.trailingAnchor.constraint(equalTo: responseContainer.trailingAnchor, constant: -10),
            responseStack.topAnchor.constraint(equalTo: responseContainer.topAnchor, constant: 8),
            responseStack.bottomAnchor.constraint(equalTo: responseContainer.bottomAnchor, constant: -8),
        ])
    }

    private func apply(configuration: SubagentCompletionTimelineRowConfiguration) {
        currentConfiguration = configuration

        let presentation = configuration.presentation
        let palette = ThemeRuntimeState.currentPalette()
        let accent = statusColor(for: presentation.status, palette: palette)

        containerView.backgroundColor = UIColor(palette.bgHighlight).withAlphaComponent(0.55)
        containerView.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.22).cgColor

        iconImageView.image = UIImage(systemName: statusIconName(for: presentation.status))
        iconImageView.tintColor = accent

        titleLabel.textColor = UIColor(palette.fg)
        titleLabel.text = "Subagent complete: \(presentation.agentName)"

        let shortId = String(presentation.agentId.prefix(8))
        metaLabel.textColor = UIColor(palette.fgDim)
        metaLabel.text = [presentation.meta, "id \(shortId)"].compactMap { $0 }.joined(separator: " · ")

        badgeLabel.text = presentation.status.lowercased()
        badgeLabel.textColor = accent
        badgeLabel.backgroundColor = accent.withAlphaComponent(0.16)

        if let warning = presentation.warning, !warning.isEmpty {
            warningLabel.isHidden = false
            warningLabel.textColor = UIColor(palette.orange)
            warningLabel.text = "Warning: \(warning)"
        } else {
            warningLabel.isHidden = true
            warningLabel.text = nil
        }

        if let changesText = formattedChangesText(presentation) {
            changesLabel.isHidden = false
            changesLabel.textColor = UIColor(palette.fgDim)
            changesLabel.text = changesText
        } else {
            changesLabel.isHidden = true
            changesLabel.text = nil
        }

        if let response = presentation.lastResponse, !response.isEmpty {
            responseContainer.isHidden = false
            responseContainer.backgroundColor = UIColor(palette.bgDark).withAlphaComponent(0.65)
            responseTitleLabel.textColor = UIColor(palette.comment)
            responseLabel.textColor = UIColor(palette.fg).withAlphaComponent(0.9)
            responseLabel.text = responsePreview(response)
        } else {
            responseContainer.isHidden = true
            responseLabel.text = nil
        }
    }

    private func formattedChangesText(_ presentation: SubagentCompletionPresentation) -> String? {
        var lines: [String] = []
        if let changesSummary = presentation.changesSummary {
            lines.append(changesSummary)
        }
        lines.append(contentsOf: presentation.changedFiles.prefix(5).map { "• \($0)" })
        if presentation.changedFiles.count > 5 {
            lines.append("• … and \(presentation.changedFiles.count - 5) more")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func responsePreview(_ response: String) -> String {
        let lines = response.components(separatedBy: .newlines)
        let visibleLines = lines.prefix(14)
        var preview = visibleLines.joined(separator: "\n")
        if lines.count > visibleLines.count {
            preview += "\n…"
        }
        return preview
    }

    private func statusIconName(for status: String) -> String {
        switch status.lowercased() {
        case "error":
            return "xmark.circle.fill"
        case "unknown":
            return "questionmark.circle.fill"
        default:
            return "checkmark.circle.fill"
        }
    }

    private func statusColor(for status: String, palette: ThemePalette) -> UIColor {
        switch status.lowercased() {
        case "error":
            return UIColor(palette.red)
        case "unknown":
            return UIColor(palette.comment)
        default:
            return UIColor(palette.green)
        }
    }
}

private final class PaddingLabel: UILabel {
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
