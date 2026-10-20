import UIKit

/// Shared header for file review and commit diff details: the file's icon
/// tile, name, Git status pill, parent folder, and line counts.
///
/// Keeps the iPhone/iPad review surfaces visually consistent while callers
/// supply their own source of status and line-count data.
@MainActor
final class ReviewFileSummaryBarView: UIView {
    struct Values: Equatable {
        let path: String
        let status: String
        let statusLabel: String
        let addedLines: Int?
        let removedLines: Int?

        init(path: String, status: String, statusLabel: String? = nil, addedLines: Int?, removedLines: Int?) {
            self.path = path
            self.status = status
            self.statusLabel = statusLabel ?? status
            self.addedLines = addedLines
            self.removedLines = removedLines
        }
    }

    private let iconTile = UIView()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let statusPill = ControlStatusPill()
    private let parentLabel = UILabel()
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private var applied: (values: Values, themeID: ThemeID)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconTile.layer.cornerRadius = 8
        iconTile.layer.cornerCurve = .continuous
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconTile.addSubview(iconView)

        nameLabel.font = UIFont.scaled(.subheadline, .semibold)
        parentLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        parentLabel.lineBreakMode = .byTruncatingMiddle
        let countFont = UIFont.scaled(.caption2, .semibold, monospacedDigits: true)
        for label in [nameLabel, parentLabel, addedLabel, removedLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 1
        }
        addedLabel.font = countFont
        removedLabel.font = countFont
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [nameLabel, statusPill])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8
        let text = UIStackView(arrangedSubviews: [titleRow, parentLabel])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 3
        let counts = UIStackView(arrangedSubviews: [addedLabel, removedLabel])
        counts.axis = .horizontal
        counts.spacing = 8
        counts.setContentHuggingPriority(.required, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [iconTile, text, counts])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.setCustomSpacing(4, after: text)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // The text takes the room the counts leave; the counts stay trailing.
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            iconTile.widthAnchor.constraint(equalToConstant: 26),
            iconTile.heightAnchor.constraint(equalToConstant: 26),
            iconView.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            iconView.widthAnchor.constraint(lessThanOrEqualToConstant: 17),
            iconView.heightAnchor.constraint(lessThanOrEqualToConstant: 17),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ values: Values, themeID: ThemeID) {
        if let applied, applied.values == values, applied.themeID == themeID { return }
        applied = (values, themeID)
        let palette = themeID.palette
        let icon = FileIcon.forPath(values.path)
        let tint = UIColor(icon.tint.snapshotColor)
        iconTile.backgroundColor = tint.withAlphaComponent(0.12)
        iconView.image = icon.uiImage(pointSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        iconView.tintColor = tint
        iconView.contentMode = icon.isAssetImage ? .scaleAspectFit : .center

        nameLabel.text = values.path.lastPathComponentForDisplay
        nameLabel.textColor = UIColor(palette.fg)
        statusPill.apply(
            text: values.statusLabel,
            tone: Self.statusColor(values.status, palette: palette),
            emphasis: .tinted,
            palette: palette
        )
        parentLabel.text = values.path.parentPathForDisplay
        parentLabel.isHidden = values.path.parentPathForDisplay == nil
        parentLabel.textColor = UIColor(palette.comment)

        let added = values.addedLines ?? 0
        let removed = values.removedLines ?? 0
        addedLabel.text = "+\(added)"
        addedLabel.textColor = UIColor(palette.toolDiffAdded)
        addedLabel.isHidden = added <= 0
        removedLabel.text = "-\(removed)"
        removedLabel.textColor = UIColor(palette.toolDiffRemoved)
        removedLabel.isHidden = removed <= 0
    }

    /// A Git status code's pill color, from the theme.
    private static func statusColor(_ status: String, palette: ThemePalette) -> UIColor {
        switch status.trimmingCharacters(in: .whitespaces) {
        case "M": UIColor(palette.orange)
        case "A": UIColor(palette.green)
        case "D", "UU", "AA", "DD": UIColor(palette.red)
        case "R", "C": UIColor(palette.cyan)
        default: UIColor(palette.comment)
        }
    }
}
