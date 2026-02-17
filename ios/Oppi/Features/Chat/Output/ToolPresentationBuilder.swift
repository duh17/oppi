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
        let expanded: ExpandedPresentation
        if isExpanded {
            expanded = buildExpanded(
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
        } else {
            expanded = ExpandedPresentation()
        }

        // Trailing
        let trailing: String?
        if let editTrailingFallback = collapsed.editTrailingFallback {
            trailing = editTrailingFallback
        } else if normalizedTool == "todo",
                  todoMutationDiff == nil,
                  let todoTrailing = todoPresentation?.trailing,
                  !todoTrailing.isEmpty {
            trailing = todoTrailing
        } else if normalizedTool == "remember" {
            trailing = ToolCallFormatting.rememberTrailing(args: args)
        } else if normalizedTool == "recall" {
            trailing = ToolCallFormatting.recallTrailing(output: outputForFormatting)
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

        // Extract first image for collapsed thumbnail (read tool, image files)
        let imagePreview = Self.collapsedImagePreview(
            normalizedTool: normalizedTool,
            args: args,
            argsSummary: argsSummary,
            output: outputForFormatting
        )

        return ToolTimelineRowConfiguration(
            title: title,
            preview: nil, // collapsed tool rows single-line
            expandedContent: expanded.content,
            copyCommandText: expanded.copyCommandText,
            copyOutputText: expanded.copyOutputText,
            languageBadge: languageBadge,
            trailing: trailing,
            titleLineBreakMode: collapsed.titleLineBreakMode,
            toolNamePrefix: collapsed.toolNamePrefix,
            toolNameColor: collapsed.toolNameColor,
            editAdded: collapsed.editAdded,
            editRemoved: collapsed.editRemoved,
            collapsedImageBase64: imagePreview?.base64,
            collapsedImageMimeType: imagePreview?.mimeType,
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

            if normalizedTool == "read" || normalizedTool == "write" {
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
            result.title = summary.isEmpty ? "todo" : summary
            result.toolNamePrefix = "todo"
            result.toolNameColor = UIColor(Color.tokyoPurple)
            if let todoMutationDiff {
                result.editAdded = todoMutationDiff.addedLineCount
                result.editRemoved = todoMutationDiff.removedLineCount
            }

        case "remember":
            let summary = ToolCallFormatting.rememberSummary(args: args, argsSummary: argsSummary)
            result.title = summary
            result.toolNamePrefix = "remember"
            result.toolNameColor = UIColor(Color.tokyoYellow)

        case "recall":
            let summary = ToolCallFormatting.recallSummary(args: args, argsSummary: argsSummary)
            result.title = summary
            result.toolNamePrefix = "recall"
            result.toolNameColor = UIColor(Color.tokyoYellow)

        default:
            result.title = argsSummary.isEmpty ? tool : "\(tool) \(argsSummary)"
            result.toolNamePrefix = tool
            result.toolNameColor = UIColor(Color.tokyoCyan)
        }

        return result
    }

    // MARK: - Expanded Content

    /// Discriminated union for expanded tool content.
    /// Each case carries exactly the data its renderer needs.
    /// Replaces the previous flat struct of 13 boolean/optional fields,
    /// making it impossible to set conflicting rendering modes.
    enum ToolExpandedContent {
        /// Bash: separated command block + scrollable output viewport
        case bash(command: String?, output: String?, unwrapped: Bool)
        /// Unified diff (edit, todo append/update)
        case diff(lines: [DiffLine], path: String?)
        /// Code viewer with line numbers, syntax highlighting, horizontal scroll
        case code(text: String, language: SyntaxLanguage?, startLine: Int?, filePath: String?)
        /// Rendered markdown (read .md, remember)
        case markdown(text: String)
        /// Rich todo card via UIHostingConfiguration
        case todoCard(output: String)
        /// Media renderer via UIHostingConfiguration (images, etc.)
        case readMedia(output: String, filePath: String?, startLine: Int)
        /// Plain/ANSI text with optional syntax highlighting
        case text(text: String, language: SyntaxLanguage?)
    }

    struct ExpandedPresentation {
        var content: ToolExpandedContent?
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
        let output = fullOutput.isEmpty ? outputPreview : fullOutput
        let outputTrimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var copyOutput: String? = outputTrimmed.isEmpty ? nil : outputTrimmed
        var copyCommand: String?
        var content: ToolExpandedContent?

        switch normalizedTool {
        case "bash":
            let command = ToolCallFormatting.bashCommandFull(args: args, argsSummary: argsSummary)
            copyCommand = command.isEmpty ? nil : command
            content = .bash(
                command: command.isEmpty ? nil : command,
                output: outputTrimmed.isEmpty ? nil : outputTrimmed,
                unwrapped: true
            )

        case "read":
            let filePath = ToolCallFormatting.filePath(from: args)
                ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
            if !outputTrimmed.isEmpty {
                let readFileType = readOutputFileType(args: args, argsSummary: argsSummary)
                let language = readOutputLanguage(args: args, argsSummary: argsSummary)
                if readFileType == .markdown {
                    content = .markdown(text: outputTrimmed)
                } else if readFileType == .image {
                    content = .readMedia(
                        output: outputTrimmed,
                        filePath: filePath,
                        startLine: ToolCallFormatting.readStartLine(from: args)
                    )
                } else {
                    content = .code(
                        text: outputTrimmed,
                        language: language,
                        startLine: ToolCallFormatting.readStartLine(from: args),
                        filePath: filePath
                    )
                }
            } else if isLoadingOutput {
                content = .text(text: "Loading read output…", language: nil)
            } else if isDone {
                content = .text(text: "Waiting for output…", language: nil)
            }

        case "write":
            let writeContent = ToolCallFormatting.writeContent(from: args)
            let filePath = ToolCallFormatting.filePath(from: args)
                ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
            if let writeContent, !writeContent.isEmpty {
                copyOutput = writeContent
                let fileType = readOutputFileType(args: args, argsSummary: argsSummary)
                let language = readOutputLanguage(args: args, argsSummary: argsSummary)
                if fileType == .markdown {
                    content = .markdown(text: writeContent)
                } else if fileType == .image {
                    content = .readMedia(output: writeContent, filePath: filePath, startLine: 1)
                } else {
                    content = .code(
                        text: writeContent,
                        language: language,
                        startLine: 1,
                        filePath: filePath
                    )
                }
            } else if !outputTrimmed.isEmpty {
                let language = readOutputLanguage(args: args, argsSummary: argsSummary)
                content = .code(text: outputTrimmed, language: language, startLine: nil, filePath: filePath)
            }

        case "edit":
            if !isError,
               let editText = ToolCallFormatting.editOldAndNewText(from: args) {
                let lines = DiffEngine.compute(old: editText.oldText, new: editText.newText)
                let diffPath = ToolCallFormatting.displayFilePath(
                    tool: normalizedTool, args: args, argsSummary: argsSummary
                )
                content = .diff(lines: lines, path: diffPath)
                copyOutput = DiffEngine.formatUnified(lines)
            } else if !outputTrimmed.isEmpty {
                let language = readOutputLanguage(args: args, argsSummary: argsSummary)
                let filePath = ToolCallFormatting.displayFilePath(
                    tool: normalizedTool, args: args, argsSummary: argsSummary
                )
                content = .code(text: outputTrimmed, language: language, startLine: nil, filePath: filePath)
            }

        case "todo":
            if let todoMutationDiff {
                content = .diff(lines: todoMutationDiff.diffLines, path: nil)
                copyOutput = todoMutationDiff.unifiedText
            } else if !outputTrimmed.isEmpty {
                content = .todoCard(output: outputTrimmed)
            }

        case "remember":
            var parts: [String] = []
            if let text = args?["text"]?.stringValue {
                parts.append(text)
            }
            if let tagsArray = args?["tags"]?.arrayValue {
                let tags = tagsArray.compactMap(\.stringValue).filter { !$0.isEmpty }
                if !tags.isEmpty {
                    parts.append("Tags: \(tags.joined(separator: ", "))")
                }
            }
            if !parts.isEmpty {
                content = .markdown(text: parts.joined(separator: "\n\n"))
            } else if !outputTrimmed.isEmpty {
                content = .text(text: outputTrimmed, language: nil)
            }

        case "recall":
            if !outputTrimmed.isEmpty {
                content = .text(text: outputTrimmed, language: nil)
            }

        default:
            if !outputTrimmed.isEmpty {
                content = .text(text: outputTrimmed, language: nil)
            }
        }

        return ExpandedPresentation(
            content: content,
            copyCommandText: copyCommand,
            copyOutputText: copyOutput
        )
    }

    // MARK: - Helpers (moved from Coordinator)

    static func shouldWarnInlineMediaForToolOutput(
        normalizedTool: String,
        outputPreview: String,
        fullOutput: String
    ) -> Bool {
        let tool = ToolCallFormatting.normalized(normalizedTool)
        switch tool {
        case "bash", "read", "write", "edit", "todo", "remember", "recall":
            return false
        default:
            break
        }

        let outputSample = fullOutput.isEmpty ? outputPreview : fullOutput
        guard !outputSample.isEmpty else { return false }
        return containsInlineMediaDataURI(outputSample)
    }

    /// Extract the first image data URI for collapsed inline preview.
    /// Only returns data for "read" tool calls on image file types.
    private static func collapsedImagePreview(
        normalizedTool: String,
        args: [String: JSONValue]?,
        argsSummary: String,
        output: String
    ) -> (base64: String, mimeType: String)? {
        guard normalizedTool == "read",
              readOutputFileType(args: args, argsSummary: argsSummary) == .image,
              !output.isEmpty else {
            return nil
        }
        guard let first = ImageExtractor.extract(from: output).first else {
            return nil
        }
        return (first.base64, first.mimeType ?? "image/png")
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
