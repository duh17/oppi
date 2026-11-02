enum ToolTimelineRowFullScreenSupport {
    @MainActor static func fullScreenContent(
        configuration: ToolTimelineRowConfiguration,
        outputCopyText: String?,
        interactionPolicy: ToolTimelineRowInteractionPolicy?,
        terminalTrace: ReaderTrace<TerminalSnapshot>?,
        sourceTrace: ReaderTrace<SourceSnapshot>?
    ) -> FullScreenCodeContent? {
        guard configuration.isExpanded,
              let content = configuration.expandedContent else {
            return nil
        }

        guard interactionPolicy?.supportsFullScreenPreview ?? true else { return nil }

        if !configuration.isDone {
            switch content {
            case .bash(let command, let output, _):
                let terminalOutput = outputCopyText ?? output ?? ""
                guard !terminalOutput.isEmpty else { return nil }
                return .terminal(
                    content: terminalOutput,
                    command: command ?? configuration.copyCommandText,
                    trace: terminalTrace
                )

            case .text(let text, _):
                guard !text.isEmpty else { return nil }
                return .terminal(
                    content: text,
                    command: configuration.copyCommandText,
                    trace: terminalTrace
                )

            case .notebook(let plan):
                return .notebook(plan)

            case .code, .diff, .markdown, .document:
                guard let snapshot = liveSourceSnapshot(
                    configuration: configuration,
                    outputCopyText: outputCopyText
                ) else {
                    return nil
                }

                if let sourceTrace {
                    return .liveSource(sourceTrace)
                }

                return .plainText(content: snapshot.text, filePath: snapshot.filePath)

            case .readMedia, .audioMessage, .status:
                return nil
            }
        }

        return staticFullScreenContent(
            configuration: configuration,
            outputCopyText: outputCopyText,
            terminalTrace: terminalTrace
        )
    }

    /// The terminal trace's payload. The row and the timeline's open-reader
    /// feed share it, so a reader shows the text the apply produced.
    static func terminalTraceUpdate(
        configuration: ToolTimelineRowConfiguration
    ) -> TerminalSnapshot {
        let output: String
        if case .text(let text, _) = configuration.expandedContent {
            // The stream drives full-screen display; keep its ANSI payload and
            // strip only when the controller builds clipboard text.
            output = text
        } else {
            output = configuration.copyOutputText ?? ""
        }
        return TerminalSnapshot(
            output: output,
            command: configuration.copyCommandText,
            isDone: configuration.isDone,
            sidecarSource: configuration.toolOutputSidecarSource
        )
    }

    /// The snapshot a live-source reader shows, and the finished content that
    /// replaces it. Nil when this row has no source reading to follow.
    static func sourceTraceUpdate(
        configuration: ToolTimelineRowConfiguration,
        outputCopyText: String?
    ) -> SourceSnapshot? {
        guard let snapshot = liveSourceSnapshot(
            configuration: configuration,
            outputCopyText: outputCopyText
        ) else {
            return nil
        }
        let finalContent: FullScreenCodeContent?
        if configuration.isDone {
            finalContent = staticFullScreenContent(
                configuration: configuration,
                outputCopyText: outputCopyText,
                terminalTrace: nil
            )
        } else {
            finalContent = snapshot.finalContent
        }
        return SourceSnapshot(
            text: snapshot.text,
            filePath: snapshot.filePath,
            isDone: configuration.isDone,
            finalContent: finalContent
        )
    }

    static func staticFullScreenContent(
        configuration: ToolTimelineRowConfiguration,
        outputCopyText: String?,
        terminalTrace: ReaderTrace<TerminalSnapshot>?
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
                resourceAccess: configuration.resourceAccess,
                rawText: configuration.rawMarkdownText,
                sidecarSource: configuration.toolOutputSidecarSource.map { source in
                    var bound = source
                    bound.rawDocumentPrefix = configuration.rawMarkdownOutputPrefix
                    return bound
                }
            )

        case .document(let family):
            guard !family.text.isEmpty else { return nil }
            return .document(family)

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
                trace: terminalTrace,
                sidecarSource: configuration.toolOutputSidecarSource
            )

        case .text(let text, _):
            // `text` is the display payload and may contain ANSI styling; the
            // separate copy value is intentionally stripped for the clipboard.
            guard !text.isEmpty else { return nil }
            return .terminal(
                content: text,
                command: configuration.copyCommandText,
                // Completed text is already the final ANSI display payload. The
                // trace snapshot is the clipboard-safe representation and may
                // intentionally be stripped.
                trace: nil
            )

        case .notebook(let plan):
            return .notebook(plan)

        case .readMedia, .audioMessage, .status:
            return nil
        }
    }

    static func liveSourceSnapshot(
        configuration: ToolTimelineRowConfiguration,
        outputCopyText: String?
    ) -> SourceSnapshot? {
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
            return SourceSnapshot(
                text: text,
                filePath: filePath,
                isDone: configuration.isDone,
                finalContent: renderContent
            )

        case .diff(let lines, let path):
            let diffText = outputCopyText ?? DiffEngine.formatUnified(lines)
            guard !diffText.isEmpty else { return nil }
            return SourceSnapshot(
                text: diffText,
                filePath: path,
                isDone: configuration.isDone,
                finalContent: nil
            )

        case .markdown(let text, let filePath):
            guard !text.isEmpty else { return nil }
            let path = resolvedMarkdownFilePath(filePath, configuration: configuration)
            return SourceSnapshot(
                text: text,
                filePath: path,
                isDone: configuration.isDone,
                finalContent: .markdown(
                    content: text,
                    filePath: path,
                    resourceAccess: configuration.resourceAccess,
                    rawText: configuration.rawMarkdownText,
                    sidecarSource: configuration.toolOutputSidecarSource.map { source in
                        var bound = source
                        bound.rawDocumentPrefix = configuration.rawMarkdownOutputPrefix
                        return bound
                    }
                )
            )

        case .document(let family):
            guard !family.text.isEmpty else { return nil }
            return SourceSnapshot(
                text: family.text,
                filePath: family.filePath,
                isDone: configuration.isDone,
                finalContent: .document(family)
            )

        case .text(let text, _):
            // Keep terminal styling in the full-screen display while copyOutputText
            // remains the ANSI-stripped clipboard representation.
            guard !text.isEmpty else { return nil }
            return SourceSnapshot(
                text: text,
                filePath: nil,
                isDone: configuration.isDone,
                finalContent: nil
            )

        case .notebook(let plan):
            return SourceSnapshot(
                text: plan.readerText,
                filePath: nil,
                isDone: configuration.isDone,
                finalContent: .notebook(plan)
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
}
