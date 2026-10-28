import UIKit

/// The Agent editor's pages that choose Skills or Extensions from the server's
/// catalog. Each row is one selection row; saved selections the server no
/// longer lists stay in their own section so they can be deselected. Edits go
/// to the editor's draft, so the editor's Save sends them.
final class AgentResourceSelectionViewController: SettingsListViewController<
    AgentResourceSelectionViewController.Section, AgentResourceSelectionViewController.Item
> {
    enum Kind {
        case skills, extensions

        /// The plural name the catalog and the copy use.
        var resourceName: String { self == .skills ? "Skills" : "Extensions" }
        var title: String { "Agent \(resourceName)" }
        /// The part of a row's identifier that names the kind.
        var identifierKind: String { self == .skills ? "skill" : "extension" }
    }

    enum Section: Hashable, Sendable { case status, empty, discovered, unavailable }
    enum Item: Hashable, Sendable { case status, empty, resource(String), unavailable(String) }

    private struct Row {
        let id: String
        let title: String
        let subtitle: String
        let status: String?
        let canAdd: Bool
    }

    private let kind: Kind
    private let draft: AgentNativeEditDraft
    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .status:
            if draft.catalogState(kind) == .loading {
                cell.configure(.loading("Loading \(kind.resourceName)\u{2026}"))
            } else {
                cell.configure(.failure(statusTitle(draft.catalogState(kind)), retry: nil))
            }
        default:
            cell.configure(.message(emptyMessage() ?? ""))
        }
    }
    private lazy var resourceRow = UICollectionView.CellRegistration<SettingsSelectionRowCell, Item> { [weak self] cell, _, item in
        self?.configureResource(cell, item: item)
    }

    init(kind: Kind, draft: AgentNativeEditDraft) {
        self.kind = kind
        self.draft = draft
        super.init(
            title: kind.title,
            listIdentifier: "agent.nativeEdit.\(kind.identifierKind)s.list",
            scope: .server(draft.serverName),
            headers: true,
            footers: true
        )
    }

    // MARK: - Data

    private var selected: Set<String> {
        get { kind == .skills ? draft.selectedSkillPaths : draft.selectedExtensionIds }
        set {
            if kind == .skills { draft.selectedSkillPaths = newValue } else { draft.selectedExtensionIds = newValue }
        }
    }

    private var discovered: [Row] {
        switch kind {
        case .skills:
            return draft.availableSkills.compactMap { skill in
                guard let path = skill.path else { return nil }
                return Row(
                    id: path,
                    title: skill.name,
                    subtitle: skill.description,
                    status: skill.state == .error
                        ? (skill.loadError ?? "Cannot load")
                        : skill.state == .disabled ? "Disabled by default \u{00B7} selectable for this Agent" : nil,
                    canAdd: skill.state != .error
                )
            }
        case .extensions:
            return draft.availableExtensions.map { resource in
                Row(
                    id: resource.id,
                    title: resource.name,
                    subtitle: resource.description ?? resource.provenance.label,
                    status: resource.state == .error
                        ? (resource.loadError ?? "Cannot load")
                        : resource.state == .off ? "Off by default \u{00B7} selectable for this Agent" : nil,
                    canAdd: resource.state != .error
                )
            }
        }
    }

    /// Saved selections the catalog no longer lists.
    private func unavailableIds(discovered: [Row]) -> [String] {
        selected.subtracting(discovered.map(\.id)).sorted()
    }

    private func emptyMessage() -> String? {
        let rows = discovered
        guard rows.isEmpty, unavailableIds(discovered: rows).isEmpty else { return nil }
        switch (kind, draft.catalogState(kind)) {
        case (.skills, .empty): return "No Skills Found\nThis server has no selectable Skills."
        case (.skills, .content): return "No Selectable Skills\nThe loaded Skills catalog has no selectable paths."
        case (.extensions, .empty): return "No Extensions Found\nThis server has no selectable Extensions."
        default: return nil
        }
    }

    private func statusTitle(_ state: AgentResourceCatalogState) -> String {
        switch state {
        case .neverLoaded: "\(kind.resourceName) catalog has not loaded"
        case .failed: "\(kind.resourceName) unavailable"
        case .cachedOffline: "Showing cached \(kind.resourceName)"
        case .unavailable: "\(kind.resourceName) unavailable offline"
        case .loading, .empty, .content: ""
        }
    }

    private func statusFooter(_ state: AgentResourceCatalogState) -> String? {
        switch state {
        case .neverLoaded: "Reconnect or retry before choosing a new exact selection."
        case .failed: "Existing selections are preserved. Retry before choosing new \(kind.resourceName)."
        case .unavailable: "Existing selections are preserved, and unavailable selections can still be removed."
        case .loading, .cachedOffline, .empty, .content: nil
        }
    }

    // MARK: - Page

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        let state = draft.catalogState(kind)
        let rows = discovered
        let unavailable = unavailableIds(discovered: rows)
        var sections: [SettingsSectionModel<Section, Item>] = []
        switch state {
        case .empty, .content:
            break
        case .loading, .neverLoaded, .failed, .cachedOffline, .unavailable:
            sections.append(.init(.status, footer: statusFooter(state), items: [.status]))
        }
        if emptyMessage() != nil {
            sections.append(.init(.empty, items: [.empty]))
        }
        if !rows.isEmpty {
            sections.append(.init(
                .discovered,
                header: "Discovered \(kind.resourceName)",
                items: rows.map { .resource($0.id) }
            ))
        }
        if !unavailable.isEmpty {
            sections.append(.init(
                .unavailable,
                header: "Unavailable Selections",
                footer: kind == .skills
                    ? "Deselect these paths before saving, or restore them on the server."
                    : "Deselect these identifiers before saving, or restore them on the server.",
                items: unavailable.map { .unavailable($0) }
            ))
        }
        return sections
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .status: AnyHashable(String(describing: draft.catalogState(kind)))
        case .empty: AnyHashable(emptyMessage() ?? "")
        case .resource(let id), .unavailable(let id): AnyHashable([selected.contains(id)])
        }
    }

    override func prepareRegistrations() {
        _ = (stateRow, resourceRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .status, .empty: collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        case .resource, .unavailable: collectionView.dequeueConfiguredReusableCell(using: resourceRow, for: indexPath, item: item)
        }
    }

    private func configureResource(_ cell: SettingsSelectionRowCell, item: Item) {
        let row: Row
        switch item {
        case .resource(let id):
            guard let found = discovered.first(where: { $0.id == id }) else { return }
            row = found
        case .unavailable(let id):
            row = Row(id: id, title: id, subtitle: "No longer discovered on this server", status: "Unavailable", canAdd: false)
        default:
            return
        }
        let isChosen = selected.contains(row.id)
        cell.configure(
            title: row.title,
            subtitle: row.subtitle,
            status: row.status,
            isChosen: isChosen,
            isEnabled: isChosen || row.canAdd,
            value: [isChosen ? "Selected" : "Not selected", row.status].compactMap { $0 }.joined(separator: ", "),
            identifier: "agent.nativeEdit.\(kind.identifierKind).\(row.id)"
        ) { [weak self] in
            guard let self else { return }
            var ids = selected
            if ids.contains(row.id) {
                ids.remove(row.id)
            } else if row.canAdd {
                ids.insert(row.id)
            } else {
                return
            }
            selected = ids
        }
    }
}

