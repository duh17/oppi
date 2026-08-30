import UIKit

@MainActor
final class AssistantMarkdownSegmentSource {
    /// Rendering inputs that affect cached prefix segments independently of source text.
    private struct SegmentBuildContext: Equatable {
        let themeID: ThemeID
        let serverID: String?
        let workspaceID: String?
        let sessionID: String?
        let serverBaseURL: URL?
        let sourceDirectory: String?
        let worktreeId: String?
    }

    /// UIKit-specific paint cache layered over the shared block parser.
    private struct StreamingSegmentState {
        var prefixBlocks: [MarkdownBlock]
        var prefixSegments: [FlatSegment]
        var buildContext: SegmentBuildContext
    }

    private var streamingParser = CommonMarkStreamingParser()
    private var streamingSegmentState: StreamingSegmentState?

    func reset() {
        streamingParser.reset()
        streamingSegmentState = nil
    }

    func buildSegments(
        _ config: AssistantMarkdownContentView.Configuration,
        mergeAdjacentTextSegments: Bool = true
    ) -> [FlatSegment] {
        let content = config.content

        if !config.isStreaming,
           mergeAdjacentTextSegments,
           let cached = MarkdownSegmentCache.shared.get(
               content,
               themeID: config.themeID,
               serverID: config.serverID,
               workspaceID: config.workspaceID,
               sessionID: config.sessionID,
               serverBaseURL: config.serverBaseURL,
               sourceDirectory: config.sourceDirectory,
               worktreeId: config.worktreeId
           ) {
            return Self.applyReaderPreferences(to: cached, config: config)
        }

        if config.isStreaming {
            return Self.applyReaderPreferences(to: buildSegmentsIncremental(config), config: config)
        }

        let parseStart = MarkdownStreamingPerf.timestampNs()
        let blocks = parseCommonMark(content)
        let parseEnd = MarkdownStreamingPerf.timestampNs()
        let segments = FlatSegment.build(
            from: blocks,
            themeID: config.themeID,
            serverID: config.serverID,
            workspaceID: config.workspaceID,
            sessionID: config.sessionID,
            serverBaseURL: config.serverBaseURL,
            sourceDirectory: config.sourceDirectory,
            worktreeId: config.worktreeId,
            mergeAdjacentTextSegments: mergeAdjacentTextSegments
        )
        let buildEnd = MarkdownStreamingPerf.timestampNs()

        MarkdownStreamingPerf.record(
            parseDurationNs: parseEnd - parseStart,
            buildDurationNs: buildEnd - parseEnd,
            lineCount: Self.countNewlines(content) + 1,
            isTailOnly: false,
            isStreaming: false
        )

        if mergeAdjacentTextSegments {
            MarkdownSegmentCache.shared.set(
                content,
                themeID: config.themeID,
                serverID: config.serverID,
                workspaceID: config.workspaceID,
                sessionID: config.sessionID,
                serverBaseURL: config.serverBaseURL,
                sourceDirectory: config.sourceDirectory,
                worktreeId: config.worktreeId,
                segments: segments
            )
        }
        return Self.applyReaderPreferences(to: segments, config: config)
    }

    func buildSegmentsWithSourceLineRanges(
        _ config: AssistantMarkdownContentView.Configuration,
        mergeAdjacentTextSegments: Bool = true
    ) -> FlatSegment.BuildResult {
        // Reader identity needs located top-level starts on every tick. Keep
        // this path canonical during streaming: segment splitting/merging must
        // finish before same-key occurrence ordinals are assigned.
        let content = config.content
        let parseStart = MarkdownStreamingPerf.timestampNs()
        let blocks = parseCommonMarkLocated(content)
        let parseEnd = MarkdownStreamingPerf.timestampNs()
        let build = FlatSegment.buildWithSourceLineRanges(
            from: blocks,
            themeID: config.themeID,
            serverID: config.serverID,
            workspaceID: config.workspaceID,
            sessionID: config.sessionID,
            serverBaseURL: config.serverBaseURL,
            sourceDirectory: config.sourceDirectory,
            worktreeId: config.worktreeId,
            mergeAdjacentTextSegments: mergeAdjacentTextSegments
        )
        let buildEnd = MarkdownStreamingPerf.timestampNs()

        MarkdownStreamingPerf.record(
            parseDurationNs: parseEnd - parseStart,
            buildDurationNs: buildEnd - parseEnd,
            lineCount: Self.countNewlines(content) + 1,
            isTailOnly: false,
            isStreaming: config.isStreaming
        )

        let segments = Self.applyReaderPreferences(to: build.segments, config: config)
        return FlatSegment.BuildResult(
            segments: segments,
            sourceLineRanges: build.sourceLineRanges,
            identities: FlatSegment.readerSegmentIDs(
                segments: segments,
                sourceLineRanges: build.sourceLineRanges
            )
        )
    }

