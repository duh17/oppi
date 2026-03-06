import Foundation

struct ToolRowRenderPlan: Equatable {
    enum ExpandedMode: String, Equatable {
        case none
        case bash
        case diff
        case code
        case markdown
        case plot
        case readMedia
        case text
    }

    let expandedMode: ExpandedMode
    let interactionPolicy: ToolTimelineRowInteractionPolicy?
    let interactionSpec: TimelineInteractionSpec
    let commandTextPresent: Bool
    let outputTextPresent: Bool
    let collapsedPreviewPresent: Bool
    let collapsedImagePreviewPresent: Bool

    var expectsExpandedContainer: Bool {
        switch expandedMode {
        case .diff, .code, .markdown, .plot, .readMedia, .text:
            true
        case .none, .bash:
            false
        }
    }

    var expectsCommandContainer: Bool {
        expandedMode == .bash && commandTextPresent
    }

    var expectsOutputContainer: Bool {
        expandedMode == .bash && outputTextPresent
    }
}