private extension AgentNativeEditDraft {
    func catalogState(_ kind: AgentResourceSelectionViewController.Kind) -> AgentResourceCatalogState {
        kind == .skills ? skillCatalogState : extensionCatalogState
    }
}

/// The Agent editor's Allowed Workspaces page: the server's workspaces whose
/// runtime fits the editor's required runtime, plus any already chosen.
final class AgentWorkspaceSelectionViewController: SettingsListViewController<
    AgentWorkspaceSelectionViewController.Section, AgentWorkspaceSelectionViewController.Item
> {
    enum Section: Hashable, Sendable { case workspaces }
    enum Item: Hashable, Sendable { case empty, workspace(String) }

    private let draft: AgentNativeEditDraft
    private lazy var emptyRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { cell, _, _ in
        cell.configure(.message(
            "No Compatible Workspace\nAdd a workspace that matches the required runtime, or choose Any runtime."
        ))
    }
    private lazy var workspaceRow = UICollectionView.CellRegistration<SettingsSelectionRowCell, Item> { [weak self] cell, _, item in
        self?.configureWorkspace(cell, item: item)
    }

    init(draft: AgentNativeEditDraft) {
        self.draft = draft
        super.init(
            title: "Allowed Workspaces",
            listIdentifier: "agent.nativeEdit.workspaces.list",
            scope: .server(draft.serverName)
        )
    }

    private var displayed: [Workspace] {
        draft.workspaces.filter { draft.selectedAllowedWorkspaceIds.contains($0.id) || runtimeMatches($0) }
    }

    private func runtimeMatches(_ workspace: Workspace) -> Bool {
        draft.requiredRuntime.map { $0 == (workspace.runtime ?? .host) } ?? true
    }

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        let workspaces = displayed
        return [SettingsSectionModel(
            .workspaces,
            items: workspaces.isEmpty ? [.empty] : workspaces.map { .workspace($0.id) }
        )]
    }

    override func inputs(of item: Item) -> AnyHashable {
        guard case .workspace(let id) = item, let workspace = draft.workspaces.first(where: { $0.id == id }) else {
            return AnyHashable(0)
        }
        return AnyHashable([draft.selectedAllowedWorkspaceIds.contains(id), runtimeMatches(workspace)])
    }

    override func prepareRegistrations() {
        _ = (emptyRow, workspaceRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .empty: collectionView.dequeueConfiguredReusableCell(using: emptyRow, for: indexPath, item: item)
        case .workspace: collectionView.dequeueConfiguredReusableCell(using: workspaceRow, for: indexPath, item: item)
        }
    }

    private func configureWorkspace(_ cell: SettingsSelectionRowCell, item: Item) {
        guard case .workspace(let id) = item, let workspace = draft.workspaces.first(where: { $0.id == id }) else { return }
        let isChosen = draft.selectedAllowedWorkspaceIds.contains(id)
        let matches = runtimeMatches(workspace)
        let runtime = (workspace.runtime ?? .host).rawValue.capitalized
        let summary = matches ? runtime : "\(runtime) \u{00B7} Does not match required runtime"
        cell.configure(
            title: workspace.name,
            subtitle: summary,
            subtitleIsWarning: !matches,
            isChosen: isChosen,
            value: isChosen ? "Selected" : "Not selected",
            identifier: "agent.nativeEdit.workspace.\(id)"
        ) { [weak self] in
            guard let self else { return }
            if draft.selectedAllowedWorkspaceIds.contains(id) {
                draft.selectedAllowedWorkspaceIds.remove(id)
            } else {
                draft.selectedAllowedWorkspaceIds.insert(id)
            }
        }
    }
}