    static func hasUnclosedCodeFence(_ content: String) -> Bool {
        var openFences = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if openFences > 0 {
                    openFences -= 1
                } else {
                    openFences += 1
                }
            }
        }
        return openFences > 0
    }

    // MARK: - Incremental streaming parse (tail-only)

    private func buildSegmentsIncremental(
        _ config: AssistantMarkdownContentView.Configuration
    ) -> [FlatSegment] {
        let buildContext = SegmentBuildContext(
            themeID: config.themeID,
            serverID: config.serverID,
            workspaceID: config.workspaceID,
            sessionID: config.sessionID,
            serverBaseURL: config.serverBaseURL,
            sourceDirectory: config.sourceDirectory,
            worktreeId: config.worktreeId
        )
        let parseStart = MarkdownStreamingPerf.timestampNs()
        let parsed = streamingParser.parse(config.content)
        let parseEnd = MarkdownStreamingPerf.timestampNs()

        let prefixSegments: [FlatSegment]
        if let cached = streamingSegmentState,
           cached.prefixBlocks == parsed.prefixBlocks,
           cached.buildContext == buildContext {
            prefixSegments = cached.prefixSegments
        } else {
            prefixSegments = FlatSegment.build(
                from: parsed.prefixBlocks,
                themeID: config.themeID,
                serverID: config.serverID,
                workspaceID: config.workspaceID,
                sessionID: config.sessionID,
                serverBaseURL: config.serverBaseURL,
                sourceDirectory: config.sourceDirectory,
                worktreeId: config.worktreeId
            )
        }

        let tailSegments = FlatSegment.build(
            from: parsed.tailBlocks,
            themeID: config.themeID,
            serverID: config.serverID,
            workspaceID: config.workspaceID,
            sessionID: config.sessionID,
            serverBaseURL: config.serverBaseURL,
            sourceDirectory: config.sourceDirectory,
            worktreeId: config.worktreeId
        )
        let buildEnd = MarkdownStreamingPerf.timestampNs()

        streamingSegmentState = parsed.prefixBlocks.isEmpty
            ? nil
            : StreamingSegmentState(
                prefixBlocks: parsed.prefixBlocks,
                prefixSegments: prefixSegments,
                buildContext: buildContext
            )

        MarkdownStreamingPerf.record(
            parseDurationNs: parseEnd - parseStart,
            buildDurationNs: buildEnd - parseEnd,
            lineCount: Self.countNewlines(config.content) + 1,
            isTailOnly: parsed.strategy == .tailOnly,
            isStreaming: true
        )

        return mergeSegments(prefix: prefixSegments, tail: tailSegments)
    }

    // MARK: - Segment merge

    private func mergeSegments(prefix: [FlatSegment], tail: [FlatSegment]) -> [FlatSegment] {
        guard !prefix.isEmpty, !tail.isEmpty else { return prefix + tail }

        if case .text(let prefixText) = prefix.last,
           case .text(let tailText) = tail.first {
            var merged = prefixText
            merged.append(AttributedString("\n\n"))
            merged.append(tailText)

            var result = Array(prefix.dropLast())
            result.append(.text(merged))
            result.append(contentsOf: tail.dropFirst())
            return result
        }

        return prefix + tail
    }

    static func applyReaderPreferences(
        to segments: [FlatSegment],
        config: AssistantMarkdownContentView.Configuration
    ) -> [FlatSegment] {
        guard let preferences = config.readerPreferences,
              preferences != FullScreenReaderContentFamily.markdown.defaultPreferences
        else { return segments }

        return segments.map { segment in
            guard case .text(let text) = segment else { return segment }
            return .text(applyReaderPreferences(to: text, preferences: preferences))
        }
    }

    private static func applyReaderPreferences(
        to text: AttributedString,
        preferences: FullScreenReaderPreferences
    ) -> AttributedString {
        let scale = preferences.textScale
        let lineSpacing = preferences.spacing.markdownLineSpacing
        let mutable = NSMutableAttributedString(text)
        let fullRange = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let font = (attributes[.font] as? UIFont) ?? AppFont.messageBody
            mutable.addAttribute(
                .font,
                value: FullScreenCodeTypography.scaledFont(font, scale: scale),
                range: range
            )

            let paragraph = ((attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }

        return AttributedString(mutable)
    }

    // MARK: - Helpers

    /// Count newlines via UTF-8 byte scan. Avoids the `components(separatedBy:)` array allocation.
    private static func countNewlines(_ string: String) -> Int {
        var count = 0
        for byte in string.utf8 where byte == UInt8(ascii: "\n") {
            count += 1
        }
        return count
    }
}
