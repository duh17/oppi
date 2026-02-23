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
        outputColor: UIColor,
        commandTextColor: UIColor,
        wasOutputVisible: Bool,
        commandLabel: UILabel,
        outputLabel: UILabel,
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
                    commandLabel.attributedText = ToolRowTextRenderer.shellHighlighted(displayCmd)
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
                unwrapped: unwrapped
            )

            if signature != outputRenderSignature {
                let presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
                    displayOutput,
                    isError: isError
                )
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
                outputLabel.lineBreakMode = .byClipping
                outputScrollView.alwaysBounceHorizontal = true
                outputScrollView.showsHorizontalScrollIndicator = true
                outputUsesUnwrappedLayout = true
            } else {
                outputLabel.lineBreakMode = .byCharWrapping
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
        expandedLabel: UILabel,
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
        let signature = ToolTimelineRowRenderMetrics.diffSignature(lines: lines, path: path)
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeDiff
            || expandedLabel.attributedText == nil

        showExpandedLabel()
        if shouldRerender {
            let diffText = ToolRowTextRenderer.makeDiffAttributedText(lines: lines, filePath: path)
            expandedLabel.text = nil
            expandedLabel.attributedText = diffText
            expandedRenderedText = diffText.string
            expandedRenderSignature = signature
        }

        expandedLabel.lineBreakMode = .byClipping
        expandedScrollView.alwaysBounceHorizontal = true
        expandedScrollView.showsHorizontalScrollIndicator = true
        setModeDiff()
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()
        expandedShouldAutoFollow = false
        if shouldRerender { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

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
        expandedLabel: UILabel,
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
            startLine: resolvedStartLine
        )
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeCode
            || expandedLabel.attributedText == nil

        showExpandedLabel()
        if shouldRerender {
            let codeText = ToolRowTextRenderer.makeCodeAttributedText(
                text: displayText,
                language: language,
                startLine: resolvedStartLine
            )
            expandedLabel.text = nil
            expandedLabel.attributedText = codeText
            expandedRenderedText = codeText.string
            expandedRenderSignature = signature
        }

        expandedLabel.lineBreakMode = .byClipping
        expandedScrollView.alwaysBounceHorizontal = true
        expandedScrollView.showsHorizontalScrollIndicator = true
        setModeCode()
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()
        expandedShouldAutoFollow = false
        if shouldRerender { ToolTimelineRowUIHelpers.resetScrollPosition(expandedScrollView) }

        return Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    static func renderMarkdownMode(
        text: String,
        expandedMarkdownView: AssistantMarkdownContentView,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        wasExpandedVisible: Bool,
        isUsingMarkdownLayout: Bool,
        showExpandedMarkdown: () -> Void,
        setExpandedContainerTapCopyGestureEnabled: (Bool) -> Void,
        setModeText: () -> Void,
        updateExpandedLabelWidthIfNeeded: () -> Void,
        showExpandedViewport: () -> Void,
        scheduleExpandedAutoScrollToBottomIfNeeded: () -> Void
    ) -> Visibility {
        let signature = ToolTimelineRowRenderMetrics.markdownSignature(text)
        let shouldRerender = signature != expandedRenderSignature
            || !isUsingMarkdownLayout

        showExpandedMarkdown()
        // Markdown expanded content should support native UITextView selection
        // on double-tap across tool surfaces.
        setExpandedContainerTapCopyGestureEnabled(false)

        expandedRenderedText = text
        updateExpandedLabelWidthIfNeeded()
        if shouldRerender {
            expandedMarkdownView.apply(configuration: .init(
                content: text,
                isStreaming: false,
                themeID: ThemeRuntimeState.currentThemeID()
            ))
            expandedRenderSignature = signature
        }

        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        setModeText()
        showExpandedViewport()
        if !wasExpandedVisible { expandedShouldAutoFollow = true }
        if shouldRerender { scheduleExpandedAutoScrollToBottomIfNeeded() }

        return Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }

    static func renderTodoMode(
        output: String,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        isUsingReadMediaLayout: Bool,
        hasExpandedReadMediaContentView: Bool,
        showExpandedHostedView: () -> Void,
        installExpandedTodoView: (String) -> Void,
        setModeText: () -> Void,
        showExpandedViewport: () -> Void
    ) -> Visibility {
        let signature = ToolTimelineRowRenderMetrics.todoSignature(output)
        let shouldReinstall = signature != expandedRenderSignature
            || !isUsingReadMediaLayout
            || !hasExpandedReadMediaContentView

        showExpandedHostedView()
        expandedRenderedText = output
        if shouldReinstall {
            installExpandedTodoView(output)
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
        outputColor: UIColor,
        expandedLabel: UILabel,
        expandedScrollView: UIScrollView,
        expandedRenderSignature: inout Int?,
        expandedRenderedText: inout String?,
        expandedShouldAutoFollow: inout Bool,
        wasExpandedVisible: Bool,
        isCurrentModeText: Bool,
        isUsingMarkdownLayout: Bool,
        isUsingReadMediaLayout: Bool,
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
            isError: isError
        )
        let shouldRerender = signature != expandedRenderSignature
            || !isCurrentModeText
            || isUsingMarkdownLayout
            || isUsingReadMediaLayout
            || (expandedLabel.attributedText == nil && expandedLabel.text == nil)

        showExpandedLabel()
        if shouldRerender {
            let presentation: ToolRowTextRenderer.ANSIOutputPresentation
            if let language, !isError {
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

        expandedLabel.lineBreakMode = .byCharWrapping
        expandedScrollView.alwaysBounceHorizontal = false
        expandedScrollView.showsHorizontalScrollIndicator = false
        setModeText()
        updateExpandedLabelWidthIfNeeded()
        showExpandedViewport()
        if !wasExpandedVisible { expandedShouldAutoFollow = true }
        if shouldRerender { scheduleExpandedAutoScrollToBottomIfNeeded() }

        return Visibility(
            showExpandedContainer: true,
            showCommandContainer: false,
            showOutputContainer: false
        )
    }
}
