import UIKit

@MainActor
enum ToolTimelineRowExpandedRenderer {
    struct Visibility {
        let showExpandedContainer: Bool
        let showCommandContainer: Bool
        let showOutputContainer: Bool
    }

    static func renderBashMode(
        command: String?,
        output: String?,
        unwrapped: Bool,
        isError: Bool,
        isStreaming: Bool,
        outputColor: UIColor,
        commandTextColor: UIColor,
        wasOutputVisible: Bool,
        commandLabel: UITextView,
        outputLabel: UITextView,
        outputScrollView: UIScrollView,
        commandRenderSignature: inout Int?,
        outputRenderSignature: inout Int?,
        outputRenderedText: inout String?,
        outputUsesUnwrappedLayout: inout Bool,
        outputUsesViewport: inout Bool,
        outputShouldAutoFollow: inout Bool,
        outputDidTextChange: inout Bool,
        outputViewportHeightConstraint: NSLayoutConstraint?,
        hideExpandedContainer: () -> Void
    ) -> Visibility {
        var showCommandContainer = false
        var showOutputContainer = false
        outputDidTextChange = false

        if let command, !command.isEmpty {
            let displayCmd = ToolTimelineRowRenderMetrics.displayCommandText(command)
            let signature = ToolTimelineRowRenderMetrics.commandSignature(displayCommand: displayCmd)
            if signature != commandRenderSignature {
                if displayCmd.utf8.count <= ToolRowTextRenderer.maxShellHighlightBytes {
                    commandLabel.attributedText = ToolRowTextRenderer.bashCommandHighlighted(displayCmd)
                } else {
                    commandLabel.attributedText = nil
                    commandLabel.text = displayCmd
                    commandLabel.textColor = commandTextColor
                }
                commandRenderSignature = signature
            }
            showCommandContainer = true
        } else {
            commandRenderSignature = nil
        }

        if let output, !output.isEmpty {
            let displayOutput = ToolTimelineRowRenderMetrics.displayOutputText(output)
            let signature = ToolTimelineRowRenderMetrics.outputSignature(
                displayOutput: displayOutput,
                isError: isError,
                unwrapped: unwrapped,
                isStreaming: isStreaming
            )

            if signature != outputRenderSignature {
                let presentation: ToolRowTextRenderer.ANSIOutputPresentation
                if isStreaming {
                    // During streaming, skip expensive ANSI parsing — show
                    // stripped plain text. Full-screen view handles ANSI live.
                    // Highlighting applies once when the tool completes.
                    presentation = ToolRowTextRenderer.ANSIOutputPresentation(
                        attributedText: nil,
                        plainText: ANSIParser.strip(displayOutput)
                    )
                } else {
                    presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
                        displayOutput,
                        isError: isError
                    )
                }
                let nextRendered = presentation.attributedText?.string ?? presentation.plainText ?? ""
                let prevOutputRendered = outputLabel.attributedText?.string ?? outputLabel.text ?? ""
                outputDidTextChange = prevOutputRendered != nextRendered

                ToolRowTextRenderer.applyANSIOutputPresentation(
                    presentation,
                    to: outputLabel,
                    plainTextColor: outputColor
                )
                outputRenderSignature = signature
                outputRenderedText = unwrapped ? nextRendered : nil
            }

            if unwrapped {
                outputLabel.textContainer.lineBreakMode = .byClipping
                outputScrollView.alwaysBounceHorizontal = true
                outputScrollView.showsHorizontalScrollIndicator = true
                outputUsesUnwrappedLayout = true
            } else {
                outputLabel.textContainer.lineBreakMode = .byCharWrapping
                outputScrollView.alwaysBounceHorizontal = false
                outputScrollView.showsHorizontalScrollIndicator = false
                outputUsesUnwrappedLayout = false
                outputRenderedText = nil
            }
            outputViewportHeightConstraint?.isActive = true
            outputUsesViewport = true
            showOutputContainer = true
            if !wasOutputVisible { outputShouldAutoFollow = true }
        } else {
            outputRenderSignature = nil
        }

        // Bash expanded content uses command + output containers only.
        hideExpandedContainer()

