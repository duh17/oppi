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
    }

    /// Cached state for tail-only re-parsing during streaming.
    private struct StreamingParseState {
        /// UTF-8 byte length of the finalized prefix (content before last block).
        var prefixUTF8ByteCount: Int
        /// FNV-1a 64-bit hash of the prefix content — used to detect prefix changes.
        var prefixContentHash: UInt64
        /// Parsed `MarkdownBlock` nodes for the finalized prefix region.
        var prefixBlocks: [MarkdownBlock]
        /// Pre-built `FlatSegment` array for the finalized prefix.
        var prefixSegments: [FlatSegment]
        /// Rendering context used to build `prefixSegments`.
        var buildContext: SegmentBuildContext
        /// Total content UTF-8 byte count when this state was last updated.
        /// Used to skip FNV-1a hash when content only grew (streaming appends).
        var lastContentUTF8ByteCount: Int
    }

    private struct ReferenceDefinitionScanState {
        var contentUTF8ByteCount: Int
        var hasPotentialDefinition: Bool
    }

    private var streamingState: StreamingParseState?
    private var referenceDefinitionScanState: ReferenceDefinitionScanState?

    func reset() {
        streamingState = nil
        referenceDefinitionScanState = nil
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
               sourceDirectory: config.sourceDirectory
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
                segments: segments
            )
        }
        return Self.applyReaderPreferences(to: segments, config: config)
    }

    func buildSegmentsWithSourceLineRanges(
        _ config: AssistantMarkdownContentView.Configuration,
        mergeAdjacentTextSegments: Bool = true
    ) -> FlatSegment.BuildResult {
        guard !config.isStreaming else {
            return FlatSegment.BuildResult(
                segments: buildSegments(config, mergeAdjacentTextSegments: mergeAdjacentTextSegments),
                sourceLineRanges: []
            )
        }

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

        return FlatSegment.BuildResult(
            segments: Self.applyReaderPreferences(to: build.segments, config: config),
            sourceLineRanges: build.sourceLineRanges
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
        let content = config.content
        let themeID = config.themeID
        let serverID = config.serverID
        let workspaceID = config.workspaceID
        let sessionID = config.sessionID
        let serverBaseURL = config.serverBaseURL
        let sourceDirectory = config.sourceDirectory
        let buildContext = SegmentBuildContext(
            themeID: themeID,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory
        )
        let contentUTF8 = content.utf8
        // Reference definitions can retroactively resolve links in already-finalized
        // blocks. Keep the canonical full-document path while one is present.
        let requiresCanonicalFullParse = containsPotentialLinkReferenceDefinition(content)
            || containsPotentialDisplayMath(content)

        if !requiresCanonicalFullParse,
           let state = streamingState,
           state.prefixUTF8ByteCount > 0,
           state.prefixUTF8ByteCount < contentUTF8.count {
            // Fast path: skip FNV-1a hash when content only grew (streaming appends).
            // The prefix bytes are unchanged since streaming only adds to the tail.
            // Fall back to hash verification if content shrank or was replaced.
            let contentByteCount = contentUTF8.count
            let prefixValid: Bool
            if contentByteCount >= state.lastContentUTF8ByteCount {
                prefixValid = true
            } else {
                prefixValid = fnv1a64(bytes: contentUTF8, count: state.prefixUTF8ByteCount) == state.prefixContentHash
            }

            if prefixValid {
                let boundaryIdx = contentUTF8.index(
                    contentUTF8.startIndex,
                    offsetBy: state.prefixUTF8ByteCount
                )
                let tailContent = String(content[boundaryIdx...])
                let tailLineCount = Self.countNewlines(tailContent) + 1

                let parseStart = MarkdownStreamingPerf.timestampNs()
                let (tailBlocks, tailLastBlockLine) = tailContent.isEmpty
                    ? ([], 1)
                    : parseCommonMarkWithLastLine(tailContent)
                let parseEnd = MarkdownStreamingPerf.timestampNs()

                let prefixSegments: [FlatSegment]
                if state.buildContext == buildContext {
                    prefixSegments = state.prefixSegments
                } else {
                    prefixSegments = FlatSegment.build(
                        from: state.prefixBlocks,
                        themeID: themeID,
                        serverID: serverID,
                        workspaceID: workspaceID,
                        sessionID: sessionID,
                        serverBaseURL: serverBaseURL,
                        sourceDirectory: sourceDirectory
                    )
                }

                let tailSegments = FlatSegment.build(
                    from: tailBlocks,
                    themeID: themeID,
                    serverID: serverID,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    serverBaseURL: serverBaseURL,
                    sourceDirectory: sourceDirectory
                )
                let buildEnd = MarkdownStreamingPerf.timestampNs()
                let segments = mergeSegments(prefix: prefixSegments, tail: tailSegments)

                MarkdownStreamingPerf.record(
                    parseDurationNs: parseEnd - parseStart,
                    buildDurationNs: buildEnd - parseEnd,
                    lineCount: tailLineCount,
                    isTailOnly: true,
                    isStreaming: true
                )

                if tailBlocks.count >= 2, tailLastBlockLine > 1 {
                    let tailPrefixByteCount = utf8ByteOffset(forLine: tailLastBlockLine, in: tailContent)
                    let newPrefixByteCount = state.prefixUTF8ByteCount + tailPrefixByteCount

                    if newPrefixByteCount < contentUTF8.count {
                        let tailFinalizedBlocks = Array(tailBlocks.dropLast())
                        let tailFinalizedSegments = FlatSegment.build(
                            from: tailFinalizedBlocks,
                            themeID: themeID,
                            serverID: serverID,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            serverBaseURL: serverBaseURL,
                            sourceDirectory: sourceDirectory
                        )
                        let newPrefixSegments = mergeSegments(
                            prefix: prefixSegments,
                            tail: tailFinalizedSegments
                        )

                        streamingState = StreamingParseState(
                            prefixUTF8ByteCount: newPrefixByteCount,
                            prefixContentHash: fnv1a64(bytes: contentUTF8, count: newPrefixByteCount),
                            prefixBlocks: Array((state.prefixBlocks + tailBlocks).dropLast()),
                            prefixSegments: newPrefixSegments,
                            buildContext: buildContext,
                            lastContentUTF8ByteCount: contentByteCount
                        )
                    } else {
                        streamingState = nil
                    }
                } else if state.buildContext != buildContext {
                    streamingState = StreamingParseState(
                        prefixUTF8ByteCount: state.prefixUTF8ByteCount,
                        prefixContentHash: state.prefixContentHash,
                        prefixBlocks: state.prefixBlocks,
                        prefixSegments: prefixSegments,
                        buildContext: buildContext,
                        lastContentUTF8ByteCount: contentByteCount
                    )
                }

                return segments
            }
        }

        let parseStart = MarkdownStreamingPerf.timestampNs()
        let (allBlocks, lastBlockLine) = parseCommonMarkWithLastLine(content)
        let parseEnd = MarkdownStreamingPerf.timestampNs()
        let segments = FlatSegment.build(
            from: allBlocks,
            themeID: themeID,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory
        )
        let buildEnd = MarkdownStreamingPerf.timestampNs()

        MarkdownStreamingPerf.record(
            parseDurationNs: parseEnd - parseStart,
            buildDurationNs: buildEnd - parseEnd,
            lineCount: Self.countNewlines(content) + 1,
            isTailOnly: false,
            isStreaming: true
        )

        if requiresCanonicalFullParse {
            streamingState = nil
        } else {
            storeStreamingState(
                content: content,
                contentUTF8: contentUTF8,
                allBlocks: allBlocks,
                lastBlockLine: lastBlockLine,
                themeID: themeID,
                serverID: serverID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                serverBaseURL: serverBaseURL,
                sourceDirectory: sourceDirectory,
                buildContext: buildContext
            )
        }

        return segments
    }

    private func storeStreamingState(
        content: String,
        contentUTF8: String.UTF8View,
        allBlocks: [MarkdownBlock],
        lastBlockLine: Int,
        themeID: ThemeID,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?,
        serverBaseURL: URL?,
        sourceDirectory: String?,
        buildContext: SegmentBuildContext
    ) {
        guard allBlocks.count >= 2, lastBlockLine > 1 else {
            streamingState = nil
            return
        }

        let byteOffset = utf8ByteOffset(forLine: lastBlockLine, in: content)
        guard byteOffset > 0, byteOffset < contentUTF8.count else {
            streamingState = nil
            return
        }

        let prefixBlocks = Array(allBlocks.dropLast())
        let prefixSegments = FlatSegment.build(
            from: prefixBlocks,
            themeID: themeID,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory
        )

        streamingState = StreamingParseState(
            prefixUTF8ByteCount: byteOffset,
            prefixContentHash: fnv1a64(bytes: contentUTF8, count: byteOffset),
            prefixBlocks: prefixBlocks,
            prefixSegments: prefixSegments,
            buildContext: buildContext,
            lastContentUTF8ByteCount: contentUTF8.count
        )
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

    private func utf8ByteOffset(forLine targetLine: Int, in content: String) -> Int {
        guard targetLine > 1 else { return 0 }
        var currentLine = 1
        var byteOffset = 0
        for byte in content.utf8 {
            byteOffset += 1
            if byte == UInt8(ascii: "\n") {
                currentLine += 1
                if currentLine == targetLine {
                    return byteOffset
                }
            }
        }
        return content.utf8.count
    }

    private func fnv1a64(bytes: String.UTF8View, count: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let end = bytes.index(bytes.startIndex, offsetBy: count)
        for byte in bytes[..<end] {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    /// Display delimiters can retroactively turn an earlier CommonMark block
    /// into one opaque formula. Keep the canonical full-document path whenever
    /// they are present rather than duplicating the pre-cmark scanner's HTML,
    /// indentation, fence, and code-span state machine in the streaming cache.
    private func containsPotentialDisplayMath(_ content: String) -> Bool {
        content.contains("$$") || content.contains(#"\["#) || content.contains(#"\]"#)
    }

    /// Conservatively detects CommonMark link reference definitions by their
    /// required closing-label delimiter (`]:`). Definitions may be nested in
    /// containers or use multiline labels, so line-start matching is unsafe.
    /// False positives only select the slower canonical path.
    ///
    /// Streaming source is append-only. Scan only the appended UTF-8 suffix,
    /// retaining one overlap byte so a delimiter split across ticks is found.
    private func containsPotentialLinkReferenceDefinition(_ content: String) -> Bool {
        if referenceDefinitionScanState?.hasPotentialDefinition == true {
            return true
        }

        let bytes = content.utf8
        let previousByteCount = referenceDefinitionScanState?.contentUTF8ByteCount ?? 0
        let isAppend = bytes.count >= previousByteCount
        let startOffset = isAppend ? max(0, previousByteCount - 1) : 0
        let start = bytes.index(bytes.startIndex, offsetBy: startOffset)

        var previousByte: UInt8?
        var found = false
        for byte in bytes[start...] {
            if previousByte == UInt8(ascii: "]"), byte == UInt8(ascii: ":") {
                found = true
                break
            }
            previousByte = byte
        }

        referenceDefinitionScanState = ReferenceDefinitionScanState(
            contentUTF8ByteCount: bytes.count,
            hasPotentialDefinition: found
        )
        return found
    }

    /// Count newlines via UTF-8 byte scan. Avoids the `components(separatedBy:)` array allocation.
    private static func countNewlines(_ string: String) -> Int {
        var count = 0
        for byte in string.utf8 where byte == UInt8(ascii: "\n") {
            count += 1
        }
        return count
    }
}
