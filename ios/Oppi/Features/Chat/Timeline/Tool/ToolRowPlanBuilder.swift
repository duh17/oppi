import Foundation

@MainActor
enum ToolRowPlanBuilder {
    static func build(configuration: ToolTimelineRowConfiguration) -> ToolRowRenderPlan {
        guard configuration.isExpanded,
              let expandedContent = configuration.expandedContent else {
            return ToolRowRenderPlan(
                interactionPolicy: nil,
                interactionSpec: .collapsed
            )
        }

        let interactionPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(expandedContent, isDone: configuration.isDone)
        let hasSelectedTextContext = configuration.selectedTextPiRouter != nil
            && configuration.selectedTextSessionId != nil
        let supportsFullScreen = supportsFullScreenPreview(
            configuration: configuration,
            expandedContent: expandedContent,
            interactionPolicy: interactionPolicy
        )
        let expandedSurfaceInteraction = TimelineExpandableTextInteractionSpec.build(
            hasSelectedTextContext: hasSelectedTextContext,
            supportsFullScreenPreview: supportsFullScreen
        )

        let isBashMode = if case .bash = expandedContent { true } else { false }
        let commandTextPresent = commandTextPresent(for: expandedContent)
        let outputTextPresent = outputTextPresent(for: expandedContent)
        let expandedLabelSelectionEligible = switch expandedContent {
        case .code, .diff, .text:
            true
        case .bash, .markdown, .plot, .readMedia, .status:
            false
        }
        let markdownSelectionEligible = if case .markdown = expandedContent { true } else { false }

        let commandSelectionEnabled = hasSelectedTextContext && commandTextPresent
        let outputSelectionEnabled = hasSelectedTextContext
            && isBashMode
            && expandedSurfaceInteraction.inlineSelectionEnabled
            && outputTextPresent
        let expandedLabelSelectionEnabled = expandedSurfaceInteraction.inlineSelectionEnabled
            && expandedLabelSelectionEligible
        let markdownSelectionEnabled = expandedSurfaceInteraction.inlineSelectionEnabled
            && markdownSelectionEligible

        let interactionSpec = TimelineInteractionSpec(
            enablesTapCopyGesture: interactionPolicy.enablesTapCopyGesture && expandedSurfaceInteraction.enablesTapActivation,
            enablesPinchGesture: interactionPolicy.enablesPinchGesture && expandedSurfaceInteraction.enablesPinchActivation,
            allowsHorizontalScroll: interactionPolicy.allowsHorizontalScroll,
            commandSelectionEnabled: commandSelectionEnabled,
            outputSelectionEnabled: outputSelectionEnabled,
            expandedLabelSelectionEnabled: expandedLabelSelectionEnabled,
            markdownSelectionEnabled: markdownSelectionEnabled
        )

        return ToolRowRenderPlan(
            interactionPolicy: interactionPolicy,
            interactionSpec: interactionSpec
        )
    }

    private static func commandTextPresent(
        for content: ToolPresentationBuilder.ToolExpandedContent
    ) -> Bool {
        guard case .bash(let command, _, _) = content else {
            return false
        }
        return !(command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private static func outputTextPresent(
        for content: ToolPresentationBuilder.ToolExpandedContent
    ) -> Bool {
        switch content {
        case .bash(_, let output, _):
            return !(output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .diff(let lines, _):
            return !lines.isEmpty
        case .code(let text, _, _, _), .markdown(let text), .text(let text, _), .readMedia(let text, _, _):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .plot(_, let fallbackText):
            return !(fallbackText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .status:
            return false
        }
    }

    private static func supportsFullScreenPreview(
        configuration: ToolTimelineRowConfiguration,
        expandedContent: ToolPresentationBuilder.ToolExpandedContent,
        interactionPolicy: ToolTimelineRowInteractionPolicy
    ) -> Bool {
        guard configuration.isExpanded,
              interactionPolicy.supportsFullScreenPreview else {
            return false
        }

        switch expandedContent {
        case .diff(let lines, _):
            return !lines.isEmpty

        case .markdown(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        case .code(let text, _, _, _), .text(let text, _):
            let copyText = configuration.copyOutputText ?? text
            return !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        case .bash(_, let output, _):
            let terminalOutput = configuration.copyOutputText ?? output ?? ""
            return !terminalOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        case .plot, .readMedia, .status:
            return false
        }
    }
}
