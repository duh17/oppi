import Foundation

@MainActor
final class AssistantMarkdownSegmentSource {
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
        /// Theme used to build `prefixSegments`.
        var themeID: ThemeID
    }

    private var streamingState: StreamingParseState?

    func reset() {
        streamingState = nil
    }

    func buildSegments(_ config: AssistantMarkdownContentView.Configuration) -> [FlatSegment] {
        let content = config.content

        if let plainTextFallbackThreshold = config.plainTextFallbackThreshold,
           content.count > plainTextFallbackThreshold {
            var plain = AttributedString(content)
            plain.foregroundColor = config.themeID.palette.fg
            return [.text(plain)]
        }

        if !config.isStreaming,
           let cached = MarkdownSegmentCache.shared.get(
               content,
               themeID: config.themeID,
               workspaceID: config.workspaceID
           ) {
            return cached
        }

        if config.isStreaming {
            return buildSegmentsIncremental(config)
        }

        let parseStart = MarkdownStreamingPerf.timestampNs()
        let blocks = parseCommonMark(content)
        let parseEnd = MarkdownStreamingPerf.timestampNs()
        let segments = FlatSegment.build(
            from: blocks,
            themeID: config.themeID,
            workspaceID: config.workspaceID,
            serverBaseURL: config.serverBaseURL
        )
        let buildEnd = MarkdownStreamingPerf.timestampNs()

        MarkdownStreamingPerf.record(
            parseDurationNs: parseEnd - parseStart,
            buildDurationNs: buildEnd - parseEnd,
            lineCount: Self.countNewlines(content) + 1,
            isTailOnly: false,
            isStreaming: false
        )

        MarkdownSegmentCache.shared.set(
            content,
            themeID: config.themeID,
            workspaceID: config.workspaceID,
            segments: segments
        )
        return segments
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
        let workspaceID = config.workspaceID
        let serverBaseURL = config.serverBaseURL
        let contentUTF8 = content.utf8

        if let state = streamingState,
           state.prefixUTF8ByteCount > 0,
           state.prefixUTF8ByteCount < contentUTF8.count {
            let prefixHash = fnv1a64(bytes: contentUTF8, count: state.prefixUTF8ByteCount)

            if prefixHash == state.prefixContentHash {
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
                if state.themeID == themeID {
                    prefixSegments = state.prefixSegments
                } else {
                    prefixSegments = FlatSegment.build(
                        from: state.prefixBlocks,
                        themeID: themeID,
                        workspaceID: workspaceID,
                        serverBaseURL: serverBaseURL
                    )
                }

                let tailSegments = FlatSegment.build(
                    from: tailBlocks,
                    themeID: themeID,
                    workspaceID: workspaceID,
                    serverBaseURL: serverBaseURL
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
                            workspaceID: workspaceID,
                            serverBaseURL: serverBaseURL
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
                            themeID: themeID
                        )
                    } else {
                        streamingState = nil
                    }
                } else if state.themeID != themeID {
                    streamingState = StreamingParseState(
                        prefixUTF8ByteCount: state.prefixUTF8ByteCount,
                        prefixContentHash: state.prefixContentHash,
                        prefixBlocks: state.prefixBlocks,
                        prefixSegments: prefixSegments,
                        themeID: themeID
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
            workspaceID: workspaceID,
            serverBaseURL: serverBaseURL
        )
        let buildEnd = MarkdownStreamingPerf.timestampNs()

        MarkdownStreamingPerf.record(
            parseDurationNs: parseEnd - parseStart,
            buildDurationNs: buildEnd - parseEnd,
            lineCount: Self.countNewlines(content) + 1,
            isTailOnly: false,
            isStreaming: true
        )

        storeStreamingState(
            content: content,
            contentUTF8: contentUTF8,
            allBlocks: allBlocks,
            lastBlockLine: lastBlockLine,
            themeID: themeID,
            workspaceID: workspaceID,
            serverBaseURL: serverBaseURL
        )

        return segments
    }

    private func storeStreamingState(
        content: String,
        contentUTF8: String.UTF8View,
        allBlocks: [MarkdownBlock],
        lastBlockLine: Int,
        themeID: ThemeID,
        workspaceID: String?,
        serverBaseURL: URL?
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
            workspaceID: workspaceID,
            serverBaseURL: serverBaseURL
        )

        streamingState = StreamingParseState(
            prefixUTF8ByteCount: byteOffset,
            prefixContentHash: fnv1a64(bytes: contentUTF8, count: byteOffset),
            prefixBlocks: prefixBlocks,
            prefixSegments: prefixSegments,
            themeID: themeID
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

    /// Count newlines via UTF-8 byte scan. Avoids the `components(separatedBy:)` array allocation.
    private static func countNewlines(_ string: String) -> Int {
        var count = 0
        for byte in string.utf8 {
            if byte == UInt8(ascii: "\n") { count += 1 }
        }
        return count
    }
}
