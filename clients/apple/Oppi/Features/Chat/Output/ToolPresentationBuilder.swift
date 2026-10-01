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
        var inputPresentation: ToolInputPresentation? = nil
        var nestedCalls: NestedToolCalls? = nil
        var previewOnly = false
        var totalBytes: Int? = nil
        var display: ToolDisplay? = nil
        var outputPresentation: ToolOutputPresentation? = nil
        var outputAvailability: ToolOutputAvailability? = nil
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
        let isInteractive = context.outputPresentation?.isInteractive == true
        let isExpanded = context.expandedItemIDs.contains(itemID)
        let args = context.args

        let presentation = ToolContentDescriptorBuilder.build(
            tool: tool, argsSummary: argsSummary, outputPreview: outputPreview,
            isError: isError, isDone: isDone,
            context: .init(args: args, details: context.details, fullOutput: context.fullOutput,
                           isLoadingOutput: context.isLoadingOutput, inputPresentation: context.inputPresentation,
                           nestedCalls: context.nestedCalls, previewOnly: context.previewOnly,
                           totalBytes: context.totalBytes, display: context.display,
                           outputPresentation: context.outputPresentation, outputAvailability: context.outputAvailability),
            includeOutput: isExpanded || Self.toolAudioPresentationDetails(from: context.details) != nil
        )
        let isTerminal = presentation.inspection.terminalOutput
        let file = presentation.inspection.file
        let hasInlineMediaDataURI = !isTerminal && file == nil && shouldWarnInlineMediaForToolOutput(
            outputPreview: outputPreview,
            fullOutput: context.fullOutput
        )

        // Collapsed presentation
        let collapsed = buildCollapsed(
            isInteractive: isInteractive,
            tool: tool,
            args: args,
            argsSummary: argsSummary,
            details: context.details,
            isExpanded: isExpanded,
            isError: isError,
            isDone: isDone,
            outputPreview: outputPreview,
            display: context.callSegments?.isEmpty != false ? context.display : nil,
            terminalOutput: isTerminal,
            file: file
        )
        let isVoicePresentationResult = Self.toolAudioPresentationDetails(from: context.details) != nil

        // Expanded presentation
        let expanded: ExpandedPresentation
        if isExpanded || isVoicePresentationResult {
            expanded = buildExpanded(presentation)
        } else {
            expanded = ExpandedPresentation()
        }

        // Trailing (built-in tools only; extension tools use resultSegments)
        let trailing: String?
        if isInterrupted {
            trailing = String(localized: "Interrupted")
        } else if let editTrailingFallback = collapsed.editTrailingFallback {
            trailing = editTrailingFallback
        } else if let nested = context.nestedCalls, !nested.calls.isEmpty {
            trailing = nested.summary
        } else {
            trailing = nil
        }

        // Language badge
        var languageBadge = presentation.inspection.commandLanguageBadge ?? collapsed.languageBadge
        if hasInlineMediaDataURI {
            if let existingBadge = languageBadge, !existingBadge.isEmpty {
                languageBadge = "\(existingBadge) • ⚠︎media"
            } else {
                languageBadge = "⚠︎media"
            }
        }

        var title = collapsed.title
        let shouldCapTitleLength = file == nil
        if shouldCapTitleLength, title.count > 240 {
            title = String(title.prefix(239)) + "…"
        }

        // Collapsed rows should stay file-like, even for image reads.
        // Inline media belongs in the expanded renderer, not the header.

        // Server-rendered segments: build attributed title and trailing.
        // Terminal facts and file icons replace the summary's tool prefix.
        // Keep the server's summary title even when expanded: command input
        // belongs to the separate command panel. Generic extensions retain
        // their name per the non-segment fallback behavior.
        let segmentAttributedTitle: NSAttributedString?
        if isVoicePresentationResult || isInteractive {
            segmentAttributedTitle = nil
        } else if let callSegs = context.callSegments, !callSegs.isEmpty {
            if isTerminal || file != nil {
                segmentAttributedTitle = SegmentRenderer.attributedStringStrippingPrefix(from: callSegs)
            } else {
                segmentAttributedTitle = SegmentRenderer.attributedString(from: callSegs)
            }
        } else {
            segmentAttributedTitle = nil
        }

        if isTerminal || file != nil, let segmentAttributedTitle { title = segmentAttributedTitle.string }

        let segmentAttributedTrailing: NSAttributedString?
        if isInterrupted || file?.provenance == .requested {
            segmentAttributedTrailing = nil
        } else if let resultSegs = context.resultSegments, !resultSegs.isEmpty {
            segmentAttributedTrailing = SegmentRenderer.trailingAttributedString(from: resultSegs)
        } else {
            segmentAttributedTrailing = nil
        }

        let segmentToolNamePrefix = SegmentRenderer.toolNamePrefix(from: context.callSegments ?? [])
        let segmentToolNameColor = SegmentRenderer.toolNameColor(from: context.callSegments ?? [])

        let currentFileOpenIntent = currentFileOpenIntent(
            file: file,
            isDone: isDone,
            isError: isError,
            isInterrupted: isInterrupted
        )
        let expandedContent: ToolExpandedContent? = if isExpanded,
                                                       currentFileOpenIntent != nil,
                                                       file?.text.isEmpty == true {
            // Successful empty writes still need a visible expanded surface
            // from which the user can open the actual current file.
            .status(message: "Open current file")
        } else {
            expanded.content
        }

        let toolNamePrefix = segmentAttributedTitle != nil
            ? (isTerminal || file != nil ? collapsed.toolNamePrefix : (segmentToolNamePrefix ?? collapsed.toolNamePrefix))
            : collapsed.toolNamePrefix
        // A dollar in legacy or structured summary text is not a terminal fact.
        let glyphPrefix = !isTerminal && toolNamePrefix == "$" ? nil : toolNamePrefix
        var configuration = ToolTimelineRowConfiguration(
            itemID: itemID,
            title: title,
            preview: nil, // collapsed tool rows single-line
            expandedContent: expandedContent,
            copyCommandText: expanded.copyCommandText,
            copyOutputText: expanded.copyOutputText,
            languageBadge: isVoicePresentationResult ? nil : languageBadge,
            trailing: segmentAttributedTrailing != nil ? nil : trailing,
            titleLineBreakMode: segmentAttributedTitle != nil && file == nil ? .byTruncatingTail : collapsed.titleLineBreakMode,
            toolNamePrefix: glyphPrefix,
            toolNameColor: segmentAttributedTitle != nil
                ? (isTerminal || file != nil ? collapsed.toolNameColor : (segmentToolNameColor ?? collapsed.toolNameColor))
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
        configuration.isInteractive = isInteractive
        configuration.glyph = ToolContentDescriptorBuilder.glyph(input: context.inputPresentation, output: context.outputPresentation, details: context.details)
        configuration.inspectionSupplement = presentation.inspection.supplement?.text
        configuration.rawMarkdownText = expanded.rawMarkdownText
        configuration.rawMarkdownOutputPrefix = expanded.rawMarkdownOutputPrefix
        configuration.currentFileOpenIntent = currentFileOpenIntent
        return configuration
    }

    private static func currentFileOpenIntent(
        file: ToolFileInspection?,
        isDone: Bool,
        isError: Bool,
        isInterrupted: Bool
    ) -> ToolCurrentFileOpenIntent? {
        guard let file, file.operation == .mutation,
              isDone,
              !isError,
              !isInterrupted,
              let path = file.path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              file.fileType?.previewCategory == .text else {
            return nil
        }
        return ToolCurrentFileOpenIntent(path: path)
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
        isInteractive: Bool,
        tool: String,
        args: [String: JSONValue]?,
        argsSummary: String,
        details: JSONValue?,
        isExpanded: Bool,
        isError: Bool,
        isDone: Bool,
        outputPreview: String,
        display: ToolDisplay?,
        terminalOutput: Bool,
        file: ToolFileInspection?
    ) -> CollapsedPresentation {
        var result = CollapsedPresentation(title: tool)

        if terminalOutput {
            result.toolNamePrefix = "$"
            result.toolNameColor = UIColor(Color.themeGreen)
            return result
        }

        if let file {
            // The server's segments supply the title below; without segments use
            // the producer display/ordinary fallback, never reconstruct a tool call.
            result.title = display?.label(fallback: tool) ?? (argsSummary.isEmpty ? tool : "\(tool) \(argsSummary)")
            result.toolNamePrefix = file.prefix
            result.titleLineBreakMode = .byTruncatingMiddle
            result.languageBadge = file.fileType == .markdown || file.fileType == .image
                ? file.fileType?.displayLabel : file.fileType?.syntaxLanguage?.displayName
            if !isError {
                result.editTrailingFallback = file.provenance == .requested ? "Requested" : nil
                if file.operation == .edits, let stats = file.stats {
                    result.editAdded = stats.added
                    result.editRemoved = stats.removed
                }
            }
            return result
        }
        if isInteractive {
            result.title = ToolCallFormatting.askCollapsedTitle(
                args: args,
                details: details,
                argsSummary: argsSummary
            )
            result.toolNamePrefix = nil
            result.toolNameColor = UIColor(Color.themeCyan)
            result.titleLineBreakMode = .byTruncatingTail

        } else {
            // Extension tools are rendered via server-provided StyledSegments.
            // This default case is the fallback when segments aren't available.
            if Self.toolAudioPresentationDetails(from: details) != nil {
                result.title = "Voice message"
                result.languageBadge = nil
                result.toolNamePrefix = nil
                result.toolNameColor = UIColor(Color.themePurple)
            } else if let display, !display.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.title = display.label(fallback: tool)
                result.toolNamePrefix = nil
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
        case markdown(text: String, filePath: String? = nil)
        /// Rendered CSV/TSV table or GeoJSON/TopoJSON map in the expanded tool row.
        /// `DocumentFamily` owns the per-kind behavior, including the full-screen
        /// Source toggle (`DocumentFamily.sourceToggleTitle`).
        case document(DocumentFamily)
        /// Media renderer for images/audio in read output
        case readMedia(output: String, filePath: String?, startLine: Int, attachments: [ToolMediaAttachment], fileType: FileType? = nil)
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
        var rawMarkdownText: String?
        var rawMarkdownOutputPrefix: String?
    }

    private static func buildExpanded(_ presentation: ToolContentPresentation) -> ExpandedPresentation {
        return ExpandedPresentation(
            content: presentation.content.map { descriptor in
                if presentation.inspection.terminalOutput, case .terminal(let terminal) = descriptor {
                    return .bash(command: presentation.inspection.commandText, output: terminal.output, unwrapped: true)
                }
                return expandedContent(from: descriptor)
            },
            copyCommandText: presentation.copyCommandText,
            copyOutputText: presentation.copyOutputText,
            rawMarkdownText: { if case .markdown(let markdown) = presentation.content { return markdown.rawText }; return nil }(),
            rawMarkdownOutputPrefix: { if case .markdown(let markdown) = presentation.content { return markdown.rawOutputPrefix }; return nil }()
        )
    }

    /// Maps the shared semantic descriptor onto iOS expanded paint cases.
    /// Collapsed UIKit configuration stays in this builder.
    private static func expandedContent(from descriptor: ToolContentDescriptor) -> ToolExpandedContent {
        switch descriptor {
        case .terminal(let terminal):
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
            return .markdown(text: markdown.text, filePath: markdown.filePath)
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

    private struct FilePresentationMetadata {
        let filePath: String?
        let fileType: FileType?
        let language: SyntaxLanguage?
    }

    private static func expandedFileContent(
        text: String,
        metadata: FilePresentationMetadata,
        startLine: Int,
        attachments: [ToolMediaAttachment]
    ) -> ToolExpandedContent {
        let fileType = metadata.fileType
        if let fileType,
           let document = DocumentFamily(fileType: fileType, text: text, filePath: metadata.filePath) {
            return .document(document)
        }
        switch fileType {
        case .markdown:
            return .markdown(text: text, filePath: metadata.filePath)
        case .orgMode:
            return .markdown(text: orgToMarkdown(text), filePath: metadata.filePath)
        case .image, .audio, .video:
            return .readMedia(
                output: text,
                filePath: metadata.filePath,
                startLine: startLine,
                attachments: attachments,
                fileType: fileType
            )
        case .json:
            return .code(
                text: text,
                language: metadata.language,
                startLine: startLine,
                filePath: metadata.filePath
            )
        case .html, .plain, .code, .pdf, .usdz, .binary,
             .latex, .mermaid, .graphviz, .none,
             // Classified above by `DocumentFamily`; listed so the switch stays exhaustive.
             .csv, .tsv, .geojson, .topojson:
            return .code(
                text: text,
                language: metadata.language,
                startLine: startLine,
                filePath: metadata.filePath
            )
        }
    }

    static func shouldWarnInlineMediaForToolOutput(
        outputPreview: String,
        fullOutput: String
    ) -> Bool {
        let outputSample = fullOutput.isEmpty ? outputPreview : fullOutput
        guard !outputSample.isEmpty else { return false }
        return containsInlineMediaDataURI(outputSample)
    }

    private static func containsInlineMediaDataURI(_ text: String) -> Bool {
        text.range(of: "data:image/", options: .caseInsensitive) != nil
            || text.range(of: "data:audio/", options: .caseInsensitive) != nil
    }

    /// Convert org mode source text to markdown for the `.markdown` render pipeline.
    /// Uses the shared DocumentRenderPipeline conversion.
    private static func orgToMarkdown(_ orgText: String) -> String {
        DocumentRenderPipeline.orgToMarkdown(orgText)
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
