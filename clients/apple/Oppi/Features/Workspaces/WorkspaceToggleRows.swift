import UIKit

/// A Workspace Settings switch row with a detail line under its name: an
/// extension and where it lives, an MCP server and what it runs. A spinner sits
/// beside the switch while the row's write runs.
struct WorkspaceToggleRow {
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

extension SettingsListViewController {
    /// The kit's switch row (`toggleRow`) with a detail line: a `.subtitle`
    /// content configuration over the kit's switch, and the spinner while a
    /// write runs. These switches write Pi's settings (or a sandbox's MCP picks)
    /// through `WorkspaceSettingsModel`, which `SettingsCatalog` cannot declare
    /// yet (`.piOwned` storage has no adapter), so they use `toggleRow` rather
    /// than `settingToggleRow`.
    func detailToggleRow(_ cell: UICollectionViewListCell, row: WorkspaceToggleRow, onChange: @escaping (Bool) -> Void) {
        toggleRow(
            cell,
            title: row.title,
            isOn: row.isOn,
            identifier: row.identifier,
            isEnabled: row.isEnabled && !row.isPending,
            onChange: onChange
        )
        let style = SettingsStyle.current
        var content = content(.subtitle)
        content.text = row.title
        content.textProperties.color = row.dimsTitle ? style.value : style.title
        content.textProperties.numberOfLines = 0
        content.secondaryText = row.detail
        content.secondaryTextProperties.color = row.warnsDetail ? style.warning : style.value
        content.secondaryTextProperties.font = row.monospacedDetail ? .scaledMonospaced(.caption2) : .scaled(.caption1)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        if row.isPending {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = style.value
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))] + cell.accessories
        }
    }
}
