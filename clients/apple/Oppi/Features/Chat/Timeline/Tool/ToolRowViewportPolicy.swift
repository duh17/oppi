import UIKit

/// Single routing table for expanded tool-row viewport behavior.
///
/// Render strategies decide *what* to render. This policy decides *where* that
/// content lives and how the row owns height, scrolling, and constraint priority.
@MainActor
struct ToolRowViewportPolicy {
    static let maxExtensionMarkdownViewportHeight: CGFloat = 480
    static let maxNaturalReadMediaHeight: CGFloat = 10_000
    static let minVoiceReadMediaHeight: CGFloat = 72
    static let maxVoiceReadMediaHeight: CGFloat = 150

    enum HeightBehavior: Equatable {
        /// Text/code/diff/bash output viewports measured through the cached/bucketed path.
        case cachedMeasured(mode: ToolRowViewportCalculator.ViewportMode)
        /// Hosted markdown body whose height is fixed to a content-family max.
        case markdownViewport(maxHeight: CGFloat)
        /// Hosted read-media that sizes to natural content height instead of text viewport buckets.
        case naturalReadMedia(minHeight: CGFloat, maxHeight: CGFloat)
        /// Compatibility path for older voice-message read-media payloads.
        case voiceReadMedia(minHeight: CGFloat, maxHeight: CGFloat)
        /// Hosted row without an inner scroll view, measured directly from content.
        case compactMeasured(minHeight: CGFloat, maxHeight: CGFloat?)
    }

    struct ReadMediaFacts: Equatable {
        let hasVideo: Bool
        let hasImage: Bool
        let hasAudio: Bool
        let hasInlineImage: Bool
        let isVideoFile: Bool
        let isImageFile: Bool
        let isAudioFile: Bool
        let isVoiceMessage: Bool

        var shouldUseCompactVideoLauncher: Bool {
            hasVideo && !hasImage && !hasInlineImage && !isImageFile
        }
    }

    let surface: ExpandedRenderOutput.ExpandedSurface
    let viewportMode: ToolTimelineRowContentView.ExpandedViewportMode
    let heightBehavior: HeightBehavior
    let constraintPriority: UILayoutPriority

    var viewportCalculatorMode: ToolRowViewportCalculator.ViewportMode {
        switch heightBehavior {
        case .cachedMeasured(let mode):
            return mode
        case .markdownViewport, .naturalReadMedia, .voiceReadMedia, .compactMeasured:
            return .expandedText
        }
    }

    var usesExpandedViewport: Bool {
        switch heightBehavior {
        case .compactMeasured:
            return false
        case .cachedMeasured, .markdownViewport, .naturalReadMedia, .voiceReadMedia:
            return true
        }
    }

    static let bashOutput = ToolRowViewportPolicy(
        surface: .label,
        viewportMode: .text,
        heightBehavior: .cachedMeasured(mode: .output),
        constraintPriority: .required
    )

    static let diff = ToolRowViewportPolicy(
        surface: .label,
        viewportMode: .diff,
        heightBehavior: .cachedMeasured(mode: .expandedDiff),
        constraintPriority: .required
    )

    static let code = ToolRowViewportPolicy(
        surface: .label,
        viewportMode: .code,
        heightBehavior: .cachedMeasured(mode: .expandedCode),
        constraintPriority: .required
    )

    static let text = ToolRowViewportPolicy(
        surface: .label,
        viewportMode: .text,
        heightBehavior: .cachedMeasured(mode: .expandedText),
        constraintPriority: .required
    )

    static let status = ToolRowViewportPolicy(
        surface: .label,
        viewportMode: .text,
        heightBehavior: .cachedMeasured(mode: .expandedText),
        constraintPriority: .required
    )

    static func markdown(isCustomTool: Bool) -> ToolRowViewportPolicy {
        ToolRowViewportPolicy(
            surface: .markdownViewport,
            viewportMode: .text,
            heightBehavior: .markdownViewport(
                maxHeight: isCustomTool
                    ? Self.maxExtensionMarkdownViewportHeight
                    : ToolTimelineRowContentView.maxOutputViewportHeight
            ),
            constraintPriority: .required
        )
    }

