import UIKit
import SwiftUI

/// Builds `ToolTimelineRowConfiguration` from a `ChatItem.toolCall`.
///
/// Extracted from `ChatTimelineCollectionHost.Controller.toolRowConfiguration()`
/// so per-tool rendering logic is isolated and testable.
enum ToolPresentationBuilder {

    typealias ToolMediaAttachment = ToolContentMediaAttachment

    // MARK: - Dependencies

    struct Context {
        let args: [String: JSONValue]?
        let details: JSONValue?
        let expandedItemIDs: Set<String>
        let fullOutput: String
        let isLoadingOutput: Bool
        let callSegments: [StyledSegment]?
        let resultSegments: [StyledSegment]?
        let startedAt: Date?
        let elapsedSeconds: Int?

        init(
            args: [String: JSONValue]?,
            details: JSONValue? = nil,
            expandedItemIDs: Set<String>,
            fullOutput: String,
            isLoadingOutput: Bool,
            callSegments: [StyledSegment]? = nil,
            resultSegments: [StyledSegment]? = nil,
            startedAt: Date? = nil,
            elapsedSeconds: Int? = nil
        ) {
            self.args = args
            self.details = details
            self.expandedItemIDs = expandedItemIDs
            self.fullOutput = fullOutput
            self.isLoadingOutput = isLoadingOutput
            self.callSegments = callSegments
            self.resultSegments = resultSegments
            self.startedAt = startedAt
            self.elapsedSeconds = elapsedSeconds
        }
    }

    // MARK: - Build

    static func build(
        itemID: String,
        tool: String,
        argsSummary: String,
        outputPreview: String,
        isError: Bool,
        isDone: Bool,
        isInterrupted: Bool = false,
        context: Context
    ) -> ToolTimelineRowConfiguration {
        let normalizedTool = ToolCallFormatting.normalized(tool)
        let isExpanded = context.expandedItemIDs.contains(itemID)
        let args = context.args

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
            details: context.details,
            isExpanded: isExpanded,
            isError: isError,
            isDone: isDone,
            outputPreview: outputPreview
        )

        let isBuiltInFileTool = normalizedTool == "read" || normalizedTool == "write" || normalizedTool == "edit"
        let isVoicePresentationResult = Self.toolAudioPresentationDetails(from: context.details) != nil

        // Expanded presentation
        let expanded: ExpandedPresentation
        if isExpanded || isVoicePresentationResult {
            expanded = buildExpanded(
                normalizedTool: normalizedTool,
                rawToolName: tool,
                args: args,
                details: context.details,
                argsSummary: argsSummary,
                fullOutput: context.fullOutput,
                outputPreview: outputPreview,
                isError: isError,
                isDone: isDone,
                isLoadingOutput: context.isLoadingOutput
            )
        } else {
            expanded = ExpandedPresentation()
        }

