import UIKit

/// Quick Session's router modals, one presenter slot each, requested from the
/// model's flags in `updateProperties()`: the workspace and worktree popovers
/// (UIKit, on their pills), the Agent and thinking popovers of the
/// accessibility-size panel, and the shared SwiftUI model picker sheet.
extension QuickSessionViewController {
    var presenters: [RouterModalPresenter] {
        [modelPicker, workspacePicker, worktreePicker, agentPicker, thinkingPicker]
    }

    /// A picker's content is built only while it is up: its screen closure
    /// runs only for a request, so the reads in it re-run this only then.
    func updatePresenters(colors: ComposerThemeColors) {
        let pickerPopover = ModalPresentation.popover.keepsPopoverInCompactWidth()
        modelPicker.update(
            id: model.showModelPicker ? "model-picker" : nil,
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.model.showModelPicker = false },
            screen: { model.modelPickerScreen() }
        )
        workspacePicker.update(
            id: model.showWorkspacePicker ? "workspace-picker" : nil,
            presentation: pickerPopover,
            root: root,
            clear: { [weak self] in self?.model.showWorkspacePicker = false },
            screen: {
                pickerScreen(style: .workspace, content: workspacePickerContent(), colors: colors) { [weak self] in
                    self?.selectWorkspace(key: $0)
                }
            }
        )
        worktreePicker.update(
            id: model.showWorktreePicker && model.showsWorktreePicker ? "worktree-picker" : nil,
            presentation: pickerPopover,
            root: root,
            clear: { [weak self] in self?.model.showWorktreePicker = false },
            screen: {
                pickerScreen(style: .worktree, content: worktreePickerContent(colors: colors), colors: colors) { [weak self] in
                    self?.model.selectWorktree($0)
                }
            }
        )

