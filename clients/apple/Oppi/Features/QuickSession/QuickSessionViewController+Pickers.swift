import UIKit

/// Quick Session's router modals, one presenter slot each, requested from the
/// model's flags in `updateProperties()`: the workspace and worktree popovers
/// (UIKit, pointing at their pills), the Agent and thinking popovers of the
/// accessibility-size panel, and the shared UIKit model picker sheet.
extension QuickSessionViewController {
    var presenters: [RouterModalPresenter] {
        [modelPicker, workspacePicker, worktreePicker, agentPicker, thinkingPicker]
    }

    /// Hardware Esc: close what is open over Quick Session first (a picker,
    /// the expanded composer, or a popover the composer presented), then
    /// Quick Session itself. A menu that is open takes Esc for itself.
    func installEscapeKey() {
        let escape = UIKeyCommand(
            title: String(localized: "Close Quick Session"),
            action: #selector(handleEscapeKey),
            input: UIKeyCommand.inputEscape
        )
        escape.wantsPriorityOverSystemBehavior = true
        addKeyCommand(escape)
    }

    @objc private func handleEscapeKey() {
        if closeOpenPickers() || dismissPresentedModal() { return }
        close()
    }

    /// Clears the model's picker requests, so each presenter dismisses its own
    /// and the flags stay true to what is on screen. False when none was open.
    private func closeOpenPickers() -> Bool {
        let wasOpen = model.showModelPicker || model.showWorkspacePicker || model.showWorktreePicker
            || model.showAgentPicker || model.showExpandedComposer || showsThinkingPicker
        guard wasOpen else { return false }
        model.showModelPicker = false
        model.showWorkspacePicker = false
        model.showWorktreePicker = false
        model.showAgentPicker = false
        model.showExpandedComposer = false
        showsThinkingPicker = false
        return true
    }

    /// A modal the composer presented itself (its own popovers): the first
    /// presentation found in this controller or the ones inside it.
    private func dismissPresentedModal() -> Bool {
        var pending: [UIViewController] = [self]
        while let controller = pending.popLast() {
            if let presented = controller.presentedViewController {
                presented.dismiss(animated: true)
                return true
            }
            pending.append(contentsOf: controller.children)
        }
        return false
    }

    /// A picker's content is built only while it is up: its screen closure
    /// runs only for a request, so the reads in it re-run this only then.
    func updatePresenters(colors: ComposerThemeColors) {
        let pickerPopover = ModalPresentation.popover.keepsPopoverInCompactWidth()
        let destinationControls = usesWideLayout ? wideDestinationControls : compactDestinationControls
        modelPicker.update(
            id: model.showModelPicker ? "model-picker" : nil,
            presentation: .popoverOrSheet(detents: [.large()]).inNavigation(),
            source: model.modelPickerSource,
            root: root,
            clear: { [weak self] in self?.model.showModelPicker = false },
            screen: { model.modelPickerScreen() }
        )
        workspacePicker.update(
            id: model.showWorkspacePicker ? "workspace-picker" : nil,
            presentation: pickerPopover,
            source: destinationControls.workspace,
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
            source: destinationControls.worktree,
            root: root,
            clear: { [weak self] in self?.model.showWorktreePicker = false },
            screen: {
                pickerScreen(style: .worktree, content: worktreePickerContent(colors: colors), colors: colors) { [weak self] in
                    self?.model.selectWorktree($0)
                }
            }
        )

        let stacks = stacksActionControls
        // The Agent's list is a picker of its own when its control is not in the
        // composer's row: in the wide bar, or the accessibility-size panel.
        agentPicker.update(
            id: (stacks || usesWideLayout) && model.showAgentPicker ? "agent-picker" : nil,
            presentation: pickerPopover,
            source: agentControl,
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
            source: thinkingPill,
            root: root,
            clear: { [weak self] in self?.showsThinkingPicker = false },
            screen: {
                ComposerThinkingPickerController.liveScreen(
                    levels: model.supportedThinkingLevels,
                    selected: model.effectiveThinkingLevel,
                    colors: colors,
                    onSelect: { [weak self] in self?.model.selectThinkingLevel($0) },
                    onSaveDefault: nil
                )
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
                icon: worktree.isMain
                    ? .symbol("house", color: colors.purple, style: .caption1, weight: .semibold)
                    : .worktree(color: colors.purple, style: .caption1),
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
