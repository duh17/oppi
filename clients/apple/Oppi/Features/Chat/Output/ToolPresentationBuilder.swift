import UIKit
import SwiftUI

/// Builds `ToolTimelineRowConfiguration` from a `ChatItem.toolCall`.
///
/// Extracted from `ChatTimelineCollectionHost.Controller.toolRowConfiguration()`
/// so per-tool rendering logic is isolated and testable.
enum ToolPresentationBuilder {

    struct ToolMediaAttachment: Equatable, Sendable {
        let kind: String
        let id: String
        let mimeType: String
        let fileName: String?
        let sizeBytes: Int?
        let width: Int?
        let height: Int?
    }

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

        let previewImage = isDone ? Self.toolImageAttachmentDetails(from: context.details) : nil
        let isVoicePresentationResult = Self.toolAudioAttachmentDetails(from: context.details) != nil
            || Self.toolVoicePresentationDetails(from: context.details) != nil

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
        if let editTrailingFallback = collapsed.editTrailingFallback {
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
        let isBuiltInFileTool = normalizedTool == "read" || normalizedTool == "write" || normalizedTool == "edit"
        if isVoicePresentationResult || isBuiltInFileTool || (isExpanded && normalizedTool == "bash") {
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
        if let resultSegs = context.resultSegments, !resultSegs.isEmpty {
            segmentAttributedTrailing = SegmentRenderer.trailingAttributedString(from: resultSegs)
        } else {
            segmentAttributedTrailing = nil
        }

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
                ? SegmentRenderer.toolNamePrefix(from: context.callSegments ?? [])
                : collapsed.toolNamePrefix,
            toolNameColor: segmentAttributedTitle != nil
                ? (SegmentRenderer.toolNameColor(from: context.callSegments ?? []) ?? collapsed.toolNameColor)
                : collapsed.toolNameColor,
            editAdded: collapsed.editAdded,
            editRemoved: collapsed.editRemoved,
            collapsedImageBase64: !isExpanded ? previewImage?.base64 : nil,
            collapsedImageMimeType: !isExpanded ? previewImage?.mimeType : nil,
            isExpanded: isExpanded,
            isDone: isDone,
            isError: isError,
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
            // Use the raw command (not compactCommand) because heredoc detection
            // relies on newlines that whitespace compaction strips.
            let rawCommand = ToolCallFormatting.bashCommand(args: args, argsSummary: argsSummary)
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
            result.title = displayPath.isEmpty ? normalizedTool : displayPath
            result.toolNamePrefix = normalizedTool
            result.toolNameColor = UIColor(Color.themeCyan)
            result.titleLineBreakMode = .byTruncatingMiddle

            if fileMetadata.fileType == .markdown || fileMetadata.fileType == .image {
                result.languageBadge = fileMetadata.fileType?.displayLabel
            } else {
                result.languageBadge = fileMetadata.language?.displayName
            }

            if normalizedTool == "edit" {
                if !isDone {
                    result.editTrailingFallback = "editing"
                } else if let stats = ToolCallFormatting.editDiffStats(from: args) {
                    result.editAdded = stats.added
                    result.editRemoved = stats.removed
                } else {
                    result.editTrailingFallback = "modified"
                }
            }

        default:
            // Extension tools are rendered via server-provided StyledSegments.
            // This default case is the fallback when segments aren't available.
            if Self.toolAudioAttachmentDetails(from: details) != nil
                || Self.toolVoicePresentationDetails(from: details) != nil {
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
        /// Voice message with server-owned session attachment replay.
        case voiceMessage(text: String, attachmentId: String, mimeType: String, durationSeconds: Double?, delivery: VoiceReplyDelivery?)
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
        normalizedTool: String,
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
        let output = fullOutput.isEmpty ? outputPreview : fullOutput
        let outputTrimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileMetadata = filePresentationMetadata(args: args, argsSummary: argsSummary)
        let mediaAttachments = mediaAttachmentDetails(from: details)
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
            if !outputTrimmed.isEmpty || !mediaAttachments.isEmpty {
                let startLine = ToolCallFormatting.readStartLine(from: args)
                content = isDone
                    ? expandedFileContent(
                        text: outputTrimmed,
                        metadata: fileMetadata,
                        startLine: startLine,
                        attachments: mediaAttachments
                    )
                    : expandedStreamingFileContent(
                        text: outputTrimmed,
                        metadata: fileMetadata,
                        startLine: startLine,
                        attachments: mediaAttachments
                    )
            } else if isLoadingOutput {
                content = .status(message: "Loading read output…")
            } else if isDone {
                content = .status(message: "Waiting for output…")
            }

        case "write":
            let writeContent = ToolCallFormatting.writeContent(from: args)
            if let writeContent, !writeContent.isEmpty {
                copyOutput = writeContent
                content = isDone
                    ? expandedFileContent(
                        text: writeContent,
                        metadata: fileMetadata,
                        startLine: 1,
                        attachments: []
                    )
                    : expandedStreamingFileContent(
                        text: writeContent,
                        metadata: fileMetadata,
                        startLine: 1,
                        attachments: []
                    )
            } else if !outputTrimmed.isEmpty {
                content = isDone
                    ? expandedFileCodeFallback(
                        text: outputTrimmed,
                        metadata: fileMetadata,
                        startLine: nil
                    )
                    : .text(text: outputTrimmed, language: nil)
            }

        case "edit":
            if !isError,
               let editText = ToolCallFormatting.editOldAndNewText(from: args) {
                if isDone {
                    let lines = DiffEngine.compute(old: editText.oldText, new: editText.newText)
                    // Use the raw file path (not displayFilePath) so downstream consumers
                    // can fetch the file via API. Display views apply shortenedPath as needed.
                    let diffPath = fileMetadata.filePath
                        ?? ToolCallFormatting.displayFilePath(
                            tool: normalizedTool, args: args, argsSummary: argsSummary
                        )
                    content = .diff(lines: lines, path: diffPath)
                    copyOutput = DiffEngine.formatUnified(lines)
                } else {
                    let streamingText = streamingEditText(from: editText)
                    if !streamingText.isEmpty {
                        copyOutput = streamingText
                        content = expandedStreamingFileContent(
                            text: streamingText,
                            metadata: fileMetadata,
                            startLine: 1,
                            attachments: []
                        )
                    }
                }
            } else if !outputTrimmed.isEmpty {
                content = isDone
                    ? expandedFileCodeFallback(
                        text: outputTrimmed,
                        metadata: fileMetadata,
                        startLine: nil
                    )
                    : .text(text: outputTrimmed, language: nil)
            }

        default:
            let voicePresentation = Self.toolVoicePresentationDetails(from: details)
            let hasStructuredVoiceContent = Self.toolAudioAttachmentDetails(from: details) != nil
                || voicePresentation != nil
            let hasStructuredMediaContent = !mediaAttachments.isEmpty
                || Self.toolImageAttachmentDetails(from: details) != nil
            if !outputTrimmed.isEmpty || hasStructuredVoiceContent || hasStructuredMediaContent {
                if !isError,
                   let voicePresentation,
                   Self.toolAudioAttachmentDetails(from: details) == nil {
                    let transcript = voicePresentationTranscript(
                        output: outputTrimmed,
                        details: voicePresentation,
                        args: args
                    )
                    content = .voiceMessage(
                        text: transcript,
                        attachmentId: "",
                        mimeType: "audio/wav",
                        durationSeconds: nil,
                        delivery: voicePresentation.delivery
                    )
                    copyOutput = transcript.isEmpty ? nil : transcript
                } else if !mediaAttachments.isEmpty && Self.toolAudioAttachmentDetails(from: details) == nil {
                    content = .readMedia(
                        output: outputTrimmed,
                        filePath: rawToolName,
                        startLine: 1,
                        attachments: mediaAttachments
                    )
                    copyOutput = outputTrimmed.isEmpty ? rawToolName : outputTrimmed
                } else {
                    let resolved = resolveGenericExtensionExpandedContent(
                        output: outputTrimmed,
                        toolName: rawToolName,
                        details: details,
                        args: args
                    )
                    content = resolved.content
                    copyOutput = resolved.copyOutput
                }
            }
        }

        if content == nil, !isDone {
            content = .status(message: pendingStatusMessage(normalizedTool: normalizedTool))
        }

        return ExpandedPresentation(
            content: content,
            copyCommandText: copyCommand,
            copyOutputText: copyOutput
        )
    }

    // MARK: - Helpers (moved from Coordinator)

    /// Tools whose icon replaces the textual tool name in collapsed title rendering.
    private static func toolPrefixIconReplacesName(_ prefix: String?) -> Bool {
        switch prefix {
        case "$", "read", "write", "edit", "voice_speak", "voice_create": true
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
        let filePath = resolvedFilePath(args: args, argsSummary: argsSummary)
        let fileType = filePath.map { FileType.detect(from: $0) }
        let language: SyntaxLanguage?

        switch fileType {
        case .code(let resolvedLanguage):
            language = resolvedLanguage
        case .json:
            language = .json
        case .html:
            language = .html
        case .markdown, .image, .audio, .video, .pdf, .binary, .plain,
             .latex, .orgMode, .mermaid, .graphviz, .none:
            language = nil
        }

        return FilePresentationMetadata(
            filePath: filePath,
            fileType: fileType,
            language: language
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

    private static func expandedStreamingFileContent(
        text: String,
        metadata: FilePresentationMetadata,
        startLine: Int,
        attachments: [ToolMediaAttachment]
    ) -> ToolExpandedContent {
        switch metadata.fileType {
        case .markdown:
            // Incremental markdown pipeline (tail-only CommonMark parse)
            // handles streaming efficiently. Previously downgraded to .text.
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

    private static func expandedFileCodeFallback(
        text: String,
        metadata: FilePresentationMetadata,
        startLine: Int?
    ) -> ToolExpandedContent {
        .code(
            text: text,
            language: metadata.language,
            startLine: startLine,
            filePath: metadata.filePath
        )
    }

    private static func streamingEditText(from editText: (oldText: String, newText: String)) -> String {
        if !editText.newText.isEmpty {
            return editText.newText
        }
        return editText.oldText
    }

    private static func voicePresentationTranscript(
        output: String,
        details: ToolVoicePresentationDetails,
        args: [String: JSONValue]?
    ) -> String {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitMessage = details.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let argText = args?["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicitMessage.isEmpty {
            return explicitMessage
        }
        if trimmedOutput == "Voice message" {
            return argText
        }
        if !trimmedOutput.isEmpty {
            return trimmedOutput
        }
        return argText
    }

    private static func pendingStatusMessage(normalizedTool: String) -> String {
        switch normalizedTool {
        case "read":
            return "Reading…"
        case "write":
            return "Writing…"
        case "edit":
            return "Editing…"
        default:
            return "Waiting for output…"
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
        guard let filePath = resolvedFilePath(args: args, argsSummary: argsSummary),
              !filePath.isEmpty else {
            return nil
        }
        return FileType.detect(from: filePath)
    }

    private static func resolvedFilePath(
        args: [String: JSONValue]?,
        argsSummary: String
    ) -> String? {
        ToolCallFormatting.filePath(from: args)
            ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
            ?? inferredPathFromSummary(argsSummary)
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

    /// Convert org mode source text to markdown for the `.markdown` render pipeline.
    /// Uses the shared DocumentRenderPipeline conversion.
    private static func orgToMarkdown(_ orgText: String) -> String {
        DocumentRenderPipeline.orgToMarkdown(orgText)
    }

    // periphery:ignore - used by ToolPresentationBuilderTests via @testable import
    static func readOutputLanguage(args: [String: JSONValue]?, argsSummary: String) -> SyntaxLanguage? {
        guard let fileType = readOutputFileType(args: args, argsSummary: argsSummary) else { return nil }
        switch fileType {
        case .code(let language): return language
        case .json: return .json
        case .html: return .html
        case .latex: return .latex
        case .orgMode: return .orgMode
        case .mermaid: return .mermaid
        case .graphviz: return .dot
        case .markdown, .image, .audio, .video, .pdf, .binary, .plain: return nil
        }
    }
}