        let stacks = stacksActionControls
        agentPicker.update(
            id: stacks && model.showAgentPicker ? "agent-picker" : nil,
            presentation: pickerPopover,
            root: root,
            clear: { [weak self] in self?.model.showAgentPicker = false },
            screen: {
                pickerScreen(style: .agent, content: agentPickerContent(colors: colors), colors: colors) { [weak self] id in
                    self?.model.selectAgent(id == Self.piRowID ? nil : id)
                }
            }
        )
        thinkingPicker.update(
            id: stacks && showsThinkingPicker ? "thinking-picker" : nil,
            presentation: .popover.arrowDirections(.down).keepsPopoverInCompactWidth(),
            root: root,
            clear: { [weak self] in self?.showsThinkingPicker = false },
            screen: {
                let level = model.effectiveThinkingLevel
                let levels = model.supportedThinkingLevels
                let selectThinking: (ThinkingLevel) -> Void = { [weak self] in self?.model.selectThinkingLevel($0) }
                return .liveController({
                    ComposerThinkingPickerController(
                        levels: levels,
                        selected: level,
                        colors: colors,
                        onSelect: selectThinking,
                        onSaveDefault: nil
                    )
                }, update: { picker in
                    picker.apply(levels: levels, selected: level, onSelect: selectThinking, onSaveDefault: nil)
                })
            }
        )
    }

    private func pickerScreen(
        style: QuickSessionPickerStyle,
        content: QuickSessionPickerContent,
        colors: ComposerThemeColors,
        onSelect: @escaping (String) -> Void
    ) -> RouterScreen {
        .liveController({
            QuickSessionPickerController(style: style, content: content, colors: colors, onSelect: onSelect)
        }, update: { picker in
            picker.apply(content: content, onSelect: onSelect)
        })
    }

    // MARK: Workspaces

    /// Workspace rows are keyed by server and workspace: one id can exist on two servers.
    private static func workspaceKey(serverId: String, workspaceId: String) -> String {
        "\(serverId)\u{1F}\(workspaceId)"
    }

    private func selectWorkspace(key: String) {
        for section in model.workspacePickerSections {
            if let workspace = section.workspaces.first(where: {
                Self.workspaceKey(serverId: section.id, workspaceId: $0.id) == key
            }) {
                model.selectWorkspace(workspace, serverId: section.id)
                return
            }
        }
    }

    private func workspacePickerContent() -> QuickSessionPickerContent {
        let sections = model.workspacePickerSections
        guard sections.contains(where: { !$0.workspaces.isEmpty }) else {
            return .empty(
                title: "No workspaces available",
                systemImage: "folder.badge.questionmark",
                message: model.workspacePickerEmptyMessage
            )
        }
        let showsHeaders = sections.count > 1
        let selectedWorkspaceId = model.selectedWorkspace?.id
        let selectedServerId = model.selectedServerId
        return .sections(sections.map { section in
            QuickSessionPickerSection(
                title: showsHeaders ? section.name : nil,
                rows: section.workspaces.map { workspace in
                    let isSelected = workspace.id == selectedWorkspaceId
                        && (selectedServerId == nil || selectedServerId == section.id)
                    return QuickSessionPickerRow(
                        id: Self.workspaceKey(serverId: section.id, workspaceId: workspace.id),
                        icon: .choice(workspace.icon, purpose: .workspace, sandbox: workspace.runtime == .sandbox),
                        iconAssetCache: section.iconAssetCache,
                        title: workspace.name,
                        subtitle: nil,
                        isSelected: isSelected,
                        accessibilityIdentifier: "quickSession.workspace.\(workspace.name)",
                        accessibilityLabel: workspace.name,
                        accessibilityValue: isSelected ? "Selected" : ""
                    )
                }
            )
        })
    }

    // MARK: Worktrees

    private func worktreePickerContent(colors: ComposerThemeColors) -> QuickSessionPickerContent {
        let worktrees = model.worktrees
        if model.isLoadingWorktrees && worktrees.isEmpty {
            return .loading("Loading worktrees…")
        }
        let selectedId = model.selectedWorktree?.id
        return .sections([QuickSessionPickerSection(title: nil, rows: worktrees.map { worktree in
            QuickSessionPickerRow(
                id: worktree.id,
                icon: .symbol(
                    worktree.isMain ? "house" : "arrow.triangle.branch",
                    color: colors.purple,
                    style: .caption1,
                    weight: .semibold
                ),
                title: WorkspaceWorktreeMenuFormatting.title(for: worktree),
                subtitle: Self.worktreeSubtitle(for: worktree),
                isSelected: worktree.id == selectedId,
                accessibilityIdentifier: "quickSession.worktree.\(worktree.id)",
                accessibilityLabel: WorkspaceWorktreeMenuFormatting.accessibilityLabel(for: worktree)
            )
        })])
    }

    private static func worktreeSubtitle(for worktree: WorkspaceWorktree) -> String? {
        if let count = WorkspaceWorktreeMenuFormatting.sessionCountText(for: worktree) {
            let noun = worktree.sessionCount == 1 ? "session" : "sessions"
            return "\(count) \(noun)"
        }
        if !worktree.subtitle.isEmpty, worktree.subtitle != worktree.displayName {
            return worktree.subtitle
        }
        return nil
    }

    // MARK: Agents

    /// The Pi row's id; every other row is an Agent's.
    static let piRowID = "pi"

    /// At accessibility text sizes: Pi, then the server's saved Agents, with
    /// their Genmoji icons from the server.
    private func agentPickerContent(colors: ComposerThemeColors) -> QuickSessionPickerContent {
        let selectedId = model.selectedAgentId
        let agents = model.availableAgents
        let cache = model.selectedServerIconAssetCache
        let pi = QuickSessionPickerRow(
            id: Self.piRowID,
            icon: .piAvatar,
            title: "Pi",
            isSelected: selectedId == nil,
            accessibilityIdentifier: "quickSession.agent.pi",
            accessibilityLabel: "Pi"
        )
        let rows = agents.map { agent in
            QuickSessionPickerRow(
                id: agent.id,
                icon: .choice(agent.icon, purpose: .agent, sandbox: false),
                iconAssetCache: cache,
                title: agent.name,
                subtitle: agent.description,
                isSelected: selectedId == agent.id,
                accessibilityIdentifier: "quickSession.agent.\(agent.id)",
                accessibilityLabel: agent.name
            )
        }
        let note: QuickSessionPickerNote? = agents.isEmpty
            ? (model.isLoadingAgents ? .loading("Loading agents…") : .message("No saved Agents on this server."))
            : nil
        return .sections([QuickSessionPickerSection(title: nil, rows: [pi] + rows, note: note)])
    }
}
