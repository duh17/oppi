import UIKit

/// The destination row above the composer (workspace, worktree, thread,
/// engine, incognito), the launch error, and, at accessibility text sizes,
/// the Agent, model, and thinking panel below the composer.
extension QuickSessionViewController {
    func updateErrorPanel(colors: ComposerThemeColors) {
        guard let error = model.error else {
            errorPanel.setHiddenIfChanged(true)
            return
        }
        errorPanel.apply(
            message: error,
            offersChooseWorkspace: model.offersChooseCompatibleWorkspace,
            offersOpenAgents: model.offersOpenAgents,
            colors: colors
        )
        errorPanel.setHiddenIfChanged(false)
    }

    /// The destination controls of one layout: the compact pills, or the
    /// wide bar's buttons. Both are drawn on every pass so a live size-class
    /// change finds the other set current.
    struct DestinationControls {
        let workspace: QuickSessionPillButton
        let worktree: QuickSessionPillButton
        let engine: QuickSessionPillButton
        let incognito: QuickSessionPillButton
    }

    var compactDestinationControls: DestinationControls {
        DestinationControls(workspace: workspacePill, worktree: worktreePill, engine: enginePill, incognito: incognitoPill)
    }

    var wideDestinationControls: DestinationControls {
        DestinationControls(
            workspace: wideBar.workspace, worktree: wideBar.worktree, engine: wideBar.engine, incognito: wideBar.incognito
        )
    }

    func updateDestinationRow(colors: ComposerThemeColors) {
        let wide = usesWideLayout
        destinationRowContainer.setHiddenIfChanged(wide)
        wideBarContainer.setHiddenIfChanged(!wide)
        updateDestinationControls(compactDestinationControls, colors: colors)
        updateDestinationControls(wideDestinationControls, colors: colors)
        wideBar.refreshGroups()
    }

    private func updateDestinationControls(_ controls: DestinationControls, colors: ComposerThemeColors) {
        let enabled = model.isInitialized
        let bar = controls.workspace.style == .bar
        let symbolStyle: UIFont.TextStyle = bar ? .body : .caption2
        let workspace = model.selectedWorkspace
        controls.workspace.apply(QuickSessionPillButton.Content(
            icon: .choice(workspace?.icon, purpose: .workspace, sandbox: workspace?.runtime == .sandbox),
            iconAssetCache: model.selectedServerIconAssetCache,
            title: workspace?.name ?? "Workspace",
            titleColor: colors.fg,
            trailingSymbol: "chevron.down"
        ), colors: colors)
        controls.workspace.accessibilityLabel = workspace.map { "Workspace picker, current workspace \($0.name)" }
            ?? "Workspace picker"
        controls.workspace.isEnabled = enabled

        controls.worktree.setHiddenIfChanged(!model.showsWorktreePicker)
        if model.showsWorktreePicker {
            let worktree = model.selectedWorktree
            let name = worktree?.displayName ?? "Main"
            controls.worktree.apply(QuickSessionPillButton.Content(
                icon: worktree?.isMain == false
                    ? .worktree(color: colors.purple, style: symbolStyle)
                    : .symbol("house", color: colors.purple, style: symbolStyle, weight: .semibold),
                title: name,
                titleColor: colors.fg,
                trailingSymbol: "chevron.down"
            ), colors: colors)
            controls.worktree.accessibilityLabel = "Worktree picker, current worktree \(name)"
            controls.worktree.isEnabled = enabled
        }

        updateEnginePill(controls.engine, colors: colors, enabled: enabled)

        // Incognito for this launch: the session keeps no history and is deleted
        // when its chat closes. Off it is only the symbol, so it costs the
        // destination row little width; on it spells itself out. The wide bar
        // keeps the symbol alone and shows the state as its fill.
        controls.incognito.setHiddenIfChanged(!model.offersIncognito)
        if model.offersIncognito {
            let on = model.incognitoChosen
            controls.incognito.apply(QuickSessionPillButton.Content(
                icon: .symbol(
                    on ? "eye.slash.fill" : "eye.slash",
                    color: on ? colors.purple : colors.comment,
                    style: symbolStyle,
                    weight: .semibold
                ),
                title: on && !bar ? "Incognito" : nil,
                titleColor: colors.purple,
                fill: on ? colors.purple.withAlphaComponent(0.14) : nil
            ), colors: colors)
            controls.incognito.accessibilityLabel = "Incognito"
            controls.incognito.accessibilityHint = "An incognito session keeps no history and is deleted when you leave it"
            controls.incognito.accessibilityValue = on ? "On" : "Off"
            controls.incognito.toolTip = "Incognito"
            controls.incognito.isEnabled = enabled
            // Fixed traits replace the button's own, which would have said "dimmed".
            controls.incognito.accessibilityTraits = enabled ? [.button, .toggleButton] : [.button, .toggleButton, .notEnabled]
        }
    }