        return Visibility(
            showExpandedContainer: false,
            showCommandContainer: showCommandContainer,
            showOutputContainer: showOutputContainer
        )
    }

    static func renderDiffMode(
        lines: [DiffLine],
        path: String?,
        isStreaming: Bool,
        expandedLabel: UITextView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        isCurrentModeDiff: Bool,
        showExpandedLabel: () -> Void,
        setModeDiff: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void
    ) -> Visibility {
        let signature = ToolTimelineRowRenderMetrics.diffSignature(
            lines: lines, path: path, isStreaming: isStreaming
        )
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeDiff
            || expandedLabel.attributedText == nil

        showExpandedLabel()
        if shouldRerender {
            if isStreaming {
                // During streaming, skip expensive per-line syntax highlighting
                // and colored attributed text. Show plain diff markers; the full
                // diff view renders once when the tool completes.
                let plainDiff = lines.map { line in
                    switch line.kind {
                    case .added: "+ \(line.text)"
                    case .removed: "- \(line.text)"
                    case .context: "  \(line.text)"
                    }
                }.joined(separator: "\n")
                expandedLabel.attributedText = nil
                expandedLabel.text = plainDiff
                expandedLabel.textColor = UIColor(.themeFg)
                expandedLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                expandedRenderedText = plainDiff
            } else {
                let diffText = ToolRowTextRenderer.makeDiffAttributedText(lines: lines, filePath: path)
                expandedLabel.text = nil
                expandedLabel.attributedText = diffText
                expandedRenderedText = diffText.string
            }
            expandedRenderSignature = signature
        }

        expandedLabel.textContainer.lineBreakMode = .byClipping
        expandedScrollView.alwaysBounceHorizontal = true
        expandedScrollView.showsHorizontalScrollIndicator = true
        setModeDiff()
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()
        expandedShouldAutoFollow = isStreaming
        if shouldRerender && !isStreaming { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

        return Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    static func renderCodeMode(
        text: String,
        language: SyntaxLanguage?,
        startLine: Int?,
        isStreaming: Bool,
        expandedLabel: UITextView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        isCurrentModeCode: Bool,
        showExpandedLabel: () -> Void,
        setModeCode: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void
    ) -> Visibility {
        let displayText = ToolTimelineRowRenderMetrics.displayOutputText(text)
        let resolvedStartLine = startLine ?? 1
        let signature = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: displayText,
            language: language,
            startLine: resolvedStartLine,
            isStreaming: isStreaming
        )
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeCode
            || expandedLabel.attributedText == nil

        showExpandedLabel()
        if shouldRerender {
            if isStreaming {
                // During streaming, skip expensive syntax highlighting and
                // line-number rendering. Show plain monospace text; the full
                // code view renders once when the tool completes.
                expandedLabel.attributedText = nil
                expandedLabel.text = displayText
                expandedLabel.textColor = UIColor(.themeFg)
                expandedLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            } else {
                let codeText = ToolRowTextRenderer.makeCodeAttributedText(
                    text: displayText,
                    language: language,
                    startLine: resolvedStartLine
                )
                expandedLabel.text = nil
                expandedLabel.attributedText = codeText
            }
            expandedRenderedText = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
            expandedRenderSignature = signature
        }

        expandedLabel.textContainer.lineBreakMode = .byClipping
        expandedScrollView.alwaysBounceHorizontal = true
        expandedScrollView.showsHorizontalScrollIndicator = true
        setModeCode()
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()
        expandedShouldAutoFollow = isStreaming
        if shouldRerender && !isStreaming { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

        return Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    static func renderMarkdownMode(
        text: String,
        isStreaming: Bool,
        expandedMarkdownView: AssistantMarkdownContentView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        wasExpandedVisible: Bool,
        isUsingMarkdownLayout: Bool,
        shouldAutoFollowOnFirstRender: Bool,
        showExpandedMarkdown: () -> Void,
        setModeText: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void,
        scheduleExpandedAutoScrollToBottomIfNeeded: () -> Void
    ) -> Visibility {
        let signature = ToolTimelineRowRenderMetrics.markdownSignature(text)
        let shouldRerender = signature != expandedRenderSignature
            || !isUsingMarkdownLayout
        let previousRenderedText = expandedRenderedText

        showExpandedMarkdown()

        expandedRenderedText = text
        updateExpandedLabelWidthIfNeeded()
        if shouldRerender {
            expandedMarkdownView.apply(configuration: .init(
                content: text,
                isStreaming: isStreaming,
                themeID: ThemeRuntimeState.currentThemeID()
            ))
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        setModeText()
        showExpandedViewport()

        let isStreamingContinuation = previousRenderedText.map { !$0.isEmpty && text.hasPrefix($0) } ?? false

        if !wasExpandedVisible {
            expandedShouldAutoFollow = shouldAutoFollowOnFirstRender
        } else if !shouldAutoFollowOnFirstRender,
                  shouldRerender,
                  !isStreamingContinuation {
            // Cell reuse can carry over a stale auto-follow state + non-zero
            // contentOffset from a previous expanded row. For finalized
            // markdown that does not continue prior streaming content, reset
            // to deterministic top-of-content behavior.
            expandedShouldAutoFollow = false
        }

        if shouldRerender {
            if expandedShouldAutoFollow {
                scheduleExpandedAutoScrollToBottomIfNeeded()
            } else {
                ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
            }
        }

        return Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    static func renderPlotMode(
        spec: PlotChartSpec,
        fallbackText: String?,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        isUsingReadMediaLayout: Bool,
        hasExpandedPlotContentView: Bool,
        showExpandedHostedView: () -> Void,
        installExpandedPlotView: (_ spec: PlotChartSpec, _ fallbackText: String?) -> Void,
        setModeText: () -> Void,
        showExpandedViewport: () -> Void
    ) -> Visibility {
        let signature = ToolTimelineRowRenderMetrics.plotSignature(
            spec: spec,
            fallbackText: fallbackText
        )
        let shouldReinstall = signature != expandedRenderSignature
            || !isUsingReadMediaLayout
            || !hasExpandedPlotContentView

        showExpandedHostedView()
        expandedRenderedText = fallbackText
        if shouldReinstall {
            installExpandedPlotView(spec, fallbackText)
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        setModeText()
        showExpandedViewport()
        expandedShouldAutoFollow = false
        if shouldReinstall { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

        return Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    static func renderReadMediaMode(
        output: String,
        filePath: String?,
        startLine: Int,
        isError: Bool,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        isUsingReadMediaLayout: Bool,
        hasExpandedReadMediaContentView: Bool,
        showExpandedHostedView: () -> Void,
        installExpandedReadMediaView: (_ output: String, _ isError: Bool, _ filePath: String?, _ startLine: Int) -> Void,
        setModeText: () -> Void,
        showExpandedViewport: () -> Void
    ) -> Visibility {
        let signature = ToolTimelineRowRenderMetrics.readMediaSignature(
            output: output,
            filePath: filePath,
            startLine: startLine,
            isError: isError
        )
        let shouldReinstall = signature != expandedRenderSignature
            || !isUsingReadMediaLayout
            || !hasExpandedReadMediaContentView

        showExpandedHostedView()
        expandedRenderedText = output
        if shouldReinstall {
            installExpandedReadMediaView(output, isError, filePath, startLine)
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        setModeText()
        showExpandedViewport()
        expandedShouldAutoFollow = false
        if shouldReinstall { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

        return Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    static func renderTextMode(
        text: String,
        language: SyntaxLanguage?,
        isError: Bool,
        isStreaming: Bool,
        outputColor: UIColor,
        expandedLabel: UITextView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        wasExpandedVisible: Bool,
        isCurrentModeText: Bool,
        isUsingMarkdownLayout: Bool,
        isUsingReadMediaLayout: Bool,
        shouldAutoFollowOnFirstRender: Bool,
        showExpandedLabel: () -> Void,
        setModeText: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void,
        scheduleExpandedAutoScrollToBottomIfNeeded: () -> Void
    ) -> Visibility {
        let displayText = ToolTimelineRowRenderMetrics.displayOutputText(text)
        let signature = ToolTimelineRowRenderMetrics.textSignature(
            displayText: displayText,
            language: language,
            isError: isError,
            isStreaming: isStreaming
        )
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeText
            || isUsingMarkdownLayout
            || isUsingReadMediaLayout
            || (expandedLabel.attributedText == nil && expandedLabel.text == nil)
        let previousRenderedText = expandedRenderedText

        showExpandedLabel()
        if shouldRerender {
            let presentation: ToolRowTextRenderer.ANSIOutputPresentation
            if isStreaming {
                // During streaming, skip expensive ANSI/syntax parsing — show
                // stripped plain text. Highlighting applies once when done.
                presentation = ToolRowTextRenderer.ANSIOutputPresentation(
                    attributedText: nil,
                    plainText: ANSIParser.strip(displayText)
                )
            } else if let language, !isError {
                presentation = ToolRowTextRenderer.makeSyntaxOutputPresentation(
                    displayText,
                    language: language
                )
            } else {
                presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
                    displayText,
                    isError: isError
                )
            }

            ToolRowTextRenderer.applyANSIOutputPresentation(
                presentation,
                to: expandedLabel,
                plainTextColor: outputColor
            )
            expandedRenderedText = presentation.attributedText?.string ?? presentation.plainText ?? ""
            expandedRenderSignature = signature
        }

        expandedLabel.textContainer.lineBreakMode = .byCharWrapping
        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        setModeText()
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()

        let isStreamingContinuation = previousRenderedText.map { !$0.isEmpty && displayText.hasPrefix($0) } ?? false

        if !wasExpandedVisible {
            expandedShouldAutoFollow = shouldAutoFollowOnFirstRender
        } else if !shouldAutoFollowOnFirstRender,
                  shouldRerender,
                  !isStreamingContinuation {
            // Cell reuse can leave expanded text rows at a stale bottom offset.
            // Finalized content that is not a continuation of prior streaming
            // output should reopen at top.
            expandedShouldAutoFollow = false
        }

        if shouldRerender {
            if expandedShouldAutoFollow {
                scheduleExpandedAutoScrollToBottomIfNeeded()
            } else {
                ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView)
            }
        }

        return Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }
}
