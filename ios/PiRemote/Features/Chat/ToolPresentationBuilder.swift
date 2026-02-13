import UIKit
import SwiftUI

/// Builds `ToolTimelineRowConfiguration` from a `ChatItem.toolCall`.
///
/// Extracted from `ChatTimelineCollectionView.Coordinator.nativeToolConfiguration()`
/// so per-tool rendering logic is isolated and testable.
enum ToolPresentationBuilder {

    // MARK: - Dependencies

    struct Context {
        let args: [String: JSONValue]?
        let expandedItemIDs: Set<String>
        let fullOutput: String
        let isLoadingOutput: Bool
    }

    // MARK: - Build

    static func build(
        itemID: String,
        tool: String,
        argsSummary: String,
        outputPreview: String,
        isError: Bool,
        isDone: Bool,
        context: Context
    ) -> ToolTimelineRowConfiguration {
        let normalizedTool = ToolCallFormatting.normalized(tool)
        let isExpanded = context.expandedItemIDs.contains(itemID)
        let outputForFormatting = context.fullOutput.isEmpty ? outputPreview : context.fullOutput
        let args = context.args

        let todoMutationDiff = normalizedTool == "todo"
            ? ToolCallFormatting.todoMutationDiffPresentation(args: args, argsSummary: argsSummary)
            : nil
        let todoPresentation = normalizedTool == "todo"
            ? ToolCallFormatting.todoOutputPresentation(args: args, argsSummary: argsSummary, output: outputForFormatting)
            : nil

        let hasInlineMediaDataURI = shouldWarnInlineMediaForToolOutput(
            normalizedTool: normalizedTool,
            outputPreview: outputPreview,
            fullOutput: context.fullOutput
        )

        // Collapsed presentation
        let collapsed = buildCollapsed(
            normalizedTool: normalizedTool,
            tool: tool,
            args: args,
            argsSummary: argsSummary,
            isExpanded: isExpanded,
            isError: isError,
            outputPreview: outputPreview,
            todoMutationDiff: todoMutationDiff,
            todoPresentation: todoPresentation
        )

        // Expanded presentation
        let expanded = isExpanded
            ? buildExpanded(
                normalizedTool: normalizedTool,
                args: args,
                argsSummary: argsSummary,
                fullOutput: context.fullOutput,
                outputPreview: outputPreview,
                isError: isError,
                isDone: isDone,
                isLoadingOutput: context.isLoadingOutput,
                todoMutationDiff: todoMutationDiff,
                todoPresentation: todoPresentation
            )
            : ExpandedPresentation()

        // Trailing
        let trailing: String?
        if let editTrailingFallback = collapsed.editTrailingFallback {
            trailing = editTrailingFallback
        } else if normalizedTool == "todo",
                  todoMutationDiff == nil,
                  let todoTrailing = todoPresentation?.trailing,
                  !todoTrailing.isEmpty {
            trailing = todoTrailing
        } else {
            trailing = nil
        }

        // Language badge
        var languageBadge = collapsed.languageBadge
        if hasInlineMediaDataURI {
            if let existingBadge = languageBadge, !existingBadge.isEmpty {
                languageBadge = "\(existingBadge) • ⚠︎media"
            } else {
                languageBadge = "⚠︎media"
            }
        }

        var title = collapsed.title
        if title.count > 240 {
            title = String(title.prefix(239)) + "…"
        }

        return ToolTimelineRowConfiguration(
            title: title,
            preview: nil, // collapsed tool rows single-line
            expandedText: expanded.text,
            expandedTextUsesMarkdown: expanded.textUsesMarkdown,
            expandedDiffLines: expanded.diffLines,
            expandedDiffPath: expanded.diffPath,
            expandedCommandText: expanded.commandText,
            expandedOutputText: expanded.outputText,
            expandedOutputLanguage: expanded.outputLanguage,
            expandedCodeStartLine: expanded.codeStartLine,
            expandedCodeFilePath: expanded.codeFilePath,
            expandedUsesReadMediaRenderer: expanded.usesReadMediaRenderer,
            prefersUnwrappedOutput: expanded.prefersUnwrappedOutput,
            showSeparatedCommandAndOutput: expanded.showSeparatedCommandAndOutput,
            copyCommandText: expanded.copyCommandText,
            copyOutputText: expanded.copyOutputText,
            languageBadge: languageBadge,
            trailing: trailing,
            titleLineBreakMode: collapsed.titleLineBreakMode,
            toolNamePrefix: collapsed.toolNamePrefix,
            toolNameColor: collapsed.toolNameColor,
            editAdded: collapsed.editAdded,
            editRemoved: collapsed.editRemoved,
            isExpanded: isExpanded,
            isDone: isDone,
            isError: isError
        )
    }

