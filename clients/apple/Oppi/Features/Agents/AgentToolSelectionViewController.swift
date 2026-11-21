import UIKit

/// Where a tool-selection page reads its choice and writes it back: Pi's own
/// defaults, which save each change at once. The page re-reads `state` on every
/// pass, so whatever observable model the closures read redraws it.
@MainActor
struct AgentToolSelection {
    struct State {
        var mode: AgentToolSelectionMode
        var selectedNames: Set<String>
        var builtInTools: [ServerToolSummary]
        var defaultSelection: Set<String>
        /// Tools Pi extensions register off. Shown in every mode when there are any.
        var optionalTools: [ServerToolSummary]
        var selectedOptionalNames: Set<String>
    }

    var title: String
    var inheritFooter: String
    var exactFooter: String
    var optionalToolsFooter: String
    var serverName: String
    var state: () -> State
    var setMode: (AgentToolSelectionMode) -> Void
    var setSelectedNames: (Set<String>) -> Void
    var setSelectedOptionalNames: (Set<String>) -> Void
    /// Runs when the page leaves the stack.
    var didClose: () -> Void

    /// Pi's default tools: every change saves at once (`PiToolsEditor`), and
    /// closing the page saves the selection it leaves with.
    static func pi(_ tools: PiToolsEditor, serverName: String) -> Self {
        Self(
            title: "Pi Tools",
            inheritFooter: AgentManagementPresentation.piToolsInheritFooter,
            exactFooter: AgentManagementPresentation.piToolsExactFooter,
            optionalToolsFooter: AgentManagementPresentation.piOptionalToolsFooter,
            serverName: serverName,
            state: {
                State(
                    mode: tools.mode,
                    selectedNames: tools.selectedNames,
                    builtInTools: tools.builtInTools,
                    defaultSelection: tools.defaultBuiltInSelection,
                    optionalTools: tools.optionalTools,
                    selectedOptionalNames: tools.selectedOptionalNames
                )
            },
            setMode: { tools.mode = $0 },
            setSelectedNames: { tools.selectedNames = $0 },
            setSelectedOptionalNames: { tools.selectedOptionalNames = $0 },
            didClose: { tools.pickerDidClose() }
        )
    }
}

/// The page that picks which tools Pi starts sessions with: Pi defaults, or an
/// exact list of built-in tools, plus the optional tools Pi extensions register
/// off. A pushed page of Pi's own entry, whose edits save as they are made.
/// Selecting "Choose tools" starts the list from the defaults.
final class AgentToolSelectionViewController: ListScreenController<
    AgentToolSelectionViewController.Section, AgentToolSelectionViewController.Item
