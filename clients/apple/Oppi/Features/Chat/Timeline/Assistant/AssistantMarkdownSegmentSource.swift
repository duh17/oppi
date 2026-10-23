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
        let typographyRevision: UInt64
    }

    /// UIKit-specific paint cache layered over the shared block parser.
    private struct StreamingSegmentState {
        var prefixBlocks: [MarkdownBlock]
        var prefixSegments: [FlatSegment]
        var buildContext: SegmentBuildContext
    }

    /// Last merged streaming prose so a frozen prefix AttributedString is not
    /// copied on every tail-only tick.
    private struct StreamingTextMergeCache {
        let prefixCount: Int
        let tailPlain: NSString
        var merged: AttributedString
    }

    private var streamingParser = CommonMarkStreamingParser()
    private var streamingSegmentState: StreamingSegmentState?
    private var streamingTextMergeCache: StreamingTextMergeCache?

    /// The parser's append verdict for the last streaming build, and whether the
    /// appended bytes can leave earlier glyphs alone. The applier uses it instead
    /// of re-deriving an append from the whole source text.
    private(set) var lastStreamingAppendIsMarkdownNeutral = false

    func reset() {
        streamingParser.reset()
        streamingSegmentState = nil
        streamingTextMergeCache = nil
        lastStreamingAppendIsMarkdownNeutral = false
    }

    func buildSegments(
        _ config: AssistantMarkdownContentView.Configuration,
        mergeAdjacentTextSegments: Bool = true,
        preparedBlocks: [MarkdownBlock]? = nil
    ) -> [FlatSegment] {
        let content = config.content
        let identity = config.resourceAccess.identity
        lastStreamingAppendIsMarkdownNeutral = false

        if !config.isStreaming,
           mergeAdjacentTextSegments,
           let preparedBlocks {
            let segments = FlatSegment.build(
                from: preparedBlocks,
                themeID: config.themeID,
                serverID: identity.serverID,
                workspaceID: identity.workspaceID,
                sessionID: identity.sessionID,
                serverBaseURL: identity.serverBaseURL,
                sourceDirectory: config.sourceDirectory,
                worktreeId: identity.worktreeId
            )
            return Self.applyReaderPreferences(to: segments, config: config)
        }

        if !config.isStreaming,
           mergeAdjacentTextSegments,
           let cached = MarkdownSegmentCache.shared.get(
               content,
               themeID: config.themeID,
               typographyRevision: config.typographyRevision,
               serverID: identity.serverID,
               workspaceID: identity.workspaceID,
               sessionID: identity.sessionID,
               serverBaseURL: identity.serverBaseURL,
               sourceDirectory: config.sourceDirectory,
               worktreeId: identity.worktreeId
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
            serverID: identity.serverID,
            workspaceID: identity.workspaceID,
            sessionID: identity.sessionID,
            serverBaseURL: identity.serverBaseURL,
            sourceDirectory: config.sourceDirectory,
            worktreeId: identity.worktreeId,
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
                typographyRevision: config.typographyRevision,
                serverID: identity.serverID,
                workspaceID: identity.workspaceID,
                sessionID: identity.sessionID,
                serverBaseURL: identity.serverBaseURL,
                sourceDirectory: config.sourceDirectory,
                worktreeId: identity.worktreeId,
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
        let identity = config.resourceAccess.identity
        lastStreamingAppendIsMarkdownNeutral = false
        let parseStart = MarkdownStreamingPerf.timestampNs()
        let blocks = parseCommonMarkLocated(content)
        let parseEnd = MarkdownStreamingPerf.timestampNs()
        let build = FlatSegment.buildWithSourceLineRanges(
            from: blocks,
            themeID: config.themeID,
            serverID: identity.serverID,
            workspaceID: identity.workspaceID,
            sessionID: identity.sessionID,
            serverBaseURL: identity.serverBaseURL,
            sourceDirectory: config.sourceDirectory,
            worktreeId: identity.worktreeId,
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
        let identity = config.resourceAccess.identity
        let buildContext = SegmentBuildContext(
            themeID: config.themeID,
            serverID: identity.serverID,
            workspaceID: identity.workspaceID,
            sessionID: identity.sessionID,
            serverBaseURL: identity.serverBaseURL,
            sourceDirectory: config.sourceDirectory,
            worktreeId: identity.worktreeId,
            typographyRevision: config.typographyRevision
        )
        let parseStart = MarkdownStreamingPerf.timestampNs()
        let parsed = streamingParser.parse(config.content)
        let parseEnd = MarkdownStreamingPerf.timestampNs()
        lastStreamingAppendIsMarkdownNeutral = parsed.appendedUTF8Range.map { appended in
            StreamingMarkdownDelta.appendedSourceIsMarkdownNeutral(config.content, range: appended)
        } ?? false

        let prefixSegments: [FlatSegment]
        let prefixReused: Bool
        if let cached = streamingSegmentState,
           cached.prefixBlocks == parsed.prefixBlocks,
           cached.buildContext == buildContext {
            prefixSegments = cached.prefixSegments
            prefixReused = true
        } else {
            prefixSegments = FlatSegment.build(
                from: parsed.prefixBlocks,
                themeID: config.themeID,
                serverID: identity.serverID,
                workspaceID: identity.workspaceID,
                sessionID: identity.sessionID,
                serverBaseURL: identity.serverBaseURL,
                sourceDirectory: config.sourceDirectory,
                worktreeId: identity.worktreeId
            )
            prefixReused = false
        }

        let tailSegments = FlatSegment.build(
            from: parsed.tailBlocks,
            themeID: config.themeID,
            serverID: identity.serverID,
            workspaceID: identity.workspaceID,
            sessionID: identity.sessionID,
            serverBaseURL: identity.serverBaseURL,
            sourceDirectory: config.sourceDirectory,
            worktreeId: identity.worktreeId
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

        return mergeSegments(
            prefix: prefixSegments,
            tail: tailSegments,
            prefixReused: prefixReused
        )
    }

    // MARK: - Segment merge

    private func mergeSegments(
        prefix: [FlatSegment],
        tail: [FlatSegment],
        prefixReused: Bool
    ) -> [FlatSegment] {
        guard !prefix.isEmpty, !tail.isEmpty else {
            streamingTextMergeCache = nil
            return prefix + tail
        }

        if case .text(let prefixText) = prefix.last,
           case .text(let tailText) = tail.first {
            if prefixReused,
               let cache = streamingTextMergeCache,
               cache.prefixCount == prefix.count,
               StreamingMarkdownDelta.renderedUTF16PrefixMatches(tailText, prefix: cache.tailPlain),
               let suffix = StreamingMarkdownDelta.attributedSuffix(
                   tailText,
                   afterUTF16Offset: cache.tailPlain.length
               ) {
                var merged = cache.merged
                if !suffix.characters.isEmpty {
                    merged.append(suffix)
                }
                streamingTextMergeCache = StreamingTextMergeCache(
                    prefixCount: prefix.count,
                    tailPlain: String(tailText.characters) as NSString,
                    merged: merged
                )
                return assembleMergedText(
                    prefix: prefix,
                    tail: tail,
                    merged: merged
                )
            }

            var merged = prefixText
            merged.append(AttributedString("\n\n"))
            merged.append(tailText)
            streamingTextMergeCache = StreamingTextMergeCache(
                prefixCount: prefix.count,
                tailPlain: String(tailText.characters) as NSString,
                merged: merged
            )
            return assembleMergedText(prefix: prefix, tail: tail, merged: merged)
        }

        streamingTextMergeCache = nil
        return prefix + tail
    }

    private func assembleMergedText(
        prefix: [FlatSegment],
        tail: [FlatSegment],
        merged: AttributedString
    ) -> [FlatSegment] {
        var result = Array(prefix.dropLast())
        result.append(.text(merged))
        result.append(contentsOf: tail.dropFirst())
        return result
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

/// Slices a FlatSegment AttributedString without boxing the already-rendered prefix
/// into NSAttributedString. UTF-16 offsets match TextKit / NSTextStorage.
enum StreamingMarkdownDelta {
    /// True when the appended source bytes cannot open or close inline markup, so
    /// an append cannot restyle glyphs that are already rendered. Only the
    /// appended bytes are scanned; the parser already proved the append.
    static func appendedSourceIsMarkdownNeutral(_ content: String, range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return true }

        let bytes = content.utf8
        let start = bytes.index(
            bytes.endIndex,
            offsetBy: range.lowerBound - bytes.count
        )
        for byte in bytes[start...] {
            switch byte {
            case 33, 36, 38, 40, 41, 42, 60, 62, 91, 92, 93, 95, 96, 124, 126:
                return false
            default:
                continue
            }
        }
        return true
    }

    static func attributedSuffix(
        _ attributed: AttributedString,
        afterUTF16Offset offset: Int
    ) -> AttributedString? {
        guard offset >= 0 else { return nil }
        guard let start = Range(NSRange(location: offset, length: 0), in: attributed)?.lowerBound else {
            return nil
        }
        if start == attributed.endIndex {
            return AttributedString()
        }
        return AttributedString(attributed[start...])
    }

    static func nsAttributedSuffix(
        _ attributed: AttributedString,
        afterUTF16Offset offset: Int
    ) -> NSAttributedString? {
        guard let suffix = attributedSuffix(attributed, afterUTF16Offset: offset) else {
            return nil
        }
        return NSAttributedString(suffix)
    }

    static func renderedUTF16PrefixMatches(
        _ attributed: AttributedString,
        prefix: NSString
    ) -> Bool {
        let prefixLength = prefix.length
        if prefixLength == 0 { return true }
        guard let range = Range(NSRange(location: 0, length: prefixLength), in: attributed) else {
            return false
        }
        return (String(attributed[range].characters) as NSString).isEqual(prefix)
    }
}
