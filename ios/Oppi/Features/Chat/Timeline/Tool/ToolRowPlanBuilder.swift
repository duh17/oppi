import Foundation

@MainActor
enum ToolRowPlanBuilder {
    static func build(configuration: ToolTimelineRowConfiguration) -> ToolRowRenderPlan {
        let collapsedPreviewPresent = {
            let preview = configuration.preview?.trimmingCharacters(in: .whitespacesAndNewlines)
            return !configuration.isExpanded && !(preview?.isEmpty ?? true)
        }()
        let collapsedImagePreviewPresent = {
            guard !configuration.isExpanded,
                  let base64 = configuration.collapsedImageBase64 else {
                return false
            }
            return !base64.isEmpty
        }()

        guard configuration.isExpanded,
              let expandedContent = configuration.expandedContent else {
            return ToolRowRenderPlan(
                expandedMode: .none,
                interactionPolicy: nil,
                interactionSpec: .collapsed,
                commandTextPresent: false,
                outputTextPresent: false,
                collapsedPreviewPresent: collapsedPreviewPresent,
                collapsedImagePreviewPresent: collapsedImagePreviewPresent
            )
        }

        let interactionPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(expandedContent)
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

        let expandedMode = expandedMode(for: expandedContent)
        let commandTextPresent = commandTextPresent(for: expandedContent)
        let outputTextPresent = outputTextPresent(for: expandedContent)
        let expandedLabelSelectionEligible = switch expandedContent {
        case .code, .diff, .text:
            true
        case .bash, .markdown, .plot, .readMedia:
            false
        }
        let markdownSelectionEligible = if case .markdown = expandedContent { true } else { false }

        let commandSelectionEnabled = hasSelectedTextContext && commandTextPresent
        let outputSelectionEnabled = hasSelectedTextContext
            && expandedMode == .bash
            && expandedSurfaceInteraction.inlineSelectionEnabled
            && outputTextPresent
        let expandedLabelSelectionEnabled = expandedSurfaceInteraction.inlineSelectionEnabled
            && expandedLabelSelectionEligible
        let markdownSelectionEnabled = expandedSurfaceInteraction.inlineSelectionEnabled
            && markdownSelectionEligible

        let interactionSpec = TimelineInteractionSpec(
            expandedSurfaceInteraction: expandedSurfaceInteraction,
            enablesTapCopyGesture: interactionPolicy.enablesTapCopyGesture && expandedSurfaceInteraction.enablesTapActivation,
            enablesPinchGesture: interactionPolicy.enablesPinchGesture && expandedSurfaceInteraction.enablesPinchActivation,
            allowsHorizontalScroll: interactionPolicy.allowsHorizontalScroll,
            supportsFullScreenPreview: expandedSurfaceInteraction.supportsFullScreenPreview,
            commandSelectionEnabled: commandSelectionEnabled,
            outputSelectionEnabled: outputSelectionEnabled,
            expandedLabelSelectionEnabled: expandedLabelSelectionEnabled,
            markdownSelectionEnabled: markdownSelectionEnabled
        )

        return ToolRowRenderPlan(
            expandedMode: expandedMode,
            interactionPolicy: interactionPolicy,
            interactionSpec: interactionSpec,
            commandTextPresent: commandTextPresent,
            outputTextPresent: outputTextPresent,
            collapsedPreviewPresent: collapsedPreviewPresent,
            collapsedImagePreviewPresent: collapsedImagePreviewPresent
        )
    }

    private static func expandedMode(
        for content: ToolPresentationBuilder.ToolExpandedContent
    ) -> ToolRowRenderPlan.ExpandedMode {
        switch content {
        case .bash:
            .bash
        case .diff:
            .diff
        case .code:
            .code
        case .markdown:
            .markdown
        case .plot:
            .plot
        case .readMedia:
            .readMedia
        case .text:
            .text
        }
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

        case .plot, .readMedia:
            return false
        }
    }
}
