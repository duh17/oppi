import UIKit

/// The Agent editor's Allowed Workspaces page: the server's workspaces whose
/// runtime fits the editor's required runtime, plus any already chosen. Each
/// row wears its workspace's icon, with its sandbox mark.
final class AgentWorkspaceSelectionViewController: ListScreenController<
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

    override func sections() -> [ListSection<Section, Item>] {
        let workspaces = displayed
        return [ListSection(
            .workspaces,
            items: workspaces.isEmpty ? [.empty] : workspaces.map { .workspace($0.id) }
        )]
    }

    override func inputs(of item: Item) -> AnyHashable {
        guard case .workspace(let id) = item, let workspace = draft.workspaces.first(where: { $0.id == id }) else {
            return AnyHashable(0)
        }
        // The icon is part of what the row draws: a Genmoji that lands redraws it.
        return AnyHashable([
            AnyHashable(draft.selectedAllowedWorkspaceIds.contains(id)),
            AnyHashable(runtimeMatches(workspace)),
            AnyHashable(EntityIcon.loadGeneration),
        ])
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
            image: EntityIcon.image(
                .workspace(workspace.icon, sandbox: workspace.runtime == .sandbox),
                size: 22,
                assets: draft.connection.iconAssetCache
            ),
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