    // MARK: - Collapsed Presentation

    private struct CollapsedPresentation {
        var title: String
        var toolNamePrefix: String?
        var toolNameColor: UIColor = UIColor(Color.tokyoCyan)
        var titleLineBreakMode: NSLineBreakMode = .byTruncatingTail
        var languageBadge: String?
        var editAdded: Int?
        var editRemoved: Int?
        var editTrailingFallback: String?
    }

    private static func buildCollapsed(
        normalizedTool: String,
        tool: String,
        args: [String: JSONValue]?,
        argsSummary: String,
        isExpanded: Bool,
        isError: Bool,
        outputPreview: String,
        todoMutationDiff: ToolCallFormatting.TodoMutationDiffPresentation?,
        todoPresentation: ToolCallFormatting.TodoOutputPresentation?
    ) -> CollapsedPresentation {
        var result = CollapsedPresentation(title: tool)

        switch normalizedTool {
        case "bash":
            let compactCommand = ToolCallFormatting.bashCommand(args: args, argsSummary: argsSummary)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isExpanded {
                result.title = "bash"
            } else {
                result.title = compactCommand.isEmpty ? "bash" : compactCommand
                result.titleLineBreakMode = .byTruncatingMiddle
            }
            result.toolNamePrefix = "$"
            result.toolNameColor = UIColor(Color.tokyoGreen)

        case "read", "write", "edit":
            let displayPath = ToolCallFormatting.displayFilePath(
                tool: normalizedTool, args: args, argsSummary: argsSummary
            )
            result.title = displayPath.isEmpty ? normalizedTool : displayPath
            result.toolNamePrefix = normalizedTool
            result.toolNameColor = UIColor(Color.tokyoCyan)
            result.titleLineBreakMode = .byTruncatingMiddle

            if normalizedTool == "read" {
                if let fileType = readOutputFileType(args: args, argsSummary: argsSummary),
                   fileType == .markdown {
                    result.languageBadge = fileType.displayLabel
                } else {
                    result.languageBadge = readOutputLanguage(args: args, argsSummary: argsSummary)?.displayName
                }
            }

            if normalizedTool == "edit" {
                if let stats = ToolCallFormatting.editDiffStats(from: args) {
                    result.editAdded = stats.added
                    result.editRemoved = stats.removed
                } else {
                    result.editTrailingFallback = "modified"
                }
            }

        case "todo":
            let summary = ToolCallFormatting.todoSummary(args: args, argsSummary: argsSummary)
            result.title = summary.isEmpty ? "todo" : "todo \(summary)"
            result.toolNamePrefix = "todo"
            result.toolNameColor = UIColor(Color.tokyoPurple)
            if let todoMutationDiff {
                result.editAdded = todoMutationDiff.addedLineCount
                result.editRemoved = todoMutationDiff.removedLineCount
            }

        default:
            result.title = argsSummary.isEmpty ? tool : "\(tool) \(argsSummary)"
            result.toolNamePrefix = tool
            result.toolNameColor = UIColor(Color.tokyoCyan)
        }

        return result
    }

    // MARK: - Expanded Presentation

    struct ExpandedPresentation {
        var text: String?
        var textUsesMarkdown: Bool = false
        var diffLines: [DiffLine]?
        var diffPath: String?
        var commandText: String?
        var outputText: String?
        var outputLanguage: SyntaxLanguage?
        var codeStartLine: Int?
        var codeFilePath: String?
        var usesReadMediaRenderer: Bool = false
        var prefersUnwrappedOutput: Bool = false
        var showSeparatedCommandAndOutput: Bool = false
        var copyCommandText: String?
        var copyOutputText: String?
    }

