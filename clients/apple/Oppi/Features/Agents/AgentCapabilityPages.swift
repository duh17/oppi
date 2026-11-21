import UIKit

/// One of an Agent's capability pages: "All, including new ones" at the top, then the
/// rows it follows when it is off. A row that opens a page of its own (an MCP server and
/// its tools) keeps its own switch and carries a disclosure beside it. The pages edit the
/// editor's draft, so the editor's Save sends what they chose.
final class AgentCapabilitySelectionViewController: ListScreenController<
    AgentCapabilitySelectionViewController.Section, AgentCapabilitySelectionViewController.Item
> {
    enum Section: Hashable, Sendable { case all, choices, status }
    enum Item: Hashable, Sendable { case all, choice(String), status }

    /// What the page shows and does now: read on every pass, so a change on a pushed
    /// page shows here and a catalog that finishes loading fills the list.
    private let state: () -> AgentCapabilityPage
    private let setAll: (Bool) -> Void
    private let setChosen: (String, Bool) -> Void
    private let open: ((String) -> UIViewController?)?

    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, item in
        self?.configureState(cell, item: item)
    }
    private lazy var choiceRow = UICollectionView.CellRegistration<SettingsSelectionRowCell, Item> { [weak self] cell, _, item in
        self?.configureChoice(cell, item: item)
    }

    /// - Parameters:
    ///   - page: the page as it stands now, asked on every pass.
    ///   - setAll: turns "All, including new ones" on or off.
    ///   - setChosen: chooses or unchoses one row's name.
    ///   - open: the page a row's disclosure opens, pushed from this page.
    init(
        page: @escaping () -> AgentCapabilityPage,
        setAll: @escaping (Bool) -> Void,
        setChosen: @escaping (String, Bool) -> Void,
        open: ((String) -> UIViewController?)? = nil
    ) {
        self.state = page
        self.setAll = setAll
        self.setChosen = setChosen
        self.open = open
        super.init(
            title: state().title,
            listIdentifier: "agent.nativeEdit.\(state().key).list",
            headers: true,
            footers: true
        )
    }

    // MARK: - Page

    override func sections() -> [ListSection<Section, Item>] {
        let snapshot = state()
        // Everything, including what the server adds later: there is no list to show.
        guard !snapshot.allIsOn else {
            return [.init(.all, footer: snapshot.allFooter, items: [.all])]
        }
        var sections: [ListSection<Section, Item>] = [
            .init(.all, footer: snapshot.allFooter, items: [.all])
        ]
        if snapshot.status != nil {
            sections.append(.init(.status, items: [.status]))
        } else if snapshot.choices.isEmpty {
            sections.append(.init(.choices, footer: snapshot.listFooter, items: [.status]))
        } else {
            sections.append(.init(
                .choices,
                footer: snapshot.listFooter,
                items: snapshot.choices.map { .choice($0.name) }
            ))
        }
        return sections
    }

    override func inputs(of item: Item) -> AnyHashable {
        let page = state()
        switch item {
        case .all:
            return AnyHashable([AnyHashable(page.allIsOn), AnyHashable(page.allFooter)])
        case .choice(let name):
            let choice = page.choices.first { $0.name == name }
            return AnyHashable([
                AnyHashable(page.isChosen(name)),
                AnyHashable(choice?.isAvailable ?? false),
                AnyHashable(choice?.status ?? ""),
            ])
        case .status:
            return AnyHashable([AnyHashable(page.status ?? ""), AnyHashable(page.isLoading),
                                AnyHashable(page.emptyMessage)])
        }
    }

    override func prepareRegistrations() {
        _ = (stateRow, choiceRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .all:
            return super.dequeue(item, at: indexPath)
        case .choice:
            return collectionView.dequeueConfiguredReusableCell(using: choiceRow, for: indexPath, item: item)
        case .status:
            return collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        guard item == .all else { return }
        let page = state()
        toggleRow(
            cell,
            title: page.allTitle,
            isOn: page.allIsOn,
            identifier: "agent.nativeEdit.\(page.allKey)",
            isEnabled: page.allFooter == nil
        ) { [weak self] in self?.setAll($0) }
    }

    private func configureChoice(_ cell: SettingsSelectionRowCell, item: Item) {
        guard case .choice(let name) = item, let choice = state().choices.first(where: { $0.name == name }) else {
            return
        }
        let isChosen = state().isChosen(name)
        let identifier = "agent.nativeEdit.\(state().key).\(name)"
        let disclosure = open.map { open in
            SettingsSelectionRowCell.Disclosure(
                identifier: identifier + ".disclosure",
                label: "Its tools"
            ) { [weak self] in
                guard let self, let destination = open(name) else { return }
                Router.push(destination, from: self)
            }
        }
        cell.configure(
            title: choice.title,
            subtitle: choice.subtitle,
            status: choice.status,
            isChosen: isChosen,
            isEnabled: isChosen || choice.isAvailable,
            value: [isChosen ? "Selected" : "Not selected", choice.subtitle]
                .compactMap { $0 }
                .joined(separator: ", "),
            identifier: identifier,
            disclosure: disclosure
        ) { [weak self] in
            guard let self else { return }
            let chosen = state().isChosen(name)
            guard chosen || choice.isAvailable else { return }
            setChosen(name, !chosen)
        }
    }

    private func configureState(_ cell: SettingsStateRowCell, item: Item) {
        guard item == .status else { return }
        let page = state()
        if let status = page.status {
            if page.isLoading {
                cell.configure(.loading(status))
            } else {
                cell.configure(.failure(status, retry: nil))
            }
        } else {
            cell.configure(.message(page.emptyMessage))
        }
    }
}

