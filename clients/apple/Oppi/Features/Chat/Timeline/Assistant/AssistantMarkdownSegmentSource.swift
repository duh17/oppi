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

    /// UIKit-specific paint cache layered over the shared block parser. Kept
    /// for an empty prefix too, so the first freeze extends it instead of
    /// rebuilding.
    private struct StreamingSegmentState {
        var prefixBlocks: [MarkdownBlock]
        var prefixSegments: [FlatSegment]
        var buildContext: SegmentBuildContext
    }

    /// Segments the last tick froze onto a reused prefix.
    private struct FrozenSuffix {
        let segments: [FlatSegment]
        /// The first segment joined the prefix's closing text run.
        let joinedClosingText: Bool
    }

    /// The emitted last text segment while it is the streaming tail, split at
    /// the point where text from still-open blocks starts. Everything before
    /// `openStartUTF16` renders frozen blocks, so a tick only has to compare
    /// what follows it to prove the new segment extends this one.
    private struct StreamingTextTailState {
        var openStartUTF16: Int
        /// `merged` from `openStartUTF16` on, boxed once so the next tick
        /// compares attributes as well as characters.
        var tailNS: NSAttributedString
        var merged: AttributedString
        /// Reader scale and spacing restyle the emitted text after the merge,
        /// so the comparisons above only hold under the preferences it was
        /// emitted with. Frozen prefix segments are built before them and
        /// survive a change.
        let readerPreferences: FullScreenReaderPreferences?
    }

    private var streamingParser = CommonMarkStreamingParser()
    private var streamingSegmentState: StreamingSegmentState?
    private var streamingTextTail: StreamingTextTailState?

    /// How the last build's final text segment differs from the previous
    /// build's. Nil when the segment was rebuilt or the build context changed.
    private(set) var lastStreamingTextEdit: StreamingTextEdit?
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
        streamingTextTail = nil
        lastStreamingTextEdit = nil
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
        lastStreamingTextEdit = nil

        if config.isStreaming {
            // The incremental path reads fence parity from the parse's open
            // tail. Scanning the whole answer here would undo its work.
            return Self.applyReaderPreferences(to: buildSegmentsIncremental(config), config: config)
        }

        // The flag only steers live streaming rendering, which the incremental
        // path above already answered; no other caller reads it. The text a
        // canonical build hands the applier is not the streamed tail.
        lastBuildHasUnclosedCodeFence = false
        streamingTextTail = nil

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
        lastStreamingTextEdit = nil
        streamingTextTail = nil
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
        if streamingSegmentState?.buildContext != buildContext
            || streamingTextTail?.readerPreferences != config.readerPreferences {
            streamingTextTail = nil
        }
        let parseStart = MarkdownStreamingPerf.timestampNs()
        let parsed = streamingParser.parse(config.content)
        let parseEnd = MarkdownStreamingPerf.timestampNs()
        lastBuildHasUnclosedCodeFence = Self.hasUnclosedCodeFence(
            config.content,
            fromUTF8Offset: parsed.tailUTF8Offset,
            endsInCodeBlock: Self.endsInCodeBlock(parsed.tailBlocks.last)
        )

        let prefixSegments: [FlatSegment]
        let frozen: FrozenSuffix?
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
            let suffix = newlyFrozen.isEmpty
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
                )
            let extended = Self.appending(suffix, to: cached.prefixSegments)
            prefixSegments = extended.segments
            frozen = FrozenSuffix(segments: suffix, joinedClosingText: extended.grewClosingText)
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
            frozen = nil
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

        streamingSegmentState = StreamingSegmentState(
            prefixBlocks: parsed.prefixBlocks,
            prefixSegments: prefixSegments,
            buildContext: buildContext
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
            frozen: frozen,
            readerPreferences: config.readerPreferences
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

    /// Joins the prefix's closing text run to the tail's first text segment,
    /// as `FlatSegment.build` would. While that segment is also the last one,
    /// it is kept in `streamingTextTail` and edited in place past the part
    /// this tick provably left alone, which sets `lastStreamingTextEdit`.
    private func mergeSegments(
        prefix: [FlatSegment],
        tail: [FlatSegment],
        frozen: FrozenSuffix?,
        readerPreferences: FullScreenReaderPreferences?
    ) -> [FlatSegment] {
        guard case .text(let tailText)? = tail.first else {
            streamingTextTail = nil
            return prefix + tail
        }
        let closingText: AttributedString?
        if case .text(let text)? = prefix.last {
            closingText = text
        } else {
            closingText = nil
        }
        let tailIsLastSegment = tail.count == 1

        if tailIsLastSegment,
           var state = streamingTextTail,
           let opened = Self.newlyFrozenText(
               after: state,
               frozen: frozen,
               hasClosingText: closingText != nil
           ) {
            // Take the merged run out of the state before editing it. The
            // previous tick's segment array is gone by now (the applier keeps
            // only per-segment signatures, and every text view owns its own
            // NSAttributedString), so after this assignment the local is the
            // sole owner of the storage and the edit mutates it in place
            // instead of copying the whole run.
            streamingTextTail = nil
            var candidate = opened
            candidate.append(tailText)
            // Everything before the old open start is frozen and unchanged.
            // The candidate either extends the old open part, attributes
            // included, or restyled it (a closing span, a setext underline)
            // and replaces it from there.
            let candidateNS = NSAttributedString(candidate)
            let previousTailLength = state.tailNS.length
            let previousLength = state.openStartUTF16 + previousTailLength
            let extendsPrevious = candidateNS.length >= previousTailLength
                && candidateNS.attributedSubstring(
                    from: NSRange(location: 0, length: previousTailLength)
                ).isEqual(to: state.tailNS)
            let edited: Bool
            if extendsPrevious {
                if candidateNS.length > previousTailLength {
                    state.merged.append(AttributedString(candidateNS.attributedSubstring(
                        from: NSRange(
                            location: previousTailLength,
                            length: candidateNS.length - previousTailLength
                        )
                    )))
                }
                edited = true
            } else {
                edited = Self.replaceText(
                    in: &state.merged,
                    fromUTF16Offset: state.openStartUTF16,
                    with: candidate
                )
            }
            if edited {
                lastStreamingTextEdit = StreamingTextEdit(
                    unchangedUTF16Length: extendsPrevious ? previousLength : state.openStartUTF16,
                    previousUTF16Length: previousLength
                )
                let openedLength = Self.utf16Length(of: opened)
                state.openStartUTF16 += openedLength
                state.tailNS = openedLength == 0
                    ? candidateNS
                    : candidateNS.attributedSubstring(from: NSRange(
                        location: openedLength,
                        length: candidateNS.length - openedLength
                    ))
                streamingTextTail = state
                return Self.assemble(
                    prefix: prefix,
                    merged: state.merged,
                    closesWithText: closingText != nil,
                    tail: tail
                )
            }
        }

        var merged: AttributedString
        if let closingText {
            merged = closingText
            merged.append(AttributedString("\n\n"))
            merged.append(tailText)
        } else {
            merged = tailText
        }
        streamingTextTail = tailIsLastSegment
            ? StreamingTextTailState(
                openStartUTF16: closingText.map { Self.utf16Length(of: $0) + 2 } ?? 0,
                tailNS: NSAttributedString(tailText),
                merged: merged,
                readerPreferences: readerPreferences
            )
            : nil
        return Self.assemble(prefix: prefix, merged: merged, closesWithText: closingText != nil, tail: tail)
    }

    /// Text this tick froze that now sits in the emitted segment between the
    /// part `state` already treats as frozen and the open tail; empty when
    /// nothing new froze into it. Nil when the new segment's frozen part is
    /// not provably the previous one's plus that text, so the whole segment
    /// has to be rebuilt.
    private static func newlyFrozenText(
        after state: StreamingTextTailState,
        frozen: FrozenSuffix?,
        hasClosingText: Bool
    ) -> AttributedString? {
        let hadFrozenText = state.openStartUTF16 > 0
        guard let frozen else {
            // A rebuilt prefix proves nothing about its closing run. Only a
            // segment that is open text alone, before and after, compares whole.
            return !hadFrozenText && !hasClosingText ? AttributedString() : nil
        }
        guard let last = frozen.segments.last else {
            // Nothing froze: the same closing run, or none, still leads.
            return hadFrozenText == hasClosingText ? AttributedString() : nil
        }
        // The old frozen part survives when the new blocks joined that run as
        // one text segment. Otherwise the segment now starts at the new
        // closing run (or the tail), which only extends a segment that had no
        // frozen part.
        guard hadFrozenText == (frozen.segments.count == 1 && frozen.joinedClosingText) else {
            return nil
        }
        guard case .text(var text) = last else { return AttributedString() }
        text.append(AttributedString("\n\n"))
        return text
    }

    /// Replaces `text` from `offset` on. False when `offset` is not a
    /// character boundary, which the frozen/open split never produces; the
    /// caller then rebuilds the run.
    private static func replaceText(
        in text: inout AttributedString,
        fromUTF16Offset offset: Int,
        with replacement: AttributedString
    ) -> Bool {
        guard let cut = Range(NSRange(location: offset, length: 0), in: text)?.lowerBound else {
            return false
        }
        text.replaceSubrange(cut..<text.endIndex, with: replacement)
        return true
    }

    private static func assemble(
        prefix: [FlatSegment],
        merged: AttributedString,
        closesWithText: Bool,
        tail: [FlatSegment]
    ) -> [FlatSegment] {
        var result = closesWithText ? Array(prefix.dropLast()) : prefix
        result.append(.text(merged))
        result.append(contentsOf: tail.dropFirst())
        return result
    }

    private static func utf16Length(of text: AttributedString) -> Int {
        text.unicodeScalars.reduce(into: 0) { $0 += UTF16.width($1) }
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

/// How a streamed text segment changed since the previous tick, in UTF-16
/// offsets (TextKit / NSTextStorage units). The first `unchangedUTF16Length`
/// characters are identical, attributes included; the previous segment's
/// remainder, up to `previousUTF16Length`, is replaced by the new segment's
/// remainder. A plain append leaves the two lengths equal.
struct StreamingTextEdit: Equatable {
    let unchangedUTF16Length: Int
    let previousUTF16Length: Int
}

/// Slices a FlatSegment AttributedString without boxing the already-rendered prefix
/// into NSAttributedString.
enum StreamingMarkdownDelta {
    static func nsAttributedSuffix(
        _ attributed: AttributedString,
        afterUTF16Offset offset: Int
    ) -> NSAttributedString? {
        guard offset >= 0,
              let start = Range(NSRange(location: offset, length: 0), in: attributed)?.lowerBound
        else { return nil }
        if start == attributed.endIndex {
            return NSAttributedString()
        }
        return NSAttributedString(AttributedString(attributed[start...]))
    }
}