> {
    enum Section: Hashable, Sendable {
        case mode, builtIn, builtInMissing, optional
    }
    enum Item: Hashable, Sendable {
        case mode, missingCatalog
        case builtIn(String)
        case optional(String)
    }

    private let selection: AgentToolSelection
    private var menuHadTools: Bool?
    private lazy var modeRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, _ in
        self?.configureMode(cell)
    }
    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { cell, _, _ in
        cell.configure(.failure("Built-in tool catalog unavailable", retry: nil), identifier: "agent.nativeEdit.toolCatalog")
    }
    private lazy var toolRow = UICollectionView.CellRegistration<SettingsSelectionRowCell, Item> { [weak self] cell, _, item in
        self?.configureTool(cell, item: item)
    }
    private lazy var selectionActionsItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"))
        item.accessibilityLabel = "Tool selection actions"
        item.accessibilityIdentifier = "agent.nativeEdit.toolActions"
        return item
    }()

    init(selection: AgentToolSelection) {
        self.selection = selection
        super.init(
            title: selection.title,
            listIdentifier: "agent.nativeEdit.tools.list",
            scope: .server(selection.serverName),
            headers: true,
            footers: true
        )
    }

    // MARK: - Page

    override func sections() -> [ListSection<Section, Item>] {
        let state = selection.state()
        var sections = [ListSection<Section, Item>(.mode, footer: modeFooter(state), items: [.mode])]
        if state.mode == .exact {
            if state.builtInTools.isEmpty {
                sections.append(.init(
                    .builtInMissing,
                    footer: "Reconnect to a current server before creating a new exact selection.",
                    items: [.missingCatalog]
                ))
            } else {
                sections.append(.init(.builtIn, header: "Built-in Pi Tools", items: state.builtInTools.map { .builtIn($0.name) }))
            }
        }
        if !state.optionalTools.isEmpty {
            sections.append(.init(
                .optional,
                header: "Optional Pi Tools",
                footer: selection.optionalToolsFooter,
                items: state.optionalTools.map { .optional($0.name) }
            ))
        }
        return sections
    }

    private func modeFooter(_ state: AgentToolSelection.State) -> String {
        switch state.mode {
        case .inherit: selection.inheritFooter
        case .exact: selection.exactFooter
        }
    }

    override func inputs(of item: Item) -> AnyHashable {
        let state = selection.state()
        switch item {
        case .mode: return AnyHashable(state.mode.rawValue)
        case .missingCatalog: return AnyHashable(0)
        case .builtIn(let name): return AnyHashable([state.selectedNames.contains(name)])
        case .optional(let name): return AnyHashable([state.selectedOptionalNames.contains(name)])
        }
    }

    override func prepareRegistrations() {
        _ = (modeRow, stateRow, toolRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .mode: collectionView.dequeueConfiguredReusableCell(using: modeRow, for: indexPath, item: item)
        case .missingCatalog:
            collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        case .builtIn:
            collectionView.dequeueConfiguredReusableCell(using: toolRow, for: indexPath, item: item)
        case .optional: super.dequeue(item, at: indexPath)
        }
    }

    // MARK: - Rows

    private func configureMode(_ cell: SettingsMenuRowCell) {
        let state = selection.state()
        cell.configure(
            title: "Selection",
            identifier: "agent.nativeEdit.toolMode",
            value: state.mode.title,
            menu: { [weak self] in
                [.inherit, .exact].map { mode in
                    SettingsMenuOption(title: mode.title, selected: mode == state.mode) { [weak self] in
                        self?.choose(mode)
                    }
                }
            }
        )
    }

    /// Choosing "Choose tools" starts the list from the defaults.
    private func choose(_ mode: AgentToolSelectionMode) {
        let state = selection.state()
        if mode == .exact, state.mode != .exact {
            selection.setSelectedNames(state.defaultSelection)
        }
        selection.setMode(mode)
    }

    private func configureTool(_ cell: SettingsSelectionRowCell, item: Item) {
        guard case .builtIn(let name) = item,
              let tool = selection.state().builtInTools.first(where: { $0.name == name }) else { return }
        let state = selection.state()
        let isChosen = state.selectedNames.contains(tool.name)
        let description = tool.description.flatMap { $0.isEmpty ? nil : $0 }
        cell.configure(
            title: tool.name,
            subtitle: description,
            isChosen: isChosen,
            value: isChosen ? "Selected" : "Not selected",
            hint: tool.description,
            identifier: "agent.nativeEdit.tool.\(tool.name)"
        ) { [weak self] in
            guard let self else { return }
            var names = selection.state().selectedNames
            if names.contains(tool.name) {
                names.remove(tool.name)
            } else {
                names.insert(tool.name)
            }
            selection.setSelectedNames(names)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        guard case .optional(let name) = item else { return }
        let state = selection.state()
        guard let tool = state.optionalTools.first(where: { $0.name == name }) else { return }
        var content = content(.subtitle)
        content.text = tool.name
        content.secondaryText = tool.description.flatMap { $0.isEmpty ? nil : $0 }
        cell.contentConfiguration = content
        cell.accessories = [.settingsToggle(
            state.selectedOptionalNames.contains(name),
            identifier: "agent.nativeEdit.optionalTool.\(name)",
            label: name,
            reusing: cell
        ) { [weak self] isOn in
            guard let self else { return }
            var names = selection.state().selectedOptionalNames
            if isOn { names.insert(name) } else { names.remove(name) }
            selection.setSelectedOptionalNames(names)
        }]
    }

    // MARK: - Bar and lifecycle

    override func updateProperties() {
        super.updateProperties()
        let state = selection.state()
        guard state.mode == .exact else {
            navigationItem.rightBarButtonItem = nil
            return
        }
        // The menu is rebuilt only when Select All stops or starts being
        // possible: replacing it under an open menu would close it.
        let hasTools = !knownToolNames(state).isEmpty
        if menuHadTools != hasTools {
            menuHadTools = hasTools
            selectionActionsItem.menu = UIMenu(children: [
                UIAction(
                    title: "Select All",
                    image: UIImage(systemName: "checkmark.circle"),
                    attributes: hasTools ? [] : .disabled
                ) { [weak self] _ in
                    guard let self else { return }
                    let state = selection.state()
                    selection.setSelectedNames(state.selectedNames.union(knownToolNames(state)))
                },
                UIAction(title: "Select None", image: UIImage(systemName: "circle")) { [weak self] _ in
                    self?.selection.setSelectedNames([])
                },
            ])
        }
        if navigationItem.rightBarButtonItem !== selectionActionsItem {
            navigationItem.rightBarButtonItem = selectionActionsItem
        }
    }

    private func knownToolNames(_ state: AgentToolSelection.State) -> Set<String> {
        Set(state.builtInTools.map(\.name))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { selection.didClose() }
    }
}
