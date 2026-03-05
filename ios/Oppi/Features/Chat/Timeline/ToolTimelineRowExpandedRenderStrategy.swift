@MainActor
enum ToolTimelineRowExpandedRenderMode: Equatable {
    case bash
    case diff
    case code
    case markdown
    case plot
    case readMedia
    case text
}

@MainActor
struct ToolTimelineRowExpandedRenderContext {
    let isStreaming: Bool
    let isError: Bool
    let wasExpandedVisible: Bool
    let wasOutputVisible: Bool
}

@MainActor
struct ToolTimelineRowExpandedRenderInput {
    let expandedContent: ToolPresentationBuilder.ToolExpandedContent
    let context: ToolTimelineRowExpandedRenderContext
}

@MainActor
protocol ToolTimelineRowExpandedRenderStrategy {
    static var mode: ToolTimelineRowExpandedRenderMode { get }
    static func isApplicable(to input: ToolTimelineRowExpandedRenderInput) -> Bool
}

@MainActor
enum ToolTimelineRowExpandedStrategySelector {
    static func mode(for input: ToolTimelineRowExpandedRenderInput) -> ToolTimelineRowExpandedRenderMode {
        switch input.expandedContent {
        case .bash:
            return .bash
        case .diff:
            return .diff
        case .code:
            return .code
        case .markdown:
            return .markdown
        case .plot:
            return .plot
        case .readMedia:
            return .readMedia
        case .text:
            return .text
        }
    }
}
