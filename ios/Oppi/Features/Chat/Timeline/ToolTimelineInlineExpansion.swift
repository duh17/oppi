import Foundation

enum ToolTimelineInlineExpansionLevel: Equatable {
    case compact
    case expanded
}

enum ToolTimelineInlineExpansionMode {
    case bashOutput
    case code
    case markdown
    case text
}

struct ToolTimelineInlineExpansionResolution: Equatable {
    let text: String
    let toggleTitle: String?
}

enum ToolTimelineInlineExpansion {
    private static let compactTextLineLimit = 24
    private static let expandedTextLineLimit = 120
    private static let compactCodeLineLimit = 40
    private static let expandedCodeLineLimit = 220

    static func resolve(
        text: String,
        mode: ToolTimelineInlineExpansionMode,
        level: ToolTimelineInlineExpansionLevel
    ) -> ToolTimelineInlineExpansionResolution {
        guard !text.isEmpty else {
            return ToolTimelineInlineExpansionResolution(text: text, toggleTitle: nil)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else {
            return ToolTimelineInlineExpansionResolution(text: text, toggleTitle: nil)
        }

        let compactLimit = lineLimit(for: mode, level: .compact)
        let supportsToggle = lines.count > compactLimit

        let appliedLimit = lineLimit(for: mode, level: level)
        let hiddenCount = max(0, lines.count - appliedLimit)

        let rendered: String
        if hiddenCount > 0 {
            let visible = lines.prefix(appliedLimit).joined(separator: "\n")
            let lineWord = hiddenCount == 1 ? "line" : "lines"
            let note: String
            switch level {
            case .compact:
                note = "\n\n… [\(hiddenCount) \(lineWord) hidden. Tap Show more.]"
            case .expanded:
                note = "\n\n… [\(hiddenCount) \(lineWord) hidden. Open full screen for complete output.]"
            }
            rendered = visible + note
        } else {
            rendered = text
        }

        let toggleTitle: String?
        if supportsToggle {
            switch level {
            case .compact:
                toggleTitle = String(localized: "Show more")
            case .expanded:
                toggleTitle = String(localized: "Show less")
            }
        } else {
            toggleTitle = nil
        }

        return ToolTimelineInlineExpansionResolution(
            text: rendered,
            toggleTitle: toggleTitle
        )
    }

    private static func lineLimit(
        for mode: ToolTimelineInlineExpansionMode,
        level: ToolTimelineInlineExpansionLevel
    ) -> Int {
        switch (mode, level) {
        case (.code, .compact):
            compactCodeLineLimit
        case (.code, .expanded):
            expandedCodeLineLimit
        case (.bashOutput, .compact), (.markdown, .compact), (.text, .compact):
            compactTextLineLimit
        case (.bashOutput, .expanded), (.markdown, .expanded), (.text, .expanded):
            expandedTextLineLimit
        }
    }
}
