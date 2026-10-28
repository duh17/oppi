import UIKit

/// A Workspace Settings switch row with a detail line under its name: an
/// extension and where it lives, an MCP server and what it runs. A spinner sits
/// beside the switch while the row's write runs.
///
/// A kit list row (title and secondary text in a content configuration, the
/// controls as trailing accessories), so the row re-measures at any text size
/// and the switch keeps its own size. The cell owns its one switch, as the
/// Skills row does: these switches write Pi's settings (or a sandbox's MCP
/// picks) through `WorkspaceSettingsModel`, which `SettingsCatalog` cannot
/// declare yet (`.piOwned` storage has no adapter). The switch is the row's
/// accessibility element: it carries `identifier`, and its label reads the name
/// and the detail together.
final class WorkspaceToggleRowCell: UICollectionViewListCell {
    struct Row {
        var title: String
        var detail: String
        /// A switched-off or blocked row reads in the value color.
        var dimsTitle = false
        /// The detail is a problem the person can act on.
        var warnsDetail = false
        var monospacedDetail = false
        var isOn: Bool
        var isPending = false
        var isEnabled = true
        var identifier: String
    }

    private let toggle = UISwitch()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var onChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.hidesWhenStopped = true
        spinner.isAccessibilityElement = false
        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onChange?(toggle.isOn)
        }, for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(row: Row, onChange: @escaping (Bool) -> Void) {
        let style = SettingsStyle.current
        var content = SettingsStyle.content(.subtitle)
        content.text = row.title
        content.textProperties.color = row.dimsTitle ? style.value : style.title
        content.textProperties.numberOfLines = 0
        content.secondaryText = row.detail
        content.secondaryTextProperties.color = row.warnsDetail ? style.warning : style.value
        content.secondaryTextProperties.font = row.monospacedDetail ? .scaledMonospaced(.caption2) : .scaled(.caption1)
        content.secondaryTextProperties.numberOfLines = 0
        contentConfiguration = content

        self.onChange = onChange
        toggle.isOn = row.isOn
        toggle.isEnabled = row.isEnabled && !row.isPending
        toggle.accessibilityIdentifier = row.identifier
        toggle.accessibilityLabel = "\(row.title), \(row.detail)"
        spinner.color = style.value
        let switchAccessory = UICellAccessory.customView(configuration: .init(customView: toggle, placement: .trailing()))
        if row.isPending {
            spinner.startAnimating()
            accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing())), switchAccessory]
        } else {
            spinner.stopAnimating()
            accessories = [switchAccessory]
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        toggle.accessibilityIdentifier = nil
        toggle.accessibilityLabel = nil
        spinner.stopAnimating()
    }
}
