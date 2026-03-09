import UIKit

@MainActor
struct ToolRowBashRenderStrategy {
    static func render(
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
    ) -> ToolRowRenderVisibility {
        var showCommandContainer = false
        var showOutputContainer = false
        outputDidTextChange = false

        if let command, !command.isEmpty {
            let displayCmd = ToolTimelineRowRenderMetrics.displayCommandText(command)
            let signature = ToolTimelineRowRenderMetrics.commandSignature(displayCommand: displayCmd)
            if signature != commandRenderSignature {
                let cmdStartNs = ChatTimelinePerf.timestampNs()
                if let cached = ToolRowRenderCache.get(signature: signature) {
                    commandLabel.attributedText = cached
                } else if displayCmd.utf8.count <= ToolRowTextRenderer.maxShellHighlightBytes {
                    let highlighted = ToolRowTextRenderer.bashCommandHighlighted(displayCmd)
                    ToolRowRenderCache.set(signature: signature, attributed: highlighted)
                    commandLabel.attributedText = highlighted
                } else {
                    commandLabel.attributedText = nil
                    commandLabel.text = displayCmd
                    commandLabel.textColor = commandTextColor
                }
                ChatTimelinePerf.recordRenderStrategy(
                    mode: "bash.command",
                    durationMs: ChatTimelinePerf.elapsedMs(since: cmdStartNs),
                    inputBytes: displayCmd.utf8.count
                )
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
                let outputStartNs = ChatTimelinePerf.timestampNs()
                let tier = StreamingRenderPolicy.tier(
                    isStreaming: isStreaming,
                    contentKind: .bash,
                    byteCount: displayOutput.utf8.count,
                    lineCount: 0
                )

                let presentation: ToolRowTextRenderer.ANSIOutputPresentation
                if tier == .cheap {
                    presentation = ToolRowTextRenderer.ANSIOutputPresentation(
                        attributedText: nil,
                        plainText: ANSIParser.strip(displayOutput)
                    )
                } else if let cached = ToolRowRenderCache.get(signature: signature) {
                    presentation = ToolRowTextRenderer.ANSIOutputPresentation(
                        attributedText: cached,
                        plainText: nil
                    )
                } else {
                    let p = ToolRowTextRenderer.makeANSIOutputPresentation(
                        displayOutput,
                        isError: isError
                    )
                    if let attr = p.attributedText {
                        ToolRowRenderCache.set(signature: signature, attributed: attr)
                    }
                    presentation = p
                }
                ChatTimelinePerf.recordRenderStrategy(
                    mode: tier == .cheap ? "bash.output.stream" : "bash.output.ansi",
                    durationMs: ChatTimelinePerf.elapsedMs(since: outputStartNs),
                    inputBytes: displayOutput.utf8.count
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

        hideExpandedContainer()

        return ToolRowRenderVisibility(
            showExpandedContainer: false,
            showCommandContainer: showCommandContainer,
            showOutputContainer: showOutputContainer
        )
    }
}
