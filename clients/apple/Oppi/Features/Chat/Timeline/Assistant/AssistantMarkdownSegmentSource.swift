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
        /// Bumped whenever the prefix's closing text run is rebuilt or grown.
        /// The merge cache keys on it so "same segment count" can never be
        /// mistaken for "same prefix prose": a freshly frozen text block keeps
        /// the segment count and still replaces that run's content.
        var prefixTextRevision: UInt64
    }

    /// Last merged streaming prose so a frozen prefix AttributedString is not
    /// copied on every tail-only tick.
    private struct StreamingTextMergeCache {
        let prefixCount: Int
        let prefixTextRevision: UInt64
        /// Tail rendering the merged run already ends with, attributes included.
        var tail: NSAttributedString
        var merged: AttributedString
    }

    private var streamingParser = CommonMarkStreamingParser()
    private var streamingSegmentState: StreamingSegmentState?
    private var streamingTextMergeCache: StreamingTextMergeCache?

    /// The parser's append verdict for the last build, and whether the appended
    /// bytes can leave earlier glyphs alone. The applier uses it instead of
    /// re-deriving an append from the whole source text.
    private(set) var lastStreamingAppendIsMarkdownNeutral = false
    /// Whether the content of the last build ends inside an unclosed fence.
    /// Only live streaming rendering reads it. The streaming path reads only the
    /// open tail, which is the only place an unclosed fence can start: a frozen
    /// prefix ends at a block boundary.
    private(set) var lastBuildHasUnclosedCodeFence = false

    #if DEBUG
    /// Frozen-prefix blocks built since `reset()`. A steady stream builds each
    /// block once; a full prefix rebuild counts every block again per freeze.
    private(set) var debugPrefixBlockBuildCountForTesting = 0
    #endif

    func reset() {
        streamingParser.reset()
        streamingSegmentState = nil
        streamingTextMergeCache = nil
        lastStreamingAppendIsMarkdownNeutral = false
        lastBuildHasUnclosedCodeFence = false
        #if DEBUG
        debugPrefixBlockBuildCountForTesting = 0
        #endif
    }

    func buildSegments(
        _ config: AssistantMarkdownContentView.Configuration,
        mergeAdjacentTextSegments: Bool = true,
        preparedBlocks: [MarkdownBlock]? = nil
    ) -> [FlatSegment] {
        let content = config.content
        let identity = config.resourceAccess.identity
        lastStreamingAppendIsMarkdownNeutral = false

        if config.isStreaming {
            // The incremental path reads fence parity from the parse's open
            // tail. Scanning the whole answer here would undo its work.
            return Self.applyReaderPreferences(to: buildSegmentsIncremental(config), config: config)
        }

        // The flag only steers live streaming rendering, which the incremental
        // path above already answered; no other caller reads it.
        lastBuildHasUnclosedCodeFence = false

        if mergeAdjacentTextSegments,
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

        if mergeAdjacentTextSegments,
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

    /// Whether the whole document ends inside an unclosed fenced code block,
    /// from the source bytes alone. Callers that have a parse result use the
    /// overload below: cmark closes a fence that opened inside a container when
    /// the container ends, which a line scan cannot see.
    static func hasUnclosedCodeFence(_ content: String) -> Bool {
        endsInsideOpenFence(content.utf8[...])
    }

    /// Fence parity of the region starting at `offset`. The frozen streaming
    /// prefix ends at a top-level block boundary, so it holds no open fence and
    /// the tail alone decides; scanning it keeps a tick O(appended text).
    ///
    /// `endsInCodeBlock` is what cmark parsed for the end of the region: only a
    /// document whose last top-level block is a code block can still be inside
    /// one. The scan then answers whether that fence marker closed.
    static func hasUnclosedCodeFence(
        _ content: String,
        fromUTF8Offset offset: Int,
        endsInCodeBlock: Bool
    ) -> Bool {
        guard endsInCodeBlock else { return false }
        let bytes = content.utf8
        let start = bytes.index(bytes.endIndex, offsetBy: offset - bytes.count)
        return endsInsideOpenFence(bytes[start...])
    }

    /// Whether the region's last renderable block is a code block, following the
    /// last item of a trailing list: a fence inside the final list item still
    /// streams as a `.codeBlock` segment, so the region ends inside one even
    /// though its last *top-level* block is a list.
    ///
    /// Block quotes are not followed: `FlatSegment` renders a code block inside
    /// a quote as quoted text, so no trailing code view depends on the verdict.
    /// Internal so the streaming suite can check the production verdict instead
    /// of a copy.
    static func endsInCodeBlock(_ block: MarkdownBlock?) -> Bool {
        guard let block else { return false }
        switch block {
        case .codeBlock:
            return true
        case .unorderedList(let items):
            return endsInCodeBlock(items.last?.last)
        case .orderedList(_, let items):
            return endsInCodeBlock(items.last?.last)
        case .taskList(let items):
            return endsInCodeBlock(items.last?.content.last)
        case .heading, .paragraph, .blockQuote, .thematicBreak, .table, .htmlBlock:
            return false
        }
    }

    /// Walks fence lines tracking the open marker: a closing fence repeats the
    /// opener's character, is at least as long, and carries nothing else, so a
    /// `~~~` fence keeps ``` lines as content instead of closing on them.
    private static func endsInsideOpenFence<Bytes: Collection>(_ region: Bytes) -> Bool
    where Bytes.Element == UInt8 {
        let backtick = UInt8(ascii: "`")
        let tilde = UInt8(ascii: "~")
        let space = UInt8(ascii: " ")
        let tab = UInt8(ascii: "\t")

        var openFence: (marker: UInt8, length: Int)?
        for line in region.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let body = line.drop(while: { $0 == space || $0 == tab })
            guard let marker = body.first, marker == backtick || marker == tilde else { continue }
            let length = body.prefix { $0 == marker }.count
            guard length >= 3 else { continue }
            let rest = body.dropFirst(length)
            if let open = openFence {
                guard open.marker == marker,
                      length >= open.length,
                      !rest.contains(where: { $0 != space && $0 != tab })
                else { continue }
                openFence = nil
            } else {
                openFence = (marker, length)
            }
        }
        return openFence != nil
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
        lastBuildHasUnclosedCodeFence = Self.hasUnclosedCodeFence(
            config.content,
            fromUTF8Offset: parsed.tailUTF8Offset,
            endsInCodeBlock: Self.endsInCodeBlock(parsed.tailBlocks.last)
        )

        let prefixSegments: [FlatSegment]
        let prefixReused: Bool
        let prefixTextRevision: UInt64
        if let cached = streamingSegmentState,
           cached.buildContext == buildContext,
           let newlyFrozenCount = Self.newlyFrozenBlockCount(
               parsed.prefixBlocks,
               after: cached.prefixBlocks,
               carriedForward: parsed.strategy == .tailOnly
           ) {
            // The frozen prefix only ever grows by appending blocks, so the
            // segments it already has stay valid: build the new blocks and
            // join them at the boundary text run. Anything else (a context
            // change, a replacement, a parser reset) takes the full build.
            let newlyFrozen = Array(parsed.prefixBlocks.suffix(newlyFrozenCount))
            let extended = Self.appending(
                newlyFrozen.isEmpty
                    ? []
                    : FlatSegment.build(
                        from: newlyFrozen,
                        themeID: config.themeID,
                        serverID: identity.serverID,
                        workspaceID: identity.workspaceID,
                        sessionID: identity.sessionID,
                        serverBaseURL: identity.serverBaseURL,
                        sourceDirectory: config.sourceDirectory,
                        worktreeId: identity.worktreeId
                    ),
                to: cached.prefixSegments
            )
            prefixSegments = extended.segments
            prefixTextRevision = cached.prefixTextRevision &+ (extended.grewClosingText ? 1 : 0)
            prefixReused = true
            #if DEBUG
            debugPrefixBlockBuildCountForTesting += newlyFrozenCount
            #endif
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
            prefixTextRevision = (streamingSegmentState?.prefixTextRevision ?? 0) &+ 1
            prefixReused = false
            #if DEBUG
            debugPrefixBlockBuildCountForTesting += parsed.prefixBlocks.count
            #endif
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
                buildContext: buildContext,
                prefixTextRevision: prefixTextRevision
            )

        // A full parse covers the whole document even when a stable prefix was
        // split off, so its line count must not describe the tail alone. The
        // count is only read by telemetry, and the whole-document scan is
        // O(answer): `record` evaluates it lazily.
        MarkdownStreamingPerf.record(
            parseDurationNs: parseEnd - parseStart,
            buildDurationNs: buildEnd - parseEnd,
            lineCount: parsed.strategy == .full
                ? Self.countNewlines(config.content) + 1
                : Self.countNewlines(config.content, fromUTF8Offset: parsed.tailUTF8Offset) + 1,
            isTailOnly: parsed.strategy == .tailOnly,
            isStreaming: true
        )

        return mergeSegments(
            prefix: prefixSegments,
            tail: tailSegments,
            prefixReused: prefixReused,
            prefixTextRevision: prefixTextRevision
        )
    }

    // MARK: - Prefix extension

    /// Blocks `blocks` grew by since `cached`, or nil when `blocks` does not
    /// extend it. `carriedForward` says the parser kept its own frozen prefix
    /// (it only ever appends to it), so the shared blocks need no comparison;
    /// every other tick compares them before trusting the cached segments.
    private static func newlyFrozenBlockCount(
        _ blocks: [MarkdownBlock],
        after cached: [MarkdownBlock],
        carriedForward: Bool
    ) -> Int? {
        guard blocks.count >= cached.count else { return nil }
        guard !carriedForward else { return blocks.count - cached.count }
        for index in cached.indices where cached[index] != blocks[index] {
            return nil
        }
        return blocks.count - cached.count
    }

    /// Append segments for newly frozen blocks to the cached prefix.
    /// `FlatSegment.build` joins adjacent text-like blocks with a blank line, so
    /// a text run spanning the freeze boundary has to stay one segment.
    private static func appending(
        _ suffix: [FlatSegment],
        to prefix: [FlatSegment]
    ) -> (segments: [FlatSegment], grewClosingText: Bool) {
        guard case .text(let prefixText)? = prefix.last,
              case .text(let suffixText)? = suffix.first
        else {
            return (suffix.isEmpty ? prefix : prefix + suffix, false)
        }

        var mergedText = prefixText
        mergedText.append(AttributedString("\n\n"))
        mergedText.append(suffixText)
        var segments = Array(prefix.dropLast())
        segments.append(.text(mergedText))
        segments.append(contentsOf: suffix.dropFirst())
        return (segments, true)
    }

    // MARK: - Segment merge

    private func mergeSegments(
        prefix: [FlatSegment],
        tail: [FlatSegment],
        prefixReused: Bool,
        prefixTextRevision: UInt64
    ) -> [FlatSegment] {
        guard !prefix.isEmpty, !tail.isEmpty else {
            streamingTextMergeCache = nil
            return prefix + tail
        }

        if case .text(let prefixText) = prefix.last,
           case .text(let tailText) = tail.first {
            if prefixReused,
               var cache = streamingTextMergeCache,
               cache.prefixCount == prefix.count,
               cache.prefixTextRevision == prefixTextRevision,
               let appended = StreamingMarkdownDelta.appendedRendering(
                   tailText,
                   after: cache.tail
               ) {
                // Take the merged run out of the cache before appending. The
                // previous tick's segment array is gone by now (the applier
                // keeps only per-segment signatures, and every text view owns
                // its own NSAttributedString), so after this assignment the
                // local is the sole owner of the storage and `append` mutates
                // it in place instead of copying the whole run.
                streamingTextMergeCache = nil
                if !appended.suffix.characters.isEmpty {
                    cache.merged.append(appended.suffix)
                }
                cache.tail = appended.rendered
                streamingTextMergeCache = cache
                return assembleMergedText(
                    prefix: prefix,
                    tail: tail,
                    merged: cache.merged
                )
            }

            var merged = prefixText
            merged.append(AttributedString("\n\n"))
            merged.append(tailText)
            streamingTextMergeCache = StreamingTextMergeCache(
                prefixCount: prefix.count,
                prefixTextRevision: prefixTextRevision,
                tail: NSAttributedString(tailText),
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
        countNewlines(string, fromUTF8Offset: 0)
    }

    /// Newlines from `offset` to the end. Streaming telemetry wants the open
    /// tail, and indexing from the end keeps that scan O(tail).
    private static func countNewlines(_ string: String, fromUTF8Offset offset: Int) -> Int {
        let bytes = string.utf8
        let start = bytes.index(bytes.endIndex, offsetBy: offset - bytes.count)
        var count = 0
        for byte in bytes[start...] where byte == UInt8(ascii: "\n") {
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
    ///
    /// `-` and `=` count as markup only at the start of a line (after a newline
    /// plus up to 3 spaces): a setext underline or a bullet restyles the line
    /// above it without changing one of its characters. Mid-line they are plain
    /// prose — " - " is common enough that treating it as markup everywhere
    /// would push most ticks onto the O(tail) comparison. Reading one byte back
    /// across the tick boundary tells the two apart.
    ///
    /// An empty append is not neutral: the same content can arrive with a new
    /// reader text size, typography revision, or theme, and the tail still has to
    /// be restyled.
    static func appendedSourceIsMarkdownNeutral(_ content: String, range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }

        let bytes = content.utf8
        let start = bytes.index(
            bytes.endIndex,
            offsetBy: range.lowerBound - bytes.count
        )
        // Spaces seen since the line start, or nil when a non-space byte already
        // rules the position out as a block-marker start.
        var lineStartSpaces = lineStartSpaceCount(bytes, before: start)
        for byte in bytes[start...] {
            switch byte {
            case 33, 36, 38, 40, 41, 42, 60, 62, 91, 92, 93, 95, 96, 124, 126:
                return false
            case 45, 61:
                // `-` and `=`: only markup at the start of a line.
                if lineStartSpaces != nil { return false }
            case 10:
                lineStartSpaces = 0
            case 32:
                if let spaces = lineStartSpaces {
                    lineStartSpaces = spaces < 3 ? spaces + 1 : nil
                }
            default:
                lineStartSpaces = nil
            }
        }
        return true
    }

    /// Spaces before `index` on its line, or nil when the line already has
    /// non-space content (or an indent wider than a block marker allows). Looks
    /// back at most 4 bytes, across the tick boundary included.
    private static func lineStartSpaceCount(
        _ bytes: String.UTF8View,
        before index: String.UTF8View.Index
    ) -> Int? {
        var spaces = 0
        var cursor = index
        while cursor > bytes.startIndex {
            cursor = bytes.index(before: cursor)
            switch bytes[cursor] {
            case 10:
                return spaces
            case 32 where spaces < 3:
                spaces += 1
            default:
                return nil
            }
        }
        // The document starts here, which is also a line start.
        return spaces
    }

    /// A rendering that extends the one a cached merge already ends with.
    struct AppendedRendering {
        /// The part after the cached rendering.
        let suffix: AttributedString
        /// The whole rendering, boxed once so it can become the next cache tail.
        let rendered: NSAttributedString
    }

    /// The new part of `attributed` when it starts with exactly `rendered`'s
    /// content and attributes; nil when it does not.
    ///
    /// Characters alone are not enough to reuse a cached merge: a setext
    /// underline turns prose that already streamed into a heading without
    /// changing one character, and a plain-text comparison would keep the old
    /// styling on every later tick.
    static func appendedRendering(
        _ attributed: AttributedString,
        after rendered: NSAttributedString
    ) -> AppendedRendering? {
        let candidate = NSAttributedString(attributed)
        guard candidate.length >= rendered.length else { return nil }
        guard candidate.attributedSubstring(
            from: NSRange(location: 0, length: rendered.length)
        ).isEqual(to: rendered) else { return nil }

        let suffixLength = candidate.length - rendered.length
        let suffix = suffixLength > 0
            ? AttributedString(candidate.attributedSubstring(
                from: NSRange(location: rendered.length, length: suffixLength)
            ))
            : AttributedString()
        return AppendedRendering(suffix: suffix, rendered: candidate)
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

    /// UTF-16 offset where the tail's last paragraph starts, i.e. just past its
    /// last blank line. Text blocks join with a blank line, so an appended
    /// underline or marker lands in that paragraph. Zero when the tail is one
    /// paragraph.
    static func lastParagraphStart(in plain: NSString) -> Int {
        let length = plain.length
        guard length > 0 else { return 0 }
        let separator = plain.range(
            of: "\n\n",
            options: .backwards,
            range: NSRange(location: 0, length: length)
        )
        guard separator.location != NSNotFound else { return 0 }
        return separator.location + separator.length
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
