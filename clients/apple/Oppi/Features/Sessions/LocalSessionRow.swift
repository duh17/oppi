import UIKit

/// Row for a local pi TUI session, visually matching the session row: the
/// identity icon, title and time, then a "Terminal" badge, the model, and the
/// message count. One button element (`localSession.nav.<piSessionId>`) that
/// imports and resumes the session; the collection owns the tap, and
/// accessibility activation runs the same `onImport`.
struct LocalSessionRowConfiguration: UIContentConfiguration {
    let session: LocalSession
    let isEnabled: Bool
    let themeID: ThemeID
    let onImport: () -> Void

    func makeContentView() -> any UIView & UIContentView {
        LocalSessionRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class LocalSessionRowContentView: UIView, UIContentView {
    private let icon = SessionGridBadgeView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let badgeLabel = SessionRowInsetLabel()
    private let providerIcon = UIImageView()
    private let modelLabel = UILabel()
    private let countLabel = UILabel()
    private var applied: LocalSessionRowConfiguration

    var configuration: UIContentConfiguration {
        get { applied }
        set {
            guard let configuration = newValue as? LocalSessionRowConfiguration else { return }
            apply(configuration)
        }
    }

    init(configuration: LocalSessionRowConfiguration) {
        applied = configuration
        super.init(frame: .zero)
        isAccessibilityElement = true

        icon.translatesAutoresizingMaskIntoConstraints = false
        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)

        titleLabel.font = SessionRowText.font(.body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.font = SessionRowText.font(.caption2)
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, SessionRowSpacer(minWidth: 4), timeLabel])
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8

        badgeLabel.text = String(localized: "Terminal")
        badgeLabel.font = SessionRowText.font(.caption2, .medium)
        badgeLabel.insets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        badgeLabel.layer.cornerRadius = 3
        badgeLabel.layer.masksToBounds = true
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        providerIcon.contentMode = .scaleAspectFit
        providerIcon.translatesAutoresizingMaskIntoConstraints = false
        for label in [modelLabel, countLabel] {
            label.font = SessionRowText.font(.caption1)
            label.adjustsFontForContentSizeCategory = true
        }
        modelLabel.lineBreakMode = .byTruncatingMiddle
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let detailRow = UIStackView(arrangedSubviews: [badgeLabel, providerIcon, modelLabel, countLabel, SessionRowSpacer(minWidth: 0)])
        detailRow.alignment = .center
        detailRow.spacing = 6

        let column = UIStackView(arrangedSubviews: [titleRow, detailRow])
        column.axis = .vertical
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconContainer)
        addSubview(column)
        // Same insets as a session row (`SessionListEntryContentView`), plus
        // the row's own 12 pt lead and 2 pt vertical padding.
        directionalLayoutMargins = .zero
        preservesSuperviewLayoutMargins = true
        let margins = layoutMarginsGuide
        let inset = SessionListEntryContentView.verticalInset
        // As tall as the content (see `SessionListEntryContentView`).
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        NSLayoutConstraint.activate([
            hug,
            iconContainer.leadingAnchor.constraint(equalTo: margins.leadingAnchor, constant: 12),
            iconContainer.topAnchor.constraint(equalTo: topAnchor, constant: inset + 3),
            iconContainer.widthAnchor.constraint(equalToConstant: 24),
            iconContainer.heightAnchor.constraint(equalToConstant: 24),
            bottomAnchor.constraint(greaterThanOrEqualTo: iconContainer.bottomAnchor, constant: inset + 2),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            column.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: margins.trailingAnchor, constant: -4),
            column.topAnchor.constraint(equalTo: topAnchor, constant: inset + 2),
            bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: inset + 2),
            providerIcon.widthAnchor.constraint(equalToConstant: 11),
            providerIcon.heightAnchor.constraint(equalToConstant: 11),
        ])
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func apply(_ configuration: LocalSessionRowConfiguration) {
        applied = configuration
        let session = configuration.session
        let style = SessionRowStyle.for(configuration.themeID)
        let colors = style.colors
        icon.configure(sessionId: session.piSessionId, agentId: nil, agentIcon: nil, iconAssetCache: nil)
        titleLabel.text = session.displayTitle
        titleLabel.textColor = colors.fg
        timeLabel.text = session.lastModified.relativeString()
        timeLabel.textColor = colors.comment
        badgeLabel.textColor = colors.comment
        badgeLabel.backgroundColor = colors.comment.withAlphaComponent(0.15)

        let model = SessionModelSummaryBuilder.summaries(primaryModel: session.model).first
        modelLabel.isHidden = model == nil
        providerIcon.isHidden = model?.provider.isEmpty ?? true
        if let model {
            modelLabel.text = model.label
            if !model.provider.isEmpty {
                providerIcon.image = style.providerIcon(model.provider)
            }
        }
        countLabel.isHidden = session.messageCount == 0
        countLabel.text = "\(session.messageCount) msgs"
        for label in [modelLabel, countLabel] { label.textColor = colors.fgDim }

        accessibilityIdentifier = "localSession.nav.\(session.piSessionId)"
        accessibilityTraits = configuration.isEnabled ? .button : [.button, .notEnabled]
        accessibilityLabel = [
            icon.accessibilityLabel, titleLabel.text, timeLabel.text, badgeLabel.text,
            model?.label, countLabel.isHidden ? nil : countLabel.text,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// UI tests also see the row's texts, as they saw the SwiftUI row's.
    override var automationElements: [Any]? {
        get { [titleLabel, timeLabel, badgeLabel, modelLabel, countLabel].filter(\.isShownForAutomation) }
        set { super.automationElements = newValue }
    }

    override func accessibilityActivate() -> Bool {
        guard applied.isEnabled else { return false }
        applied.onImport()
        return true
    }
}

/// A label drawn with padding around its text, for small capsule badges.
class SessionRowInsetLabel: UILabel {
    var insets = UIEdgeInsets.zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
