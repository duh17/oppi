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

    func updateDestinationRow(colors: ComposerThemeColors) {
        let enabled = model.isInitialized
        let workspace = model.selectedWorkspace
        workspacePill.apply(QuickSessionPillButton.Content(
            icon: workspace.map { .choice($0.icon, purpose: .workspace, sandbox: $0.runtime == .sandbox) }
                ?? .symbol("folder", color: colors.blue, style: .caption2, weight: .semibold),
            iconAssetCache: model.selectedServerIconAssetCache,
            title: workspace?.name ?? "Workspace",
            titleColor: colors.fg,
            trailingSymbol: "chevron.down"
        ), colors: colors)
        workspacePill.accessibilityLabel = workspace.map { "Workspace picker, current workspace \($0.name)" }
            ?? "Workspace picker"
        workspacePill.isEnabled = enabled

        worktreePill.setHiddenIfChanged(!model.showsWorktreePicker)
        if model.showsWorktreePicker {
            let worktree = model.selectedWorktree
            let name = worktree?.displayName ?? "Main"
            worktreePill.apply(QuickSessionPillButton.Content(
                icon: .symbol(
                    worktree?.isMain == false ? "arrow.triangle.branch" : "house",
                    color: colors.purple,
                    style: .caption2,
                    weight: .semibold
                ),
                title: name,
                titleColor: colors.fg,
                trailingSymbol: "chevron.down"
            ), colors: colors)
            worktreePill.accessibilityLabel = "Worktree picker, current worktree \(name)"
            worktreePill.isEnabled = enabled
        }

        let threadParent = model.threadParent
        threadPill.setHiddenIfChanged(threadParent == nil)
        if let threadParent {
            threadPill.apply(QuickSessionPillButton.Content(
                icon: .symbol("point.3.connected.trianglepath.dotted", color: colors.blue, style: .caption2, weight: .semibold),
                title: threadParent.title,
                titleColor: colors.fg,
                trailingSymbol: "xmark"
            ), colors: colors)
            threadPill.accessibilityLabel = "In thread \(threadParent.title)"
            threadPill.isEnabled = enabled
        }

        updateEnginePill(colors: colors, enabled: enabled)

        // Incognito for this launch: the session keeps no history and is deleted
        // when its chat closes. Off it is only the symbol, so it costs the
        // destination row little width; on it spells itself out.
        incognitoPill.setHiddenIfChanged(!model.offersIncognito)
        if model.offersIncognito {
            let on = model.incognitoChosen
            incognitoPill.apply(QuickSessionPillButton.Content(
                icon: .symbol(on ? "eye.slash.fill" : "eye.slash", color: on ? colors.purple : colors.comment, style: .caption2, weight: .semibold),
                title: on ? "Incognito" : nil,
                titleColor: colors.purple,
                fill: on ? colors.purple.withAlphaComponent(0.14) : nil
            ), colors: colors)
            incognitoPill.accessibilityValue = on ? "On" : "Off"
            incognitoPill.isEnabled = enabled
        }
    }

    /// Durable Sessions experiment: the engine this launch uses. A toggle between
    /// Durable and Classic, or a fixed Classic with its reason when the server
    /// would refuse durable for this launch.
    private func updateEnginePill(colors: ComposerThemeColors, enabled: Bool) {
        let decision = model.engineDecision
        enginePill.setHiddenIfChanged(!decision.showsPill)
        guard decision.showsPill else { return }
        let isDurable = decision.engine == .durable
        enginePill.apply(QuickSessionPillButton.Content(
            icon: isDurable ? .symbol("infinity", color: colors.fg, style: .caption2, weight: .semibold) : nil,
            title: isDurable ? "Durable" : "Classic",
            titleColor: isDurable ? colors.fg : colors.comment,
            detail: decision.classicReason.map { "\u{00B7} \($0)" }
        ), colors: colors)
        // A fixed Classic still takes its touches, as a label; its tap does
        // nothing (`toggleEngine`). Passed on, the touch landed on the row's
        // empty space, whose tap closes Quick Session.
        if decision.canToggle {
            enginePill.accessibilityTraits = .button
            enginePill.accessibilityLabel = isDurable ? "Durable session" : "Classic session"
            enginePill.accessibilityHint = isDurable ? "Switches this session to Classic" : "Switches this session to Durable"
            enginePill.isEnabled = enabled
        } else {
            enginePill.isEnabled = true
            enginePill.accessibilityTraits = .staticText
            enginePill.accessibilityLabel = "Classic session. Durable is unavailable with \(decision.classicReason ?? "this launch")."
            enginePill.accessibilityHint = nil
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
            title: agent?.name ?? "Pi",
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
            icon: provider.map { ComposerProviderIconRenderer.image(provider: $0, size: 11, colors: colors) },
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
