import UIKit

/// Server Settings → Features: one switch per larger feature, for every device that uses the
/// server (`SettingsCatalog.feature`, `GET|PUT /server/features`). Plain Pi turns every switch
/// off in one save, leaving chat, sessions and files; Turn All On brings every feature back.
/// Each group's footer says what off does: some switches only hide screens.
///
/// Pinned to the server it was made for, as Server Settings' other pages are: its store is that
/// server's, and Server Settings tracks it so a server switch closes it.
@MainActor
final class ServerFeaturesViewController: ListScreenController<ServerFeaturesViewController.Section, ServerFeaturesViewController.Item> {
    enum Section: Hashable, Sendable { case presets, screens, schedules, mcp, terminal, rex, panes }

    enum Item: Hashable, Sendable {
        case feature(ServerFeature)
        case failure(String)
        case plainPi, allOn
    }

    /// The groups in order, with the switches in each.
    private static let groups: [(Section, [ServerFeature])] = [
        (.screens, [.agents, .skills, .extensions]),
        (.schedules, [.schedules]),
        (.mcp, [.mcp]),
        (.terminal, [.terminal, .herdr]),
        (.rex, [.rex]),
        (.panes, [.godotPane, .browserPane]),
    ]

    let server: PairedServer

    init(server: PairedServer, settings: SettingsStore) {
        self.server = server
        super.init(
            title: String(localized: "Features"),
            listIdentifier: "server.features.list",
            scope: .server(server.name),
            settings: settings,
            footers: true
        )
    }

    /// "All On", "Plain Pi", or "3 of 10 On", for Server Settings' Features row. Nil until the
    /// switches have loaded.
    static func summary(_ settings: SettingsStore) -> String? {
        var on = 0
        for feature in ServerFeature.allCases {
            guard let value = settings.read(SettingsCatalog.feature(feature)).current else { return nil }
            if value { on += 1 }
        }
        let all = ServerFeature.allCases.count
        if on == all { return String(localized: "All On") }
        if on == 0 { return String(localized: "Plain Pi") }
        return String(localized: "\(on) of \(all) On")
    }

    /// The presets first, so a phone reaches them without scrolling past every switch.
    override func sections() -> [ListSection<Section, Item>] {
        [ListSection(
            .presets,
            footer: String(localized: "Plain Pi keeps chat, sessions and files, and turns every feature below off."),
            items: [.plainPi, .allOn]
        )] + Self.groups.map { section, features in
            ListSection(
                section,
                footer: footer(section),
                items: features.flatMap { feature in
                    settingRows(SettingsCatalog.feature(feature), .feature(feature)) { .failure($0) }
                }
            )
        }
    }

    private func footer(_ section: Section) -> String? {
        switch section {
        case .screens:
            String(localized: "Hides these screens on every device that uses this server. Sessions still use installed skills and extensions, and schedules can still start a saved Agent.")
        case .schedules:
            String(localized: "Pauses every schedule. Turned back on, each schedule runs at its next time; times missed while it was off are skipped.")
        case .mcp:
            String(localized: "Hides MCP Servers, and new sessions load no MCP tools.")
        case .terminal:
            String(localized: "Hides Terminal in the sidebar, new panes and the chat bar. Herdr runs inside Terminal and needs it. Terminal settings and terminals already open stay on each device.")
        case .rex:
            String(localized: "Hides Rex in the sidebar, new panes and Rex links. Rex terminals already open stay.")
        case .panes:
            String(localized: "Godot Pane hides Godot games in panes; sessions keep their Godot tools. Godot Pane also needs the Experiment on each device. With Web Pages in Panes off, web links open in a sheet.")
        case .presets:
            nil
        }
    }

    /// Herdr is part of Terminal: held off while it is off.
    private var terminalOn: Bool {
        settings?.read(SettingsCatalog.feature(.terminal)).current ?? true
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .feature(.herdr):
            AnyHashable([settingInputs(SettingsCatalog.feature(.herdr)), AnyHashable(terminalOn)])
        case .feature(let feature): settingInputs(SettingsCatalog.feature(feature))
        case .failure(let id): settingFailureInputs(id)
        case .plainPi, .allOn: AnyHashable(ServerFeature.allCases.map { settingInputs(SettingsCatalog.feature($0)) })
        }
    }

    private lazy var presetRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        let on = item == .allOn
        // Offered while some switch is not already where the preset puts it.
        let changes = ServerFeature.allCases.contains { settings?.read(SettingsCatalog.feature($0)).current == !on }
        cell.configure(
            title: on ? String(localized: "Turn All On") : String(localized: "Plain Pi"),
            systemImage: on ? "square.grid.2x2" : "bubble.left",
            identifier: on ? "server.features.allOn" : "server.features.plainPi",
            isEnabled: changes
        ) { [weak self] in self?.setAll(on) }
    }

    override func prepareRegistrations() {
        _ = presetRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .feature: super.dequeue(item, at: indexPath)
        case .failure(let id): dequeueSettingFailure(id, at: indexPath)
        case .plainPi, .allOn: collectionView.dequeueConfiguredReusableCell(using: presetRow, for: indexPath, item: item)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        guard case .feature(let feature) = item else { return }
        let partOfTerminal = feature == .herdr
        settingToggleRow(cell, SettingsCatalog.feature(feature), isEnabled: !partOfTerminal || terminalOn)
        cell.indentationLevel = partOfTerminal ? 1 : 0
    }

    /// Every switch to `on`, in one save.
    private func setAll(_ on: Bool) {
        settings?.set(ServerFeature.allCases.map(SettingsCatalog.feature), to: on)
    }
}
