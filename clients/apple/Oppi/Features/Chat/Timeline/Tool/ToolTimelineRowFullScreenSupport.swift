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

            case .text(let text, _):
                guard !text.isEmpty else { return nil }
                return .terminal(
                    content: text,
                    command: configuration.copyCommandText,
                    stream: terminalStream
                )

            case .code, .diff, .markdown:
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

            case .readMedia, .audioMessage, .status:
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
            return .diff(
                ToolDiffDocument(
                    lines: lines,
                    filePath: path,
                    copyText: outputCopyText ?? DiffEngine.formatUnified(lines)
                )
            )

        case .markdown(let text, let filePath):
            guard !text.isEmpty else { return nil }
            let path = resolvedMarkdownFilePath(filePath, configuration: configuration)
            return .markdown(
                content: text,
                filePath: path,
                workspaceContext: markdownWorkspaceContext(configuration: configuration)
            )

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
            // `text` is the display payload and may contain ANSI styling; the
            // separate copy value is intentionally stripped for the clipboard.
            guard !text.isEmpty else { return nil }
            return .terminal(
                content: text,
                command: configuration.copyCommandText,
                // Completed text is already the final ANSI display payload. The
                // stream snapshot is the clipboard-safe representation and may
                // intentionally be stripped.
                stream: nil
            )

        case .readMedia, .audioMessage, .status:
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
        case .code(let text, let language, _, let filePath):
            guard !text.isEmpty else { return nil }
            let renderContent: FullScreenCodeContent? = language == .html
                ? .html(content: text, filePath: filePath)
                : nil
            return SourceTraceStream.Snapshot(
                text: text,
                filePath: filePath,
                isDone: configuration.isDone,
                finalContent: renderContent
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

        case .markdown(let text, let filePath):
            guard !text.isEmpty else { return nil }
            let path = resolvedMarkdownFilePath(filePath, configuration: configuration)
            let workspaceContext = markdownWorkspaceContext(configuration: configuration)
            return SourceTraceStream.Snapshot(
                text: text,
                filePath: path,
                isDone: configuration.isDone,
                finalContent: .markdown(
                    content: text,
                    filePath: path,
                    workspaceContext: workspaceContext
                )
            )

        case .text(let text, _):
            // Keep terminal styling in the full-screen display while copyOutputText
            // remains the ANSI-stripped clipboard representation.
            guard !text.isEmpty else { return nil }
            return SourceTraceStream.Snapshot(
                text: text,
                filePath: nil,
                isDone: configuration.isDone,
                finalContent: nil
            )

        case .bash, .readMedia, .audioMessage, .status:
            return nil
        }
    }

    private static func resolvedMarkdownFilePath(
        _ filePath: String?,
        configuration: ToolTimelineRowConfiguration
    ) -> String? {
        for candidate in [filePath, configuration.sourceFilePath] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func markdownWorkspaceContext(
        configuration: ToolTimelineRowConfiguration
    ) -> FullScreenCodeContent.WorkspaceContext? {
        let workspaceID = configuration.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspaceID, !workspaceID.isEmpty,
              let serverBaseURL = configuration.serverBaseURL,
              let fetchWorkspaceFile = configuration.fetchWorkspaceFile else {
            return nil
        }
        return .init(
            workspaceID: workspaceID,
            serverID: configuration.serverID,
            worktreeId: configuration.worktreeId,
            serverBaseURL: serverBaseURL,
            fetchWorkspaceFile: fetchWorkspaceFile,
            sessionID: configuration.sessionID,
            fetchHostFile: configuration.fetchHostFile,
            audioPlayer: configuration.audioPlayer
        )
    }
}