    static func readMedia(
        output: String,
        filePath: String?,
        attachments: [ToolPresentationBuilder.ToolMediaAttachment],
        fileType: FileType?
    ) -> ToolRowViewportPolicy {
        let facts = readMediaFacts(output: output, filePath: filePath, attachments: attachments, fileType: fileType)

        if facts.isVoiceMessage {
            return ToolRowViewportPolicy(
                surface: .hostedView,
                viewportMode: .text,
                heightBehavior: .voiceReadMedia(
                    minHeight: Self.minVoiceReadMediaHeight,
                    maxHeight: Self.maxVoiceReadMediaHeight
                ),
                constraintPriority: .defaultHigh
            )
        }

        if facts.shouldUseCompactVideoLauncher {
            return ToolRowViewportPolicy(
                surface: .compactHostedView,
                viewportMode: .text,
                heightBehavior: .compactMeasured(minHeight: 1, maxHeight: nil),
                constraintPriority: .required
            )
        }

        return ToolRowViewportPolicy(
            surface: .hostedView,
            viewportMode: .text,
            heightBehavior: .naturalReadMedia(
                minHeight: ToolTimelineRowContentView.minOutputViewportHeight,
                maxHeight: Self.maxNaturalReadMediaHeight
            ),
            constraintPriority: .defaultHigh
        )
    }

    static let audioMessage = ToolRowViewportPolicy(
        surface: .compactHostedView,
        viewportMode: .text,
        heightBehavior: .compactMeasured(minHeight: 1, maxHeight: nil),
        constraintPriority: .required
    )

    static func forExpandedContent(
        _ content: ToolPresentationBuilder.ToolExpandedContent,
        toolNamePrefix: String?
    ) -> ToolRowViewportPolicy {
        switch content {
        case .bash:
            return .bashOutput
        case .diff:
            return .diff
        case .code:
            return .code
        case .markdown(_, let filePath):
            return .markdown(isCustomTool: filePath == nil)
        case .readMedia(let output, let filePath, _, let attachments, let fileType):
            return .readMedia(output: output, filePath: filePath, attachments: attachments, fileType: fileType)
        case .audioMessage:
            return .audioMessage
        case .status:
            return .status
        case .text:
            return .text
        case .document(let family):
            return .document(family.inline)
        }
    }

    static func document(_ traits: DocumentFamily.InlineTraits) -> ToolRowViewportPolicy {
        ToolRowViewportPolicy(
            surface: .hostedView,
            viewportMode: .text,
            heightBehavior: .compactMeasured(
                minHeight: traits.minViewportHeight,
                maxHeight: ToolTimelineRowContentView.maxOutputViewportHeight
            ),
            constraintPriority: .required
        )
    }

    static func readMediaFacts(
        output: String,
        filePath: String?,
        attachments: [ToolPresentationBuilder.ToolMediaAttachment],
        fileType: FileType?
    ) -> ReadMediaFacts {
        let isVideoFile = fileType.map { type in
            if case .video = type { return true }
            return false
        } ?? false
        let isImageFile = fileType.map { type in
            if case .image = type { return true }
            return false
        } ?? false
        let isAudioFile = fileType.map { type in
            if case .audio = type { return true }
            return false
        } ?? false

        let hasVideoAttachment = attachments.contains { attachment in
            normalizedMediaKind(attachment.kind) == "video"
                || attachment.mimeType.lowercased().hasPrefix("video/")
        }
        let hasImageAttachment = attachments.contains { attachment in
            normalizedMediaKind(attachment.kind) == "image"
                || attachment.mimeType.lowercased().hasPrefix("image/")
        }
        let hasAudioAttachment = attachments.contains { attachment in
            normalizedMediaKind(attachment.kind) == "audio"
                || attachment.mimeType.lowercased().hasPrefix("audio/")
        }
        let hasInlineImage = output.range(of: "data:image/", options: .caseInsensitive) != nil
            || output.range(of: "<svg", options: .caseInsensitive) != nil

        return ReadMediaFacts(
            hasVideo: hasVideoAttachment || isVideoFile,
            hasImage: hasImageAttachment || isImageFile,
            hasAudio: hasAudioAttachment || isAudioFile,
            hasInlineImage: hasInlineImage,
            isVideoFile: isVideoFile,
            isImageFile: isImageFile,
            isAudioFile: isAudioFile,
            isVoiceMessage: filePath == "Voice message"
        )
    }

    private static func normalizedMediaKind(_ kind: String) -> String {
        kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

}