        // Trailing (built-in tools only; extension tools use resultSegments)
        let trailing: String?
        if isInterrupted {
            trailing = String(localized: "Interrupted")
        } else if let editTrailingFallback = collapsed.editTrailingFallback {
            trailing = editTrailingFallback
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
        let shouldCapTitleLength = !(normalizedTool == "read" || normalizedTool == "write" || normalizedTool == "edit")
        if shouldCapTitleLength, title.count > 240 {
            title = String(title.prefix(239)) + "…"
        }

        // Collapsed rows should stay file-like, even for image reads.
        // Inline media belongs in the expanded renderer, not the header.

        // Server-rendered segments: build attributed title and trailing.
        // For tools with SF Symbol icons (read, write, edit, bash), the first
        // bold segment is the tool name — strip it since the icon already
        // represents the tool. Generic extension tools keep the name in the
        // title per their non-segment fallback behavior.
        //
        // Expanded bash rows render a dedicated command panel, so we suppress
        // segment title commands there to avoid duplicate command text.
        let segmentAttributedTitle: NSAttributedString?
        if isVoicePresentationResult || isBuiltInFileTool || normalizedTool == "ask" || (isExpanded && normalizedTool == "bash") {
            segmentAttributedTitle = nil
        } else if let callSegs = context.callSegments, !callSegs.isEmpty {
            let prefix = SegmentRenderer.toolNamePrefix(from: callSegs)
            if Self.toolPrefixIconReplacesName(prefix) {
                segmentAttributedTitle = SegmentRenderer.attributedStringStrippingPrefix(from: callSegs)
            } else {
                segmentAttributedTitle = SegmentRenderer.attributedString(from: callSegs)
            }
        } else {
            segmentAttributedTitle = nil
        }

        let segmentAttributedTrailing: NSAttributedString?
        if isInterrupted {
            segmentAttributedTrailing = nil
        } else if let resultSegs = context.resultSegments, !resultSegs.isEmpty {
            segmentAttributedTrailing = SegmentRenderer.trailingAttributedString(from: resultSegs)
        } else {
            segmentAttributedTrailing = nil
        }

        let segmentToolNamePrefix = SegmentRenderer.toolNamePrefix(from: context.callSegments ?? [])
        let segmentToolNameColor = SegmentRenderer.toolNameColor(from: context.callSegments ?? [])

        return ToolTimelineRowConfiguration(
            itemID: itemID,
            title: title,
            preview: nil, // collapsed tool rows single-line
            expandedContent: expanded.content,
            copyCommandText: expanded.copyCommandText,
            copyOutputText: expanded.copyOutputText,
            languageBadge: isVoicePresentationResult ? nil : languageBadge,
            trailing: segmentAttributedTrailing != nil ? nil : trailing,
            titleLineBreakMode: segmentAttributedTitle != nil ? .byTruncatingTail : collapsed.titleLineBreakMode,
            toolNamePrefix: segmentAttributedTitle != nil
                ? (segmentToolNamePrefix ?? collapsed.toolNamePrefix)
                : collapsed.toolNamePrefix,
            toolNameColor: segmentAttributedTitle != nil
                ? (segmentToolNameColor ?? collapsed.toolNameColor)
                : collapsed.toolNameColor,
            editAdded: isInterrupted ? nil : collapsed.editAdded,
            editRemoved: isInterrupted ? nil : collapsed.editRemoved,
            collapsedImageBase64: nil,
            collapsedImageMimeType: nil,
            isExpanded: isExpanded,
            isDone: isDone,
            isError: isError,
            isInterrupted: isInterrupted,
            startedAt: isVoicePresentationResult ? nil : context.startedAt,
            elapsedSeconds: isVoicePresentationResult ? nil : context.elapsedSeconds,
            segmentAttributedTitle: segmentAttributedTitle,
            segmentAttributedTrailing: segmentAttributedTrailing
        )
    }

    // MARK: - Collapsed Presentation

    private struct CollapsedPresentation {
        var title: String
        var toolNamePrefix: String?
        var toolNameColor = UIColor(Color.themeCyan)
        var titleLineBreakMode: NSLineBreakMode = .byTruncatingTail
        var languageBadge: String?
        var editAdded: Int?
        var editRemoved: Int?
        var editTrailingFallback: String?
    }

