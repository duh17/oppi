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
        /// Identities of `prefixBlocks` (`CommonMarkStreamingParseResult.blockIDs`).
        var prefixBlockIDs: [Int]
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
    /// Whether the content of the last build ends inside an unclosed code or
    /// math fence, as the streaming parse reported it. Only live streaming
    /// rendering reads it.
    private(set) var lastBuildHasUnclosedCodeFence = false
    /// The last streaming build could not extend the segments it had: a block
    /// it had frozen changed (a replacement, or a link definition that resolved
    /// an earlier link). Every segment may differ, so the views rebuild.
    private(set) var lastBuildReplacedFrozenSegments = false
    /// Index of the last streaming build's first segment drawn from blocks that
    /// are still open. Segments before it are frozen; any from it on can
    /// change, not only the last one (a table held open below a paragraph
    /// that may yet become a row).
    private(set) var lastBuildOpenSegmentStart = 0

    #if DEBUG
    /// Frozen-prefix blocks built since `reset()`. A steady stream builds each
    /// block once; a full prefix rebuild counts every block again per freeze.
    private(set) var debugPrefixBlockBuildCountForTesting = 0
    #endif

    func reset() {
        streamingParser.reset()
        streamingSegmentState = nil
        openTableSegment = nil
        streamingTextTail = nil
        lastStreamingTextEdit = nil
        lastBuildHasUnclosedCodeFence = false
        lastBuildReplacedFrozenSegments = false
        lastBuildOpenSegmentStart = 0
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
            return Self.applyReaderPreferences(to: buildSegmentsIncremental(config), config: config)
        }

        // The flag only steers live streaming rendering, which the incremental
        // path above already answered; no other caller reads it. The text a
        // canonical build hands the applier is not the streamed tail.
        lastBuildHasUnclosedCodeFence = false
        lastBuildReplacedFrozenSegments = false
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
        mergeAdjacentTextSegments: Bool = true,
        splitsAtHeadings: Bool = false
    ) -> FlatSegment.BuildResult {
        // Reader identity needs located top-level starts on every tick. Keep
        // this path canonical during streaming: segment splitting/merging must
        // finish before same-key occurrence ordinals are assigned.
        let content = config.content
        let identity = config.resourceAccess.identity
        lastStreamingTextEdit = nil
        streamingTextTail = nil
        let parseStart = MarkdownStreamingPerf.timestampNs()
        // One parse gives the blocks and, while streaming, whether the text
        // ends in an open fence.
        let parsed = parseCommonMarkTail(content)
        let blocks = zip(parsed.blocks, parsed.blockLineRanges).map { LocatedMarkdownBlock(block: $0, lineRange: $1) }
        lastBuildHasUnclosedCodeFence = config.isStreaming && parsed.endsInOpenBlock
        lastBuildReplacedFrozenSegments = false
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
            mergeAdjacentTextSegments: mergeAdjacentTextSegments,
            splitsAtHeadings: splitsAtHeadings
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
            ),
            headingSegments: build.headingSegments
        )
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
        lastBuildHasUnclosedCodeFence = parsed.endsInOpenBlock
        let prefixBlockIDs = Array(parsed.blockIDs.prefix(parsed.prefixBlocks.count))

        let prefixSegments: [FlatSegment]
        let frozen: FrozenSuffix?
        if let cached = streamingSegmentState,
           cached.buildContext == buildContext,
           let newlyFrozenCount = Self.newlyFrozenBlockCount(
               parsed.prefixBlocks,
               ids: prefixBlockIDs,
               after: cached,
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
            lastBuildReplacedFrozenSegments = false
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
            lastBuildReplacedFrozenSegments = streamingSegmentState.map { !$0.prefixSegments.isEmpty } ?? false
            #if DEBUG
            debugPrefixBlockBuildCountForTesting += parsed.prefixBlocks.count
            #endif
        }

        let shownTail = Self.droppingUnfinishedTableRow(parsed.tailBlocks, content: config.content)
        let tailSegments = openTableSegments(shownTail, parsed: parsed, buildContext: buildContext)
            ?? FlatSegment.build(
                from: shownTail,
                themeID: config.themeID,
                serverID: identity.serverID,
                workspaceID: identity.workspaceID,
                sessionID: identity.sessionID,
                serverBaseURL: identity.serverBaseURL,
                sourceDirectory: config.sourceDirectory,
                worktreeId: identity.worktreeId
            )
        recordOpenTableSegment(tailSegments, tail: shownTail, parsed: parsed, buildContext: buildContext)
        let buildEnd = MarkdownStreamingPerf.timestampNs()

        streamingSegmentState = StreamingSegmentState(
            prefixBlocks: parsed.prefixBlocks,
            prefixBlockIDs: prefixBlockIDs,
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

    // MARK: - Open table

    /// The built segment of a table that is the whole open tail, kept so the
    /// next tick builds only the rows its parse reports new
    /// (`openTableUnchangedRows`) instead of the whole table.
    private struct OpenTableSegment {
        let id: Int
        let buildContext: SegmentBuildContext
        let headers: [[MarkdownInline]]
        let rows: [[[MarkdownInline]]]
        let alignments: [MarkdownTableAlignment?]
    }

    private var openTableSegment: OpenTableSegment?

    /// The tail's table segment from the kept rows plus the new ones, or nil
    /// when the tail is not the kept table growing by rows.
    private func openTableSegments(
        _ shownTail: [MarkdownBlock],
        parsed: CommonMarkStreamingParseResult,
        buildContext: SegmentBuildContext
    ) -> [FlatSegment]? {
        guard let kept = openTableSegment, kept.id == parsed.blockIDs.last, kept.buildContext == buildContext,
              parsed.openTableUnchangedRows >= kept.rows.count,
              shownTail.count == 1, case .table(_, let rows, let alignments) = shownTail[0],
              alignments == kept.alignments, rows.count >= kept.rows.count else { return nil }
        guard rows.count > kept.rows.count else { return [.table(headers: kept.headers, rows: kept.rows, alignments: kept.alignments)] }
        let built = FlatSegment.build(
            from: [.table(headers: [], rows: Array(rows[kept.rows.count...]))],
            themeID: buildContext.themeID,
            serverID: buildContext.serverID,
            workspaceID: buildContext.workspaceID,
            sessionID: buildContext.sessionID,
            serverBaseURL: buildContext.serverBaseURL,
            sourceDirectory: buildContext.sourceDirectory,
            worktreeId: buildContext.worktreeId
        )
        guard built.count == 1, case .table(_, let newRows, _) = built[0] else { return nil }
        return [.table(headers: kept.headers, rows: kept.rows + newRows, alignments: kept.alignments)]
    }

    private func recordOpenTableSegment(
        _ segments: [FlatSegment],
        tail: [MarkdownBlock],
        parsed: CommonMarkStreamingParseResult,
        buildContext: SegmentBuildContext
    ) {
        guard tail.count == 1, case .table = tail[0], segments.count == 1,
              case .table(let headers, let rows, let alignments) = segments[0], let id = parsed.blockIDs.last else {
            openTableSegment = nil
            return
        }
        openTableSegment = OpenTableSegment(id: id, buildContext: buildContext, headers: headers, rows: rows, alignments: alignments)
    }

    /// A table at the open tail shows only the rows whose line has ended.
    ///
    /// Every byte of a streamed row changes the row and, with it, the table's
    /// column widths and row heights. Laying the table out per byte makes a
    /// stream cost O(table) per tick; per finished row it costs O(new rows).
    /// Once the stream ends, the canonical build shows every row.
    static func droppingUnfinishedTableRow(
        _ blocks: [MarkdownBlock],
        content: String
    ) -> [MarkdownBlock] {
        guard case .table(let headers, let rows, let alignments)? = blocks.last, !rows.isEmpty else { return blocks }
        let newline = UInt8(ascii: "\n")
        let lastLine = content.utf8.reversed().prefix { $0 != newline }
        // Spaces after the last newline start no row.
        guard lastLine.contains(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") && $0 != UInt8(ascii: "\r") })
        else { return blocks }
        var dropped = blocks
        dropped[dropped.count - 1] = .table(headers: headers, rows: Array(rows.dropLast()), alignments: alignments)
        return dropped
    }

    // MARK: - Prefix extension

    /// Blocks `blocks` grew by since `cached`, or nil when `blocks` does not
    /// extend it. Identities (start offsets) must match first. `carriedForward`
    /// says the parser kept its own frozen prefix (it only ever appends to it),
    /// so the shared blocks need no comparison; after a whole-document parse
    /// their content is compared too, since a link definition can change a
    /// block in place.
    private static func newlyFrozenBlockCount(
        _ blocks: [MarkdownBlock],
        ids: [Int],
        after cached: StreamingSegmentState,
        carriedForward: Bool
    ) -> Int? {
        guard ids.count >= cached.prefixBlockIDs.count, ids.starts(with: cached.prefixBlockIDs) else { return nil }
        if !carriedForward {
            for index in cached.prefixBlocks.indices where cached.prefixBlocks[index] != blocks[index] {
                return nil
            }
        }
        return blocks.count - cached.prefixBlocks.count
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
            lastBuildOpenSegmentStart = prefix.count
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
                return assemble(
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
        return assemble(prefix: prefix, merged: merged, closesWithText: closingText != nil, tail: tail)
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

    private func assemble(
        prefix: [FlatSegment],
        merged: AttributedString,
        closesWithText: Bool,
        tail: [FlatSegment]
    ) -> [FlatSegment] {
        lastBuildOpenSegmentStart = closesWithText ? prefix.count - 1 : prefix.count
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
        var segments = segments
        if let preferences = config.readerPreferences,
           preferences != FullScreenReaderContentFamily.markdown.defaultPreferences {
            segments = segments.map { segment in
                guard case .text(let text) = segment else { return segment }
                return .text(applyReaderPreferences(to: text, preferences: preferences))
            }
        }
        // Book typography has the last word on a chapter's text: it owns the
        // font, ink and paragraph metrics of every run it sees.
        if let appearance = config.bookAppearance {
            segments = BookReaderTextAppearance.apply(
                appearance,
                scale: config.readerPreferences?.textScale ?? 1,
                traits: config.bookTraits,
                to: segments
            )
        }
        return segments
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