    private static func buildExpanded(
        normalizedTool: String,
        args: [String: JSONValue]?,
        argsSummary: String,
        fullOutput: String,
        outputPreview: String,
        isError: Bool,
        isDone: Bool,
        isLoadingOutput: Bool,
        todoMutationDiff: ToolCallFormatting.TodoMutationDiffPresentation?,
        todoPresentation: ToolCallFormatting.TodoOutputPresentation?
    ) -> ExpandedPresentation {
        var result = ExpandedPresentation()
        let output = fullOutput.isEmpty ? outputPreview : fullOutput
        let outputTrimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        result.copyOutputText = outputTrimmed.isEmpty ? nil : outputTrimmed

        switch normalizedTool {
        case "bash":
            let command = ToolCallFormatting.bashCommandFull(args: args, argsSummary: argsSummary)
            result.copyCommandText = command.isEmpty ? nil : command
            result.commandText = command.isEmpty ? nil : command
            result.outputText = outputTrimmed.isEmpty ? nil : outputTrimmed
            result.prefersUnwrappedOutput = true
            result.showSeparatedCommandAndOutput = true

        case "read":
            if !outputTrimmed.isEmpty {
                result.text = outputTrimmed
                let readFileType = readOutputFileType(args: args, argsSummary: argsSummary)
                result.outputLanguage = readOutputLanguage(args: args, argsSummary: argsSummary)
                if readFileType == .markdown {
                    result.textUsesMarkdown = true
                } else if readFileType == .image {
                    result.usesReadMediaRenderer = true
                } else {
                    result.codeStartLine = ToolCallFormatting.readStartLine(from: args)
                }
                result.codeFilePath = ToolCallFormatting.filePath(from: args)
                    ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
            } else if isLoadingOutput {
                result.text = "Loading read output…"
            } else if isDone {
                result.text = "Waiting for output…"
            }

        case "write":
            if !outputTrimmed.isEmpty {
                result.text = outputTrimmed
                result.outputLanguage = readOutputLanguage(args: args, argsSummary: argsSummary)
                result.codeFilePath = ToolCallFormatting.filePath(from: args)
                    ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
            }

        case "edit":
            if !isError,
               let editText = ToolCallFormatting.editOldAndNewText(from: args) {
                let lines = DiffEngine.compute(old: editText.oldText, new: editText.newText)
                result.diffLines = lines
                result.diffPath = ToolCallFormatting.displayFilePath(
                    tool: normalizedTool, args: args, argsSummary: argsSummary
                )
                result.copyOutputText = DiffEngine.formatUnified(lines)
            } else if !outputTrimmed.isEmpty {
                result.text = outputTrimmed
                result.outputLanguage = readOutputLanguage(args: args, argsSummary: argsSummary)
                result.codeFilePath = ToolCallFormatting.filePath(from: args)
                    ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
            }

        case "todo":
            if let todoMutationDiff {
                result.diffLines = todoMutationDiff.diffLines
                result.copyOutputText = todoMutationDiff.unifiedText
            } else if let todoPresentation {
                result.text = todoPresentation.text
                result.textUsesMarkdown = todoPresentation.usesMarkdown
            } else if !outputTrimmed.isEmpty {
                result.text = outputTrimmed
            }

        default:
            if !outputTrimmed.isEmpty {
                result.text = outputTrimmed
            }
        }

        return result
    }

    // MARK: - Helpers (moved from Coordinator)

    static func shouldWarnInlineMediaForToolOutput(
        normalizedTool: String,
        outputPreview: String,
        fullOutput: String
    ) -> Bool {
        let tool = ToolCallFormatting.normalized(normalizedTool)
        switch tool {
        case "bash", "read", "write", "edit", "todo":
            return false
        default:
            break
        }

        let outputSample = fullOutput.isEmpty ? outputPreview : fullOutput
        guard !outputSample.isEmpty else { return false }
        return containsInlineMediaDataURI(outputSample)
    }

    private static func containsInlineMediaDataURI(_ text: String) -> Bool {
        text.range(of: "data:image/", options: .caseInsensitive) != nil
            || text.range(of: "data:audio/", options: .caseInsensitive) != nil
    }

    static func readOutputFileType(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> FileType? {
        let filePath = ToolCallFormatting.filePath(from: args)
            ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
            ?? inferredPathFromSummary(argsSummary)
        guard let filePath, !filePath.isEmpty else { return nil }
        return FileType.detect(from: filePath)
    }

    private static func inferredPathFromSummary(_ argsSummary: String) -> String? {
        let trimmed = argsSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withoutToolPrefix: String
        if trimmed.hasPrefix("read ") {
            withoutToolPrefix = String(trimmed.dropFirst(5))
        } else if trimmed.hasPrefix("write ") {
            withoutToolPrefix = String(trimmed.dropFirst(6))
        } else if trimmed.hasPrefix("edit ") {
            withoutToolPrefix = String(trimmed.dropFirst(5))
        } else {
            withoutToolPrefix = trimmed
        }

        let candidate = withoutToolPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if let range = candidate.range(of: #":\d+(?:-\d+)?$"#, options: .regularExpression) {
            return String(candidate[..<range.lowerBound])
        }

        return candidate
    }

    static func readOutputLanguage(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> SyntaxLanguage? {
        guard let fileType = readOutputFileType(args: args, argsSummary: argsSummary) else {
            return nil
        }
        switch fileType {
        case .code(let language): return language
        case .json: return .json
        case .markdown, .image, .audio, .plain: return nil
        }
    }
}