    // periphery:ignore:parameters isError,outputPreview
    private static func buildCollapsed(
        normalizedTool: String,
        tool: String,
        args: [String: JSONValue]?,
        argsSummary: String,
        details: JSONValue?,
        isExpanded: Bool,
        isError: Bool,
        isDone: Bool,
        outputPreview: String
    ) -> CollapsedPresentation {
        var result = CollapsedPresentation(title: tool)

        switch normalizedTool {
        case "bash":
            let compactCommand = ToolCallFormatting.bashCommand(args: args, argsSummary: argsSummary)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isExpanded {
                // Expanded bash rows already have a dedicated command panel.
                // Keep the header icon-only ("$" symbol) and reserve line
                // height with a single space so body content doesn't shift up.
                result.title = " "
            } else {
                result.title = compactCommand.isEmpty ? "bash" : compactCommand
                result.titleLineBreakMode = .byTruncatingMiddle
            }
            result.toolNamePrefix = "$"
            result.toolNameColor = UIColor(Color.themeGreen)

            // Detect embedded languages (heredocs, inline flags) for badge.
            // Use the full raw command because heredoc detection relies on
            // newlines and may appear after the 200-char collapsed title limit.
            let rawCommand = ToolCallFormatting.bashCommandFull(args: args, argsSummary: argsSummary)
            if !rawCommand.isEmpty {
                let segments = BashEmbeddedLanguageDetector.detect(rawCommand)
                if let embedded = segments.first(where: {
                    if case .embeddedCode = $0.kind { return true }
                    return false
                }), case .embeddedCode(let lang) = embedded.kind {
                    result.languageBadge = lang.displayName
                }
            }

        case "read", "write", "edit":
            let displayPath = ToolCallFormatting.displayFilePath(
                tool: normalizedTool, args: args, argsSummary: argsSummary
            )
            let fileMetadata = filePresentationMetadata(args: args, argsSummary: argsSummary)
            result.toolNamePrefix = normalizedTool
            result.toolNameColor = UIColor(Color.themeCyan)

            if normalizedTool == "read",
               !isExpanded,
               let compactTitle = ToolCallFormatting.compactReadDisplayTitle(
                   tool: normalizedTool,
                   args: args,
                   argsSummary: argsSummary
               ) {
                result.title = compactTitle
                result.titleLineBreakMode = .byTruncatingTail
                result.languageBadge = nil
            } else {
                result.title = displayPath.isEmpty ? normalizedTool : displayPath
                result.titleLineBreakMode = .byTruncatingMiddle

                if fileMetadata.fileType == .markdown || fileMetadata.fileType == .image {
                    result.languageBadge = fileMetadata.fileType?.displayLabel
                } else {
                    result.languageBadge = fileMetadata.language?.displayName
                }
            }

            if normalizedTool == "edit" {
                if !isDone {
                    result.editTrailingFallback = "editing"
                } else if let stats = ToolCallFormatting.editDiffStats(from: args) {
                    result.editAdded = stats.added
                    result.editRemoved = stats.removed
                } else if let lines = ToolCallFormatting.editResultDiffLines(from: details) {
                    let stats = DiffEngine.stats(lines)
                    result.editAdded = stats.added
                    result.editRemoved = stats.removed
                } else {
                    result.editTrailingFallback = "modified"
                }
            }

        case "ask":
            result.title = ToolCallFormatting.askCollapsedTitle(
                args: args,
                details: details,
                argsSummary: argsSummary
            )
            result.toolNamePrefix = "ask"
            result.toolNameColor = UIColor(Color.themeCyan)
            result.titleLineBreakMode = .byTruncatingTail

        default:
            // Extension tools are rendered via server-provided StyledSegments.
            // This default case is the fallback when segments aren't available.
            if Self.toolAudioPresentationDetails(from: details) != nil {
                result.title = "Voice message"
                result.languageBadge = nil
                result.toolNamePrefix = normalizedTool
                result.toolNameColor = UIColor(Color.themePurple)
            } else {
                result.title = argsSummary.isEmpty ? tool : "\(tool) \(argsSummary)"
                result.toolNamePrefix = tool
                result.toolNameColor = UIColor(Color.themeCyan)
            }
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
        /// Unified diff (edit)
        case diff(lines: [DiffLine], path: String?)
        /// Code viewer with line numbers, syntax highlighting, horizontal scroll
        case code(text: String, language: SyntaxLanguage?, startLine: Int?, filePath: String?)
        /// Rendered markdown (read .md)
        case markdown(text: String)
        /// Media renderer for images/audio in read output
        case readMedia(output: String, filePath: String?, startLine: Int, attachments: [ToolMediaAttachment])
        /// Audio message card with server-owned session attachment replay.
        case audioMessage(text: String, attachmentId: String, mimeType: String, durationSeconds: Double?, playbackBehavior: AudioPlaybackBehavior?)
        /// Lightweight non-copyable placeholder while an expanded tool has no body yet.
        case status(message: String)
        /// Plain/ANSI text with optional syntax highlighting
        case text(text: String, language: SyntaxLanguage?)
    }

    struct ExpandedPresentation {
        var content: ToolExpandedContent?
        var copyCommandText: String?
        var copyOutputText: String?
    }

    private static func buildExpanded(
        normalizedTool _: String,
        rawToolName: String,
        args: [String: JSONValue]?,
        details: JSONValue?,
        argsSummary: String,
        fullOutput: String,
        outputPreview: String,
        isError: Bool,
        isDone: Bool,
        isLoadingOutput: Bool
    ) -> ExpandedPresentation {
        let presentation = ToolContentDescriptorBuilder.build(
            tool: rawToolName,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            context: ToolContentDescriptorBuilder.Context(
                args: args,
                details: details,
                fullOutput: fullOutput,
                isLoadingOutput: isLoadingOutput
            )
        )
        return ExpandedPresentation(
            content: presentation.content.map(expandedContent(from:)),
            copyCommandText: presentation.copyCommandText,
            copyOutputText: presentation.copyOutputText
        )
    }

    /// Maps the shared semantic descriptor onto iOS expanded paint cases.
    /// Collapsed UIKit configuration stays in this builder.
    private static func expandedContent(from descriptor: ToolContentDescriptor) -> ToolExpandedContent {
        switch descriptor {
        case .terminal(let terminal):
            if terminal.unwrapped {
                return .bash(
                    command: terminal.command,
                    output: terminal.output,
                    unwrapped: true
                )
            }
            return .text(text: terminal.output ?? "", language: terminal.language)
        case .diff(let diff):
            return .diff(lines: diff.lines, path: diff.path)
        case .code(let code):
            return .code(
                text: code.text,
                language: code.language,
                startLine: code.startLine,
                filePath: code.filePath
            )
        case .markdown(let markdown):
            return .markdown(text: markdown.text)
        case .file(let file):
            return expandedFileContent(
                text: file.text,
                metadata: FilePresentationMetadata(
                    filePath: file.filePath,
                    fileType: file.fileType,
                    language: file.language
                ),
                startLine: file.startLine ?? 1,
                attachments: file.attachments
            )
        case .media(let media):
            if let audio = media.audio {
                if audio.mimeType != "audio/wav" {
                    let message = "Audio unavailable on iOS: unsupported MIME type \(audio.mimeType)"
                    return .readMedia(
                        output: message,
                        filePath: media.filePath ?? "Voice message",
                        startLine: 1,
                        attachments: []
                    )
                }
                return .audioMessage(
                    text: audio.text,
                    attachmentId: audio.attachmentId,
                    mimeType: audio.mimeType,
                    durationSeconds: audio.durationSeconds,
                    playbackBehavior: audio.playbackBehavior
                )
            }
            return .readMedia(
                output: media.output,
                filePath: media.filePath,
                startLine: media.startLine,
                attachments: media.attachments
            )
        case .status(let message):
            return .status(message: message)
        }
    }

    // MARK: - Helpers (moved from Coordinator)

    /// Tools whose icon replaces the textual tool name in collapsed title rendering.
    private static func toolPrefixIconReplacesName(_ prefix: String?) -> Bool {
        switch prefix {
        case "$", "read", "write", "edit", "ask", "voice_speak", "voice_create": true
        default: false
        }
    }

    private struct FilePresentationMetadata {
        let filePath: String?
        let fileType: FileType?
        let language: SyntaxLanguage?
    }

    private static func filePresentationMetadata(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> FilePresentationMetadata {
        let metadata = ToolContentDescriptorBuilder.fileMetadata(args: args, argsSummary: argsSummary)
        return FilePresentationMetadata(
            filePath: metadata.filePath,
            fileType: metadata.fileType,
            language: metadata.language
        )
    }

    private static func expandedFileContent(
        text: String,
        metadata: FilePresentationMetadata,
        startLine: Int,
        attachments: [ToolMediaAttachment]
    ) -> ToolExpandedContent {
        switch metadata.fileType {
        case .markdown:
            return .markdown(text: text)
        case .orgMode:
            return .markdown(text: orgToMarkdown(text))
        case .image, .audio, .video:
            return .readMedia(
                output: text,
                filePath: metadata.filePath,
                startLine: startLine,
                attachments: attachments
            )
        case .html, .plain, .code, .json, .pdf, .binary,
             .latex, .mermaid, .graphviz, .none:
            return .code(
                text: text,
                language: metadata.language,
                startLine: startLine,
                filePath: metadata.filePath
            )
        }
    }

    static func shouldWarnInlineMediaForToolOutput(
        normalizedTool: String,
        outputPreview: String,
        fullOutput: String
    ) -> Bool {
        let tool = ToolCallFormatting.normalized(normalizedTool)
        switch tool {
        case "bash", "read", "write", "edit":
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
        ToolContentDescriptorBuilder.readOutputFileType(args: args, argsSummary: argsSummary)
    }

    /// Convert org mode source text to markdown for the `.markdown` render pipeline.
    /// Uses the shared DocumentRenderPipeline conversion.
    private static func orgToMarkdown(_ orgText: String) -> String {
        DocumentRenderPipeline.orgToMarkdown(orgText)
    }

    // periphery:ignore - used by ToolPresentationBuilderTests via @testable import
    static func readOutputLanguage(args: [String: JSONValue]?, argsSummary: String) -> SyntaxLanguage? {
        ToolContentDescriptorBuilder.readOutputLanguage(args: args, argsSummary: argsSummary)
    }

    static func toolAudioPresentationDetails(
        from details: JSONValue?
    ) -> ToolContentDescriptorBuilder.AudioPresentation? {
        ToolContentDescriptorBuilder.audioPresentation(from: details)
    }

    static func toolImageAttachmentDetails(
        from details: JSONValue?
    ) -> ToolContentDescriptorBuilder.ImageAttachment? {
        ToolContentDescriptorBuilder.imageAttachment(from: details)
    }

    static func mediaAttachmentDetails(from details: JSONValue?) -> [ToolMediaAttachment] {
        ToolContentDescriptorBuilder.mediaAttachments(from: details)
    }
}
