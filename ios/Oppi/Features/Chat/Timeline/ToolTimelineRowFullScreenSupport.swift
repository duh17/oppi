enum ToolTimelineRowFullScreenSupport {
    static func supportsPreview(toolNamePrefix: String?) -> Bool {
        switch toolNamePrefix {
        case "read", "write", "edit":
            return true
        default:
            return false
        }
    }

    static func fullScreenContent(
        configuration: ToolTimelineRowConfiguration,
        outputCopyText: String?
    ) -> FullScreenCodeContent? {
        guard configuration.isExpanded,
              supportsPreview(toolNamePrefix: configuration.toolNamePrefix),
              let content = configuration.expandedContent else {
            return nil
        }

        switch content {
        case .diff(let lines, let path):
            let newText = outputCopyText ?? DiffEngine.formatUnified(lines)
            return .diff(
                oldText: "",
                newText: newText,
                filePath: path,
                precomputedLines: lines
            )

        case .markdown(let text):
            guard !text.isEmpty else { return nil }
            // Markdown payload currently has no path metadata.
            return .markdown(content: text, filePath: nil)

        case .code(let text, let language, let startLine, let filePath):
            let copyText = outputCopyText ?? text
            guard !copyText.isEmpty else { return nil }
            return .code(
                content: copyText,
                language: language?.displayName,
                filePath: filePath,
                startLine: startLine ?? 1
            )

        case .readMedia, .todoCard, .bash, .text:
            return nil
        }
    }
}
