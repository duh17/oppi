enum ToolTimelineRowFullScreenSupport {
    static func supportsPreview(toolNamePrefix: String?) -> Bool {
        _ = toolNamePrefix
        return true
    }

    static func fullScreenContent(
        configuration: ToolTimelineRowConfiguration,
        outputCopyText: String?,
        interactionPolicy: ToolTimelineRowInteractionPolicy?,
        terminalStream: TerminalTraceStream?,
        sourceStream: SourceTraceStream?
    ) -> FullScreenCodeContent? {
        guard configuration.isExpanded,
              let content = configuration.expandedContent else {
            return nil
        }

        let supportsPreview = interactionPolicy?.supportsFullScreenPreview
            ?? supportsPreview(toolNamePrefix: configuration.toolNamePrefix)
        guard supportsPreview else { return nil }

        if !configuration.isDone {
            switch content {
            case .bash(let command, let output, _):
                let terminalOutput = outputCopyText ?? output ?? ""
                guard !terminalOutput.isEmpty else { return nil }
                return .terminal(
                    content: terminalOutput,
                    command: command ?? configuration.copyCommandText,
                    stream: terminalStream
                )

            case .code, .diff, .markdown, .text:
                guard let snapshot = liveSourceSnapshot(
                    configuration: configuration,
                    outputCopyText: outputCopyText
                ) else {
                    return nil
                }

                if let sourceStream {
                    return .liveSource(snapshot: snapshot, stream: sourceStream)
                }

                return .plainText(content: snapshot.text, filePath: snapshot.filePath)

            case .readMedia, .status:
                return nil
            }
        }

        return staticFullScreenContent(
            configuration: configuration,
            outputCopyText: outputCopyText,
            terminalStream: terminalStream
        )
    }

    static func staticFullScreenContent(
        configuration: ToolTimelineRowConfiguration,
        outputCopyText: String?,
        terminalStream: TerminalTraceStream?
    ) -> FullScreenCodeContent? {
        guard configuration.isExpanded,
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
            // HTML files get rendered preview with source toggle in full-screen
            if language == .html {
                return .html(content: copyText, filePath: filePath)
            }
            // Document renderers get native rendering in full-screen
            if language == .orgMode {
                return .orgMode(content: copyText, filePath: filePath)
            }
            if language == .latex {
                return .latex(content: copyText, filePath: filePath)
            }
            if language == .mermaid {
                return .mermaid(content: copyText, filePath: filePath)
            }
            if language == .dot {
                return .graphviz(content: copyText, filePath: filePath)
            }
            return .code(
                content: copyText,
                language: language?.displayName,
                filePath: filePath,
                startLine: startLine ?? 1
            )

        case .bash(let command, let output, _):
            let terminalOutput = outputCopyText ?? output ?? ""
            guard !terminalOutput.isEmpty else { return nil }
            return .terminal(
                content: terminalOutput,
                command: command ?? configuration.copyCommandText,
                stream: terminalStream
            )

        case .text(let text, _):
            let terminalOutput = outputCopyText ?? text
            guard !terminalOutput.isEmpty else { return nil }
            return .terminal(
                content: terminalOutput,
                command: configuration.copyCommandText,
                stream: terminalStream
            )

        case .readMedia, .status:
            return nil
        }
    }

    static func liveSourceSnapshot(
        configuration: ToolTimelineRowConfiguration,
        outputCopyText: String?
    ) -> SourceTraceStream.Snapshot? {
        guard configuration.isExpanded,
              let content = configuration.expandedContent else {
            return nil
        }

        switch content {
        case .code(let text, _, _, let filePath):
            guard !text.isEmpty else { return nil }
            return SourceTraceStream.Snapshot(
                text: text,
                filePath: filePath,
                isDone: configuration.isDone,
                finalContent: nil
            )

        case .diff(let lines, let path):
            let diffText = outputCopyText ?? DiffEngine.formatUnified(lines)
            guard !diffText.isEmpty else { return nil }
            return SourceTraceStream.Snapshot(
                text: diffText,
                filePath: path,
                isDone: configuration.isDone,
                finalContent: nil
            )

        case .markdown(let text):
            guard !text.isEmpty else { return nil }
            return SourceTraceStream.Snapshot(
                text: text,
                filePath: nil,
                isDone: configuration.isDone,
                finalContent: nil
            )

        case .text(let text, _):
            let sourceText = outputCopyText ?? text
            guard !sourceText.isEmpty else { return nil }
            return SourceTraceStream.Snapshot(
                text: sourceText,
                filePath: nil,
                isDone: configuration.isDone,
                finalContent: nil
            )

        case .bash, .readMedia, .status:
            return nil
        }
    }
}