    /// Durable Sessions: the engine this launch uses. A toggle between
    /// Durable and Classic, or a fixed Classic with its reason when the server
    /// would refuse durable for this launch.
    private func updateEnginePill(_ pill: QuickSessionPillButton, colors: ComposerThemeColors, enabled: Bool) {
        let decision = model.engineDecision
        pill.setHiddenIfChanged(!decision.showsPill)
        guard decision.showsPill else { return }
        let isDurable = decision.engine == .durable
        let bar = pill.style == .bar
        if bar && decision.canToggle {
            // A symbol toggle: lit while Durable.
            pill.apply(QuickSessionPillButton.Content(
                icon: .symbol(
                    "infinity",
                    color: isDurable ? colors.blue : colors.comment,
                    style: .body,
                    weight: .semibold
                ),
                title: nil,
                titleColor: colors.fg,
                fill: isDurable ? colors.blue.withAlphaComponent(0.16) : nil
            ), colors: colors)
        } else {
            pill.apply(QuickSessionPillButton.Content(
                icon: isDurable ? .symbol("infinity", color: colors.fg, style: bar ? .body : .caption2, weight: .semibold) : nil,
                title: isDurable ? "Durable" : "Classic",
                titleColor: isDurable ? colors.fg : colors.comment,
                detail: decision.classicReason.map { "\u{00B7} \($0)" }
            ), colors: colors)
        }
        // A fixed Classic still takes its touches, as a label; its tap does
        // nothing (`toggleEngine`). Passed on, the touch landed on the row's
        // empty space, whose tap closes Quick Session.
        pill.dimsWhenPressed = decision.canToggle
        if decision.canToggle {
            pill.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
            pill.accessibilityLabel = isDurable ? "Durable session" : "Classic session"
            pill.accessibilityHint = isDurable ? "Switches this session to Classic" : "Switches this session to Durable"
            pill.toolTip = pill.accessibilityLabel
            pill.isEnabled = enabled
        } else {
            pill.isEnabled = true
            pill.accessibilityTraits = .staticText
            pill.accessibilityLabel = "Classic session. Durable is unavailable with \(decision.classicReason ?? "this launch")."
            pill.accessibilityHint = nil
            pill.toolTip = nil
        }
    }

    /// At accessibility text sizes the Agent, model, and thinking pills do not
    /// fit the composer's action row; they sit in a panel below the composer.
    func updateStackedPanel(colors: ComposerThemeColors) {
        let stacks = stacksActionControls
        stackedPanel.setHiddenIfChanged(!stacks)
        // Deactivate before activating: both pin the viewport's bottom.
        if stacks {
            viewportToKeyboard?.isActive = false
            viewportToStackedPanel?.isActive = true
        } else {
            viewportToStackedPanel?.isActive = false
            viewportToKeyboard?.isActive = true
        }
        guard stacks else { return }

        // Like the destination pills, these do nothing until set up; disabled,
        // they still take their touches.
        for pill in [agentPill, modelPill, thinkingPill] as [UIControl] {
            pill.isEnabled = model.isInitialized
        }
        // The toolbar pills fix their traits to a button, so VoiceOver would
        // not hear that they are dimmed.
        for pill in [modelPill, thinkingPill] {
            pill.accessibilityTraits = model.isInitialized ? .button : [.button, .notEnabled]
        }

        let agent = model.selectedAgent
        agentPill.apply(QuickSessionPillButton.Content(
            icon: agent.map { .choice($0.icon, purpose: .agent, sandbox: false) } ?? .piAvatar,
            iconAssetCache: model.selectedServerIconAssetCache,
            title: agent?.name,
            titleColor: colors.fg,
            trailingSymbol: "chevron.down"
        ), colors: colors)
        agentPill.accessibilityLabel = agent.map { "Agent picker, current agent \($0.name)" }
            ?? "Agent picker, Pi with no agent"

        let presentation = model.modelPresentation
        let modelId = model.effectiveModelId ?? presentation.pillText
        let title = shortModelName(modelId)
        let provider = presentation.pillProvider.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? providerFromModel(modelId)
        modelPill.apply(
            title: title,
            icon: provider.map { EntityIcon.image(.provider($0), size: 11) },
            tint: colors.fg,
            showsChevron: true,
            colors: colors
        )
        modelPill.accessibilityValue = title

        let level = model.effectiveThinkingLevel
        thinkingPill.apply(
            title: level.compactTitle,
            icon: UIImage(systemName: "sparkle"),
            tint: thinkingTint,
            showsChevron: true,
            colors: colors
        )
        thinkingPill.accessibilityValue = level.displayTitle
    }
}