/// What one capability page shows and does now: read on every pass, so a change on a
/// pushed page shows here and a catalog that finishes loading fills the list.
struct AgentCapabilityPage {
    var title: String
    /// Rows are `agent.nativeEdit.<key>.<name>`; the switch is `agent.nativeEdit.<allKey>`.
    var key: String
    var allKey: String
    var allTitle: String
    var allIsOn: Bool
    /// Why the switch cannot be turned on (a read-only Agent names what it may reach).
    var allFooter: String?
    var listFooter: String?
    var emptyMessage: String
    var choices: [AgentCapabilityChoice] = []
    var isChosen: (String) -> Bool = { _ in false }
    /// The catalog's own state: not loaded yet, failed, or empty.
    var status: String?
    var isLoading = false
}

/// The editor's three capability pages and the tools page an MCP server opens.
@MainActor
enum AgentCapabilityPages {
    /// Why a read-only Agent cannot follow every plugin or MCP server: it would widen
    /// what it may reach by omission.
    static let readOnlyFooter =
        "A read-only Agent names the plugins and MCP servers it may use. Turn on Edit files to follow every one again."

    static func plugins(draft: AgentNativeEditDraft) -> AgentCapabilitySelectionViewController {
        AgentCapabilitySelectionViewController(
            page: {
                AgentCapabilityPage(
                    title: "Plugins",
                    key: "plugin",
                    allKey: "pluginAll",
                    allTitle: "All, including new ones",
                    allIsOn: draft.pluginsAll,
                    allFooter: draft.editsFiles ? nil : readOnlyFooter,
                    listFooter: "Only the plugins chosen here load in this Agent's sessions. A plugin brings its own tools.",
                    emptyMessage: "No Plugins\nThis server has no plugin to choose.",
                    choices: draft.pluginChoices,
                    isChosen: { draft.selectedPlugins.contains($0) },
                    status: draft.pluginCatalogState.statusMessage(for: "Plugins"),
                    isLoading: draft.isLoadingResources
                )
            },
            setAll: { draft.setPluginsAll($0) },
            setChosen: { draft.selectPlugin($0, $1) }
        )
    }

    static func mcpServers(draft: AgentNativeEditDraft) -> AgentCapabilitySelectionViewController {
        AgentCapabilitySelectionViewController(
            page: {
                AgentCapabilityPage(
                    title: "MCP Servers",
                    key: "mcp",
                    allKey: "mcpAll",
                    allTitle: "All, including new ones",
                    allIsOn: draft.mcpAll,
                    allFooter: draft.editsFiles ? nil : readOnlyFooter,
                    listFooter: "This Agent reaches a server through codemode or directly, as the server's exposure says. Each server's tools are chosen beside it.",
                    emptyMessage: "No MCP Servers\nThis server has no MCP server configured.",
                    choices: draft.mcpServerChoices,
                    isChosen: { draft.mcpSelection[$0] != nil },
                    status: draft.mcpCatalogStatus,
                    isLoading: draft.isLoadingMcpServers
                )
            },
            setAll: { draft.setMcpAll($0) },
            setChosen: { draft.selectMcpServer($0, $1) },
            open: { server in Self.mcpTools(draft: draft, server: server) }
        )
    }

    static func mcpTools(
        draft: AgentNativeEditDraft,
        server: String
    ) -> AgentCapabilitySelectionViewController {
        AgentCapabilitySelectionViewController(
            page: {
                AgentCapabilityPage(
                    title: server,
                    key: "mcpTool",
                    allKey: "mcpToolAll",
                    allTitle: "All of this server's tools, including new ones",
                    allIsOn: draft.mcpTools(server) == .all,
                    allFooter: nil,
                    listFooter: "Only the tools chosen here may be called through this server.",
                    emptyMessage: "No Tools\nThis server reports no tools.",
                    choices: draft.mcpToolChoices(server),
                    isChosen: { draft.mcpTools(server)?.toolNames?.contains($0) ?? false }
                )
            },
            setAll: { all in
                // Turning it off freezes the tools the server reports now, so the server stays
                // chosen: an emptied list would drop the server from the Agent instead.
                draft.setMcpTools(
                    server,
                    all ? .all : .tools(draft.mcpToolChoices(server).map(\.name).sorted())
                )
            },
            setChosen: { tool, selected in
                var names = draft.mcpTools(server)?.toolNames ?? []
                if selected {
                    if !names.contains(tool) { names.append(tool) }
                } else {
                    names.removeAll { $0 == tool }
                }
                draft.setMcpTools(server, .tools(names.sorted()))
            }
        )
    }

    static func skills(draft: AgentNativeEditDraft) -> AgentCapabilitySelectionViewController {
        AgentCapabilitySelectionViewController(
            page: {
                AgentCapabilityPage(
                    title: "Skills",
                    key: "skill",
                    allKey: "skillAll",
                    allTitle: "All, including new ones",
                    allIsOn: draft.skillsAll,
                    allFooter: nil,
                    listFooter: "A Skill is chosen by the folder that holds its SKILL.md. Only the Skills chosen here load in this Agent's sessions.",
                    emptyMessage: "No Skills\nThis server has no Skill to choose.",
                    choices: draft.skillChoices,
                    isChosen: { draft.selectedSkills.contains($0) },
                    status: draft.skillCatalogState.statusMessage(for: "Skills"),
                    isLoading: draft.isLoadingResources
                )
            },
            setAll: { draft.setSkillsAll($0) },
            setChosen: { draft.selectSkill($0, $1) }
        )
    }
}
