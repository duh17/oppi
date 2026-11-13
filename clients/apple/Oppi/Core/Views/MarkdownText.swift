import UIKit

// MARK: - Global Segment Cache

/// Process-wide cache for parsed markdown segments.
///
/// Keyed by a stable content hash so scroll-back can hit instantly.
/// Bounded by entry count, per-document source bytes, and total source
/// bytes so fullscreen readers can reuse large documents without keeping
/// unbounded markdown histories across session switches.
final class MarkdownSegmentCache: @unchecked Sendable {
    // SAFETY (`@unchecked Sendable`):
    // - Every mutable field (`entries`, `counter`, `totalSourceBytes`) is read/written only under `lock`.
    // - Stored values are value-semantic (`[FlatSegment]`, `Int`, `UInt64`) and never expose shared mutable references.
    // - Public APIs return copied value data and do not execute callbacks while the lock is held.
    // - This process-wide singleton intentionally allows cross-thread access, with synchronization fully handled by `NSLock`.
    static let shared = MarkdownSegmentCache()

    private struct Entry {
        let segments: [FlatSegment]
        var order: UInt64
        let sourceBytes: Int
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    private var counter: UInt64 = 0
    private var totalSourceBytes = 0

    /// Hard cap on number of cached markdown messages.
    /// Sized to hold a full session's worth of assistant messages (~128 items,
    /// ~50% are assistant messages with markdown).
    private let maxEntries = 128
    /// Process-wide source-text budget. LRU eviction in `evictIfNeeded` keeps
    /// `totalSourceBytes` at or below this cap.
    static let maxTotalSourceBytes = 4 * 1024 * 1024
    /// Per-document cap. Documents over this still render on demand.
    /// 16 KB skipped real file readers; 512 KB covers typical workspace docs
    /// while leaving the total budget as the memory bound.
    static let maxEntrySourceBytes = 512 * 1024

    func shouldCache(_ content: String) -> Bool {
        content.utf8.count <= Self.maxEntrySourceBytes
    }

    func get(
        _ content: String,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        typographyRevision: UInt64 = AppFont.revision,
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceDirectory: String? = nil,
        worktreeId: String? = nil
    ) -> [FlatSegment]? {
        guard shouldCache(content) else { return nil }
        let key = stableKey(
            for: content,
            themeID: themeID,
            typographyRevision: typographyRevision,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory,
            worktreeId: worktreeId
        )
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        counter += 1
        entry.order = counter
        entries[key] = entry
        return entry.segments
    }

    func set(
        _ content: String,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        typographyRevision: UInt64 = AppFont.revision,
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceDirectory: String? = nil,
        worktreeId: String? = nil,
        segments: [FlatSegment]
    ) {
        let sourceBytes = content.utf8.count
        guard sourceBytes <= Self.maxEntrySourceBytes else { return }

        let key = stableKey(
            for: content,
            themeID: themeID,
            typographyRevision: typographyRevision,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory,
            worktreeId: worktreeId
        )
        lock.lock()
        defer { lock.unlock() }

        if let existing = entries[key] {
            totalSourceBytes -= existing.sourceBytes
        }

        counter += 1
        entries[key] = Entry(segments: segments, order: counter, sourceBytes: sourceBytes)
        totalSourceBytes += sourceBytes
        evictIfNeeded()
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
        totalSourceBytes = 0
    }

    func snapshot() -> (entries: Int, totalSourceBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (entries: entries.count, totalSourceBytes: totalSourceBytes)
    }

    private func evictIfNeeded() {
        guard entries.count > maxEntries || totalSourceBytes > Self.maxTotalSourceBytes else { return }

        let sorted = entries.sorted { $0.value.order < $1.value.order }
        for (key, entry) in sorted {
            guard entries.count > maxEntries || totalSourceBytes > Self.maxTotalSourceBytes else { break }
            entries.removeValue(forKey: key)
            totalSourceBytes -= entry.sourceBytes
        }
    }

    private func stableKey(
        for content: String,
        themeID: ThemeID,
        typographyRevision: UInt64,
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceDirectory: String? = nil,
        worktreeId: String? = nil
    ) -> UInt64 {
        // FNV-1a 64-bit hash (stable across process launches).
        var hash: UInt64 = 14_695_981_039_346_656_037

        func mix(_ string: String?, separator: UInt64) {
            hash ^= separator
            hash &*= 1_099_511_628_211
            for byte in (string ?? "").utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }

        mix(themeID.rawValue, separator: 0xFF)
        mix(serverID, separator: 0xFE)
        mix(workspaceID, separator: 0xFD)
        mix(sessionID, separator: 0xFC)
        mix(serverBaseURL?.absoluteString, separator: 0xFB)
        mix(sourceDirectory, separator: 0xFA)
        mix(worktreeId, separator: 0xF8)
        // Segments bake fonts in, so entries from before a font rebuild miss.
        hash ^= typographyRevision
        hash &*= 1_099_511_628_211
        mix(content, separator: 0xF9)
        return hash
    }
}

// MARK: - Shared Workspace File URL Helpers

enum WorkspaceFileURL {
    /// Build the client-local workspace-file identity URL
    /// `{base}/workspaces/{workspaceID}/raw/{path}`. It is a cache and routing
    /// key, never requested: the server has no such route, and bytes come from
    /// `/files/current`.
    ///
    /// `worktreeId` uses the same query name as `APIClient` workspace fetches.
    /// Nil, blank, and `main` omit the query so main-checkout URLs keep their
    /// historical identity.
    static func make(baseURL: URL, workspaceID: String, filePath: String, worktreeId: String? = nil) -> URL? {
        guard !workspaceID.isEmpty else { return nil }
        let normalizedPath = filePath.hasPrefix("/") ? String(filePath.dropFirst()) : filePath
        guard !normalizedPath.isEmpty else { return nil }

        let url = baseURL
            .appendingPathComponent("workspaces")
            .appendingPathComponent(workspaceID)
            .appendingPathComponent("raw")
            .appendingPathComponent(normalizedPath)
        guard let queryItem = worktreeQueryItem(worktreeId) else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = [queryItem]
        return components.url ?? url
    }

    /// Parse the workspace-file identity URL `{base}/workspaces/{workspaceID}/raw/{path}`.
    /// Also accepts legacy `/files/` URLs from older transcript renders.
    static func parse(_ url: URL) -> (workspaceID: String, filePath: String, worktreeId: String?)? {
        let components = url.pathComponents

        guard let workspaceIndex = components.firstIndex(of: "workspaces"),
              components.count > workspaceIndex + 1 else {
            return nil
        }

        let workspaceID = components[workspaceIndex + 1]
        guard !workspaceID.isEmpty else { return nil }

        let routeSearchStart = workspaceIndex + 2
        guard routeSearchStart < components.count,
              let routeIndex = components[routeSearchStart..<components.count].firstIndex(where: { $0 == "raw" || $0 == "files" }),
              components.count > routeIndex + 1 else {
            return nil
        }

        let filePath = components[(routeIndex + 1)...].joined(separator: "/")
        guard !filePath.isEmpty else { return nil }

        return (workspaceID: workspaceID, filePath: filePath, worktreeId: worktreeId(from: url))
    }

    /// Same query name as `APIClient.workspaceWorktreeQueryItems`. Nil, blank,
    /// and `main` omit the item so cache identity matches the implicit checkout.
    private static func worktreeQueryItem(_ worktreeId: String?) -> URLQueryItem? {
        let trimmed = worktreeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "main" else { return nil }
        return URLQueryItem(name: "worktreeId", value: trimmed)
    }

    private static func worktreeId(from url: URL) -> String? {
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "worktreeId" })?
            .value
        return worktreeQueryItem(value)?.value
    }
}

enum SessionFileURL {
    private static let scheme = "oppi-session-file"

    /// Build a client-local URL that encodes a session-scoped file fetch.
    static func make(workspaceID: String, sessionID: String, filePath: String) -> URL? {
        guard !workspaceID.isEmpty, !sessionID.isEmpty, !filePath.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "session-file"
        components.path = "/\(workspaceID)/\(sessionID)"
        components.queryItems = [
            URLQueryItem(name: "path", value: filePath),
        ]
        return components.url
    }

    /// Parse a client-local `oppi-session-file://...` URL.
    static func parse(_ url: URL) -> (workspaceID: String, sessionID: String, filePath: String)? {
        guard url.scheme == scheme else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        let workspaceID = components[0]
        let sessionID = components[1]
        guard !workspaceID.isEmpty, !sessionID.isEmpty,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let filePath = query.queryItems?.first(where: { $0.name == "path" })?.value,
              !filePath.isEmpty else {
            return nil
        }
        return (workspaceID: workspaceID, sessionID: sessionID, filePath: filePath)
    }
}

/// Client-local identity URL for an owner-host image. It is never requested
/// directly: the bytes come from an authenticated full-byte GET on the
/// host-origin current-file read. Distinct from workspace/session file URLs so
/// sandbox remapping can reuse the AV host-file route instead of pretending
/// the image is a workspace path.
///
/// Cache identity includes server and route context so `/tmp/a.png` from
/// two servers or two sessions cannot share NativeMarkdownImageView's cache.
enum HostFileURL {
    private static let scheme = "oppi-host-file"

    static func make(
        filePath: String,
        serverID: String? = nil,
        serverBaseURL: URL? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        worktreeId: String? = nil
    ) -> URL? {
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "host-file"
        var items = [URLQueryItem(name: "path", value: path)]
        if let server = scopedQueryValue(serverID) ?? scopedQueryValue(serverBaseURL?.absoluteString) {
            items.append(URLQueryItem(name: "server", value: server))
        }
        if let workspaceID = scopedQueryValue(workspaceID) {
            items.append(URLQueryItem(name: "workspaceID", value: workspaceID))
        }
        if let sessionID = scopedQueryValue(sessionID) {
            items.append(URLQueryItem(name: "sessionID", value: sessionID))
        }
        if let worktreeId = scopedQueryValue(worktreeId), worktreeId != "main" {
            items.append(URLQueryItem(name: "worktreeId", value: worktreeId))
        }
        components.queryItems = items
        return components.url
    }

    static func parse(_ url: URL) -> String? {
        guard url.scheme == scheme,
              url.host == "host-file",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = query.queryItems?.first(where: { $0.name == "path" })?.value
        else {
            return nil
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func scopedQueryValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Segment types for the flat renderer.
///
/// Built once from `[MarkdownBlock]` via `build(from:)`, then cached in `@State`.
/// All AttributedString construction happens at build time,
/// so consumers can render with a simple switch over pre-computed values.
enum FlatSegment: Sendable {
    case text(AttributedString)
    case codeBlock(language: String?, code: String)
    case table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [MarkdownTableAlignment?] = [])
    case thematicBreak
    /// A standalone image paragraph. The URL is fully resolved at build time
    /// using the workspace context or a host-file source. Rendered by `NativeMarkdownImageView`,
    /// no larger than `size` when the Markdown gives one.
    case image(alt: String, url: URL, size: MarkdownEmbedSize? = nil)
    /// An Oppi-authenticated native video embed from `![[video-file]]` or `![](video-file)`.
    case video(MarkdownVideoEmbed)
    /// An Oppi-authenticated native audio embed from `![[audio-file]]` or `![](audio-file)`.
    case audio(MarkdownAudioEmbed)
    /// An Oppi-authenticated native USDZ embed from `![[usdz-file]]` or `![](usdz-file)`.
    case usdz(MarkdownUSDZEmbed)
    /// A mermaid diagram code block. The applier decides whether to render
    /// the diagram or show as a code block based on streaming state.
    case mermaidDiagram(code: String)
    /// A GeoJSON/TopoJSON fence. Closed fences render a map; open fences stay code.
    case geoJSONMap(code: String, kind: GeoJSONViewerPlan.Kind)
    /// A LaTeX math code block. Rendered as a formula when the fence is
    /// closed, or as a syntax-highlighted code block while streaming.
    case latexBlock(code: String)

    /// Convert CommonMark blocks into renderable segments.
    ///
    /// Adjacent text-like blocks are merged into a single `.text` segment so
    /// native selection can cross paragraph/list/heading boundaries.
    /// Code blocks and tables remain standalone segments.
    ///
    /// When image links resolve to remote, workspace-relative, or session file
    /// URLs, paragraph image inlines are promoted to `.image` segments instead
    /// of the alt-text fallback. Direct remote URL fetching is still gated by
    /// `NativeMarkdownImageView`.
    /// Cached paragraph separator. Created once to avoid repeated allocation.
    private static let paragraphSeparator = AttributedString("\n\n")

    static func build(
        from blocks: [MarkdownBlock],
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        /// Directory path of the source markdown file (e.g. "docs/").
        /// Used to resolve relative image paths like `images/foo.png`
        /// → `docs/images/foo.png` in the workspace.
        sourceDirectory: String? = nil,
        /// Source-session firstCheckout worktree for workspace image URLs.
        /// Nil/main omit the query so unrelated callers stay checkout-blind.
        worktreeId: String? = nil,
        /// Timeline markdown merges adjacent text-like blocks so native text
        /// selection can cross paragraphs. Full-screen readers can disable
        /// merging and virtualize at paragraph/list granularity while using the
        /// same parser and render views.
        mergeAdjacentTextSegments: Bool = true
    ) -> [Self] {
        buildResult(
            from: blocks,
            themeID: themeID,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory,
            worktreeId: worktreeId,
            mergeAdjacentTextSegments: mergeAdjacentTextSegments
        ).segments
    }

    static func buildWithSourceLineRanges(
        from blocks: [LocatedMarkdownBlock],
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceDirectory: String? = nil,
        worktreeId: String? = nil,
        mergeAdjacentTextSegments: Bool = true,
        splitsAtHeadings: Bool = false
    ) -> BuildResult {
        buildResult(
            from: blocks.map(\.block),
            themeID: themeID,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceDirectory: sourceDirectory,
            worktreeId: worktreeId,
            sourceLineRanges: blocks.map(\.lineRange),
            mergeAdjacentTextSegments: mergeAdjacentTextSegments,
            splitsAtHeadings: splitsAtHeadings
        ).boundingTextSegments()
    }

    private static func buildResult(
        from blocks: [MarkdownBlock],
        themeID: ThemeID,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?,
        serverBaseURL: URL?,
        sourceDirectory: String?,
        worktreeId: String? = nil,
        sourceLineRanges: [ClosedRange<Int>?]? = nil,
        mergeAdjacentTextSegments: Bool,
        splitsAtHeadings: Bool = false
    ) -> BuildResult {
        let palette = themeID.palette
        let rewritten = MarkdownWikiLinkRewriter.rewrite(
            blocks: blocks,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: sourceDirectory,
            linksHeadings: splitsAtHeadings
        )
        let (blocks, sourceLineRanges) = MarkdownTaskListSplit.split(rewritten, lineRanges: sourceLineRanges)
        var result: [Self] = []
        result.reserveCapacity(blocks.count)
        var resultLineRanges: [ClosedRange<Int>?] = []
        resultLineRanges.reserveCapacity(blocks.count)

        var pendingText = AttributedString()
        var pendingTextLineRange: ClosedRange<Int>?
        var hasPendingText = false
        var headingSegments: [Int?] = []

        func mergedLineRange(_ lhs: ClosedRange<Int>?, _ rhs: ClosedRange<Int>?) -> ClosedRange<Int>? {
            switch (lhs, rhs) {
            case (nil, nil):
                return nil
            case (let range?, nil), (nil, let range?):
                return range
            case (let lhs?, let rhs?):
                return min(lhs.lowerBound, rhs.lowerBound)...max(lhs.upperBound, rhs.upperBound)
            }
        }

        func sourceLineRange(at index: Int) -> ClosedRange<Int>? {
            guard let sourceLineRanges, sourceLineRanges.indices.contains(index) else { return nil }
            return sourceLineRanges[index]
        }

        func appendSegment(_ segment: Self, lineRange: ClosedRange<Int>?) {
            result.append(segment)
            resultLineRanges.append(lineRange)
        }

        func flushPendingText() {
            guard hasPendingText, !pendingText.characters.isEmpty else { return }
            appendSegment(.text(pendingText), lineRange: pendingTextLineRange)
            pendingText = AttributedString()
            pendingTextLineRange = nil
            hasPendingText = false
        }

        func appendTextBlock(_ attributed: AttributedString, lineRange: ClosedRange<Int>?) {
            guard !attributed.characters.isEmpty else { return }
            guard mergeAdjacentTextSegments else {
                flushPendingText()
                appendSegment(.text(attributed), lineRange: lineRange)
                return
            }
            if hasPendingText {
                pendingText.append(paragraphSeparator)
            }
            pendingText.append(attributed)
            pendingTextLineRange = mergedLineRange(pendingTextLineRange, lineRange)
            hasPendingText = true
        }

        func appendCodeSegment(language: String?, code: String, lineRange: ClosedRange<Int>?) {
            if let lang = language {
                switch lang.lowercased() {
                case "geojson":
                    appendSegment(.geoJSONMap(code: code, kind: .geojson), lineRange: lineRange)
                    return
                case "topojson":
                    appendSegment(.geoJSONMap(code: code, kind: .topojson), lineRange: lineRange)
                    return
                default:
                    break
                }
            }
            if let lang = language, SyntaxLanguage.detect(lang) == .mermaid {
                appendSegment(.mermaidDiagram(code: code), lineRange: lineRange)
            } else if let lang = language, SyntaxLanguage.detect(lang) == .latex {
                appendSegment(.latexBlock(code: code), lineRange: lineRange)
            } else {
                appendSegment(.codeBlock(language: language, code: code), lineRange: lineRange)
            }
        }

        // Render list item text as attributed lines, but keep nested block-level
        // nodes (fenced code, tables, thematic breaks) as standalone segments.
        // This preserves code fences inside list items instead of dropping them.
        func appendListBlock(
            items: [[MarkdownBlock]],
            lineRange: ClosedRange<Int>?,
            markerForItem: (Int) -> AttributedString,
            continuationForItem: (Int) -> AttributedString
        ) {
            var textLines: [AttributedString] = []
            textLines.reserveCapacity(items.count)

            func flushListTextLines() {
                guard !textLines.isEmpty else { return }
                var merged = AttributedString()
                for (lineIndex, line) in textLines.enumerated() {
                    if lineIndex > 0 {
                        merged.append(AttributedString("\n"))
                    }
                    merged.append(line)
                }
                appendTextBlock(merged, lineRange: lineRange)
                textLines.removeAll(keepingCapacity: true)
            }

            for (itemIndex, itemBlocks) in items.enumerated() {
                var itemHasPrefix = false
                var emittedAnyRenderable = false

                func appendItemText(_ content: AttributedString) {
                    guard !content.characters.isEmpty else { return }

                    let prefix = itemHasPrefix ? continuationForItem(itemIndex) : markerForItem(itemIndex)
                    let continuation = continuationForItem(itemIndex)
                    var line = prefix
                    line.append(Self.prefixLines(afterFirstIn: content, with: continuation))
                    textLines.append(line)
                    itemHasPrefix = true
                    emittedAnyRenderable = true
                }

                for itemBlock in itemBlocks {
                    switch itemBlock {
                    case .codeBlock(let language, let code):
                        if !itemHasPrefix {
                            textLines.append(markerForItem(itemIndex))
                            itemHasPrefix = true
                        }
                        flushListTextLines()
                        flushPendingText()
                        appendCodeSegment(language: language, code: code, lineRange: lineRange)
                        emittedAnyRenderable = true

                    case .math(let math, let isClosed):
                        let segment = mathSegment(math, isClosed: isClosed, palette: palette)
                        if case .text(let attributed) = segment {
                            appendItemText(attributed)
                            continue
                        }
                        if !itemHasPrefix {
                            textLines.append(markerForItem(itemIndex))
                            itemHasPrefix = true
                        }
                        flushListTextLines()
                        flushPendingText()
                        appendSegment(segment, lineRange: lineRange)
                        emittedAnyRenderable = true

                    case .table(let headers, let rows, let alignments):
                        if !itemHasPrefix {
                            textLines.append(markerForItem(itemIndex))
                            itemHasPrefix = true
                        }
                        flushListTextLines()
                        flushPendingText()
                        appendSegment(.table(headers: headers, rows: rows, alignments: alignments), lineRange: lineRange)
                        emittedAnyRenderable = true

                    case .thematicBreak:
                        if !itemHasPrefix {
                            textLines.append(markerForItem(itemIndex))
                            itemHasPrefix = true
                        }
                        flushListTextLines()
                        flushPendingText()
                        appendSegment(.thematicBreak, lineRange: lineRange)
                        emittedAnyRenderable = true

                    case .unorderedList(let nestedItems):
                        let nestedBlock = MarkdownBlock.unorderedList(nestedItems)
                        if Self.containsStandaloneListBlock(nestedBlock) {
                            flushListTextLines()
                            flushPendingText()
                            appendListBlock(
                                items: nestedItems,
                                lineRange: lineRange,
                                markerForItem: { _ in
                                    var marker = AttributedString("    • ")
                                    marker.uiKit.foregroundColor = palette.ui.mdListBullet
                                    return marker
                                },
                                continuationForItem: { _ in AttributedString("      ") }
                            )
                        } else {
                            appendItemText(Self.attributedString(for: nestedBlock, palette: palette))
                        }
                        emittedAnyRenderable = true

                    case .orderedList(let start, let nestedItems):
                        let nestedBlock = MarkdownBlock.orderedList(start: start, nestedItems)
                        if Self.containsStandaloneListBlock(nestedBlock) {
                            flushListTextLines()
                            flushPendingText()
                            appendListBlock(
                                items: nestedItems,
                                lineRange: lineRange,
                                markerForItem: { nestedIndex in
                                    let markerText = "    \(start + nestedIndex). "
                                    var marker = AttributedString(markerText)
                                    marker.uiKit.foregroundColor = palette.ui.mdListBullet
                                    marker.uiKit.font = AppFont.messageBody
                                    return marker
                                },
                                continuationForItem: { nestedIndex in
                                    let markerText = "    \(start + nestedIndex). "
                                    var continuation = AttributedString(String(repeating: " ", count: markerText.count))
                                    continuation.uiKit.font = AppFont.messageBody
                                    return continuation
                                }
                            )
                        } else {
                            appendItemText(Self.attributedString(for: nestedBlock, palette: palette))
                        }
                        emittedAnyRenderable = true

                    case .paragraph(let inlines):
                        if Self.inlinesContainPromotedMediaEmbed(inlines),
                           let imageSegments = resolveParagraphImageSegments(
                            inlines: inlines,
                            palette: palette,
                            serverID: serverID,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            serverBaseURL: serverBaseURL,
                            sourceDirectory: sourceDirectory,
                            worktreeId: worktreeId
                           ) {
                            for segment in imageSegments {
                                if case .text(let attributed) = segment {
                                    appendItemText(attributed)
                                    continue
                                }
                                if !itemHasPrefix {
                                    textLines.append(markerForItem(itemIndex))
                                    itemHasPrefix = true
                                }
                                flushListTextLines()
                                flushPendingText()
                                appendSegment(segment, lineRange: lineRange)
                                emittedAnyRenderable = true
                            }
                        } else {
                            appendItemText(Self.attributedString(for: itemBlock, palette: palette))
                        }

                    default:
                        appendItemText(Self.attributedString(for: itemBlock, palette: palette))
                    }
                }

                if !emittedAnyRenderable, !itemHasPrefix {
                    textLines.append(markerForItem(itemIndex))
                }
            }

            flushListTextLines()
        }

        for (blockIndex, block) in blocks.enumerated() {
            let lineRange = sourceLineRange(at: blockIndex)

            switch block {
            case .codeBlock(let language, let code):
                flushPendingText()
                appendCodeSegment(language: language, code: code, lineRange: lineRange)

            case .table(let headers, let rows, let alignments):
                flushPendingText()
                appendSegment(.table(headers: headers, rows: rows, alignments: alignments), lineRange: lineRange)

            case .thematicBreak:
                flushPendingText()
                appendSegment(.thematicBreak, lineRange: lineRange)

            case .math(let math, let isClosed):
                let segment = mathSegment(math, isClosed: isClosed, palette: palette)
                if case .text(let attributed) = segment {
                    appendTextBlock(attributed, lineRange: lineRange)
                } else {
                    flushPendingText()
                    appendSegment(segment, lineRange: lineRange)
                }

            case .paragraph(let inlines):
                // Images, media embeds and display formulas become segments of
                // their own; the text around them stays text.
                if let imageSegments = resolveParagraphImageSegments(
                    inlines: inlines,
                    palette: palette,
                    serverID: serverID,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    serverBaseURL: serverBaseURL,
                    sourceDirectory: sourceDirectory,
                    worktreeId: worktreeId
                ) {
                    for segment in imageSegments {
                        if case .text(let attributed) = segment {
                            appendTextBlock(attributed, lineRange: lineRange)
                        } else {
                            flushPendingText()
                            appendSegment(segment, lineRange: lineRange)
                        }
                    }
                } else {
                    let attributed = Self.attributedString(for: block, palette: palette)
                    appendTextBlock(attributed, lineRange: lineRange)
                }

            case .unorderedList(let items):
                appendListBlock(
                    items: items,
                    lineRange: lineRange,
                    markerForItem: { _ in
                        var marker = AttributedString("  • ")
                        marker.uiKit.foregroundColor = palette.ui.mdListBullet
                        return marker
                    },
                    continuationForItem: { _ in AttributedString("    ") }
                )

            case .orderedList(let start, let items):
                appendListBlock(
                    items: items,
                    lineRange: lineRange,
                    markerForItem: { itemIndex in
                        let markerText = "  \(start + itemIndex). "
                        var marker = AttributedString(markerText)
                        marker.uiKit.foregroundColor = palette.ui.mdListBullet
                        marker.uiKit.font = AppFont.messageBody
                        return marker
                    },
                    continuationForItem: { itemIndex in
                        let markerText = "  \(start + itemIndex). "
                        var continuation = AttributedString(String(repeating: " ", count: markerText.count))
                        continuation.uiKit.font = AppFont.messageBody
                        return continuation
                    }
                )

            case .blockQuote(let children):
                if children.contains(where: Self.containsStandaloneListBlock) {
                    for child in children {
                        if case .math(let math, let isClosed) = child {
                            let segment = mathSegment(math, isClosed: isClosed, palette: palette)
                            if case .text(let attributed) = segment {
                                appendTextBlock(Self.applyingQuoteChrome(to: attributed, palette: palette), lineRange: lineRange)
                            } else {
                                flushPendingText()
                                appendSegment(segment, lineRange: lineRange)
                            }
                        } else if case .paragraph(let inlines) = child,
                           Self.inlinesContainPromotedMediaEmbed(inlines),
                           let imageSegments = resolveParagraphImageSegments(
                            inlines: inlines,
                            palette: palette,
                            serverID: serverID,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            serverBaseURL: serverBaseURL,
                            sourceDirectory: sourceDirectory,
                            worktreeId: worktreeId
                           ) {
                            for segment in imageSegments {
                                if case .text(let attributed) = segment {
                                    appendTextBlock(
                                        Self.applyingQuoteChrome(to: attributed, palette: palette),
                                        lineRange: lineRange
                                    )
                                } else {
                                    flushPendingText()
                                    appendSegment(segment, lineRange: lineRange)
                                }
                            }
                        } else {
                            appendTextBlock(
                                Self.attributedString(for: .blockQuote([child]), palette: palette),
                                lineRange: lineRange
                            )
                        }
                    }
                } else {
                    appendTextBlock(
                        Self.attributedString(for: block, palette: palette),
                        lineRange: lineRange
                    )
                }

            case .heading:
                // A heading that opens its own segment can be scrolled to.
                let attributed = Self.attributedString(for: block, palette: palette)
                let opensSegment = splitsAtHeadings || !mergeAdjacentTextSegments
                if opensSegment { flushPendingText() }
                headingSegments.append(opensSegment && !attributed.characters.isEmpty ? result.count : nil)
                appendTextBlock(attributed, lineRange: lineRange)

            default:
                let attributed = Self.attributedString(for: block, palette: palette)
                appendTextBlock(attributed, lineRange: lineRange)
            }
        }

        flushPendingText()
        return BuildResult(
            segments: result,
            sourceLineRanges: resultLineRanges,
            headingSegments: headingSegments
        )
    }

    private static func containsStandaloneListBlock(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .codeBlock, .table, .thematicBreak, .math:
            true
        case .paragraph(let inlines):
            inlinesContainPromotedMediaEmbed(inlines)
        case .unorderedList(let items), .orderedList(_, let items):
            items.flatMap { $0 }.contains(where: containsStandaloneListBlock)
        case .blockQuote(let children):
            children.contains(where: containsStandaloneListBlock)
        case .taskList(let items):
            items.flatMap(\.content).contains(where: containsStandaloneListBlock)
        case .heading, .htmlBlock:
            false
        }
    }

    /// Whether a paragraph inside a list or quote holds something drawn as its
    /// own view: a media embed or display formula anywhere, or an image at the
    /// paragraph's top level (`resolveParagraphImageSegments` promotes only
    /// those; an image inside a link stays its alt text).
    private static func inlinesContainPromotedMediaEmbed(_ inlines: [MarkdownInline]) -> Bool {
        inlines.contains { if case .image = $0 { true } else { false } } || inlinesContainMediaEmbed(inlines)
    }

    private static func inlinesContainMediaEmbed(_ inlines: [MarkdownInline]) -> Bool {
        inlines.contains { inline in
            switch inline {
            case .videoEmbed, .audioEmbed, .usdzEmbed:
                return true
            case .math(let math):
                return math.isDisplay
            case .emphasis(let children),
                 .strong(let children),
                 .strikethrough(let children),
                 .link(let children, _):
                return inlinesContainMediaEmbed(children)
            case .text, .code, .image, .softBreak, .hardBreak, .html:
                return false
            }
        }
    }

    private static func prefixLines(
        afterFirstIn attributed: AttributedString,
        with prefix: AttributedString
    ) -> AttributedString {
        guard !prefix.characters.isEmpty, attributed.characters.contains("\n") else { return attributed }

        var result = AttributedString()
        var segmentStart = attributed.startIndex
        var cursor = attributed.startIndex

        while cursor < attributed.endIndex {
            let character = attributed.characters[cursor]
            let next = attributed.characters.index(after: cursor)
            if character == "\n" {
                result.append(AttributedString(attributed[segmentStart ..< next]))
                if next < attributed.endIndex {
                    result.append(prefix)
                }
                segmentStart = next
            }
            cursor = next
        }

        if segmentStart < attributed.endIndex {
            result.append(AttributedString(attributed[segmentStart ..< attributed.endIndex]))
        }
        return result
    }

    private static func applyingQuoteChrome(
        to attributed: AttributedString,
        palette: ThemePalette
    ) -> AttributedString {
        if attributed.characters.contains("▎") {
            return attributed
        }
        var quoted = AttributedString("▎ ")
        quoted.uiKit.foregroundColor = palette.ui.mdQuoteBorder
        var body = attributed
        body.uiKit.foregroundColor = palette.ui.mdQuote
        quoted.append(body)
        return quoted
    }

    // MARK: - Formulas

    /// A display formula's segment, or its source as text when the block is
    /// still open (streaming, or a closer that never came) or the TeX parser
    /// rejects it: what was written stays readable.
    private static func mathSegment(_ math: MarkdownMath, isClosed: Bool, palette: ThemePalette) -> Self {
        if isClosed, TeXMathParser().parseValidated(math.latex).isRenderable { return .latexBlock(code: math.latex) }
        var container = AttributeContainer()
        container.uiKit.foregroundColor = palette.ui.fg
        container.uiKit.font = AppFont.messageBody
        return .text(AttributedString(math.source, attributes: container))
    }

    static func formulaAccessibilityLabel(for source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = TeXMathParser().parseValidated(trimmed)
        let plain = parsed.isRenderable && !containsLossyAccessibilityNode(in: parsed.nodes)
            ? mathPlainText(from: parsed.nodes)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let accessibleValue = plain.isEmpty ? trimmed : plain
        if plain.isEmpty {
            return String(
                format: String(localized: "Math formula source: %@"),
                accessibleValue
            )
        }
        return String(format: String(localized: "Math formula: %@"), accessibleValue)
    }

    private static func mathPlainText(from nodes: [MathNode]) -> String {
        var output = ""
        for node in nodes {
            appendMathPlainText(node, to: &output)
        }
        return output
    }

    private static func appendMathPlainText(_ node: MathNode, to output: inout String) {
        switch node {
        case .number(let value), .variable(let value), .text(let value):
            appendMathToken(value, to: &output)
        case .operator(let op):
            appendMathOperator(op, to: &output)
        case .symbol(let symbol):
            appendMathToken(mathSymbolText(symbol), to: &output)
        case .fraction(let numerator, let denominator):
            appendMathToken(groupedFractionOperand(numerator), to: &output)
            appendMathToken("/", to: &output)
            appendMathToken(groupedFractionOperand(denominator), to: &output)
        case .superscript(let base, let exponent):
            appendMathToken(mathPlainText(from: base), to: &output)
            appendMathToken("^", to: &output)
            appendMathToken(groupedScriptOperand(exponent), to: &output)
        case .subscript(let base, let index):
            appendMathToken(mathPlainText(from: base), to: &output)
            appendMathToken("_", to: &output)
            appendMathToken(groupedScriptOperand(index), to: &output)
        case .subSuperscript(let base, let sub, let sup):
            appendMathToken(mathPlainText(from: base), to: &output)
            appendMathToken("_", to: &output)
            appendMathToken(groupedScriptOperand(sub), to: &output)
            appendMathToken("^", to: &output)
            appendMathToken(groupedScriptOperand(sup), to: &output)
        case .sqrt(let index, let radicand):
            appendMathToken("√", to: &output)
            if let index {
                appendMathToken("[", to: &output)
                appendMathToken(mathPlainText(from: index), to: &output)
                appendMathToken("]", to: &output)
            }
            appendMathToken("(", to: &output)
            appendMathToken(mathPlainText(from: radicand), to: &output)
            appendMathToken(")", to: &output)
        case .group(let body), .font(_, let body), .accent(_, let body):
            appendMathToken(mathPlainText(from: body), to: &output)
        case .leftRight(let left, let right, let body):
            appendMathToken(delimiterText(left), to: &output)
            appendMathToken(mathPlainText(from: body), to: &output)
            appendMathToken(delimiterText(right), to: &output)
        case .matrix(let rows, _), .environment(_, let rows):
            let rowText = rows.map { row in
                row.map { mathPlainText(from: $0) }.joined(separator: " | ")
            }.joined(separator: "; ")
            appendMathToken(rowText, to: &output)
        case .space:
            appendSpace(to: &output)
        case .bigOperator(let kind, let limits):
            appendMathToken(bigOperatorText(kind), to: &output)
            if let lower = limits?.lower {
                appendMathToken("_", to: &output)
                appendMathToken(groupedScriptOperand(lower), to: &output)
            }
            if let upper = limits?.upper {
                appendMathToken("^", to: &output)
                appendMathToken(groupedScriptOperand(upper), to: &output)
            }
        }
    }

    private static func groupedFractionOperand(_ nodes: [MathNode]) -> String {
        groupedMathOperand(nodes)
    }

    private static func groupedScriptOperand(_ nodes: [MathNode]) -> String {
        groupedMathOperand(nodes)
    }

    private static func groupedMathOperand(_ nodes: [MathNode]) -> String {
        let plain = mathPlainText(from: nodes)
        guard nodes.count != 1 || !isAtomicFractionOperand(nodes[0]) else {
            return plain
        }
        return "(\(plain))"
    }

    private static func isAtomicFractionOperand(_ node: MathNode) -> Bool {
        switch node {
        case .number, .variable, .text, .symbol:
            return true
        default:
            return false
        }
    }

    private static func containsLossyAccessibilityNode(in nodes: [MathNode]) -> Bool {
        nodes.contains(where: containsLossyAccessibilityNode)
    }

    private static func containsLossyAccessibilityNode(_ node: MathNode) -> Bool {
        switch node {
        case .accent:
            // Omitting an accent changes the expression. Until a spoken accent
            // vocabulary is available, preserve exact TeX instead.
            return true
        case .fraction(let numerator, let denominator):
            return containsLossyAccessibilityNode(in: numerator)
                || containsLossyAccessibilityNode(in: denominator)
        case .superscript(let base, let exponent):
            return containsLossyAccessibilityNode(in: base)
                || containsLossyAccessibilityNode(in: exponent)
        case .subscript(let base, let index):
            return containsLossyAccessibilityNode(in: base)
                || containsLossyAccessibilityNode(in: index)
        case .subSuperscript(let base, let sub, let sup):
            return containsLossyAccessibilityNode(in: base)
                || containsLossyAccessibilityNode(in: sub)
                || containsLossyAccessibilityNode(in: sup)
        case .sqrt(let index, let radicand):
            return (index.map { containsLossyAccessibilityNode(in: $0) } ?? false)
                || containsLossyAccessibilityNode(in: radicand)
        case .group(let body), .font(_, let body):
            return containsLossyAccessibilityNode(in: body)
        case .leftRight(_, _, let body):
            return containsLossyAccessibilityNode(in: body)
        case .matrix(let rows, _), .environment(_, let rows):
            return rows.flatMap { $0 }.contains { containsLossyAccessibilityNode(in: $0) }
        case .bigOperator(_, let limits):
            return (limits?.lower.map { containsLossyAccessibilityNode(in: $0) } ?? false)
                || (limits?.upper.map { containsLossyAccessibilityNode(in: $0) } ?? false)
        case .number, .variable, .operator, .symbol, .text, .space:
            return false
        }
    }

    private static func appendMathOperator(_ op: MathOperator, to output: inout String) {
        let text: String
        switch op {
        case .plus: text = "+"
        case .minus: text = "−"
        case .times: text = "×"
        case .div: text = "÷"
        case .cdot: text = "·"
        case .pm: text = "±"
        case .mp: text = "∓"
        case .star: text = "*"
        case .equal: text = "="
        case .lessThan: text = "<"
        case .greaterThan: text = ">"
        case .leq: text = "≤"
        case .geq: text = "≥"
        case .neq: text = "≠"
        case .approx: text = "≈"
        case .equiv: text = "≡"
        case .sim: text = "∼"
        case .in: text = "∈"
        case .subset: text = "⊂"
        case .supset: text = "⊃"
        case .subseteq: text = "⊆"
        case .supseteq: text = "⊇"
        case .cup: text = "∪"
        case .cap: text = "∩"
        case .to, .rightarrow: text = "→"
        case .leftarrow: text = "←"
        case .mapsto: text = "↦"
        case .iff: text = "⟺"
        case .doubleRightarrow: text = "⇒"
        case .doubleLeftarrow: text = "⇐"
        case .doubleLeftrightarrow: text = "⇔"
        case .leftrightarrow: text = "↔"
        case .colon: text = ":"
        case .comma: text = ","
        case .semicolon: text = ";"
        case .bang: text = "!"
        }
        appendSpacedMathToken(text, to: &output)
    }

    private static func appendMathToken(_ token: String, to output: inout String) {
        guard !token.isEmpty else { return }
        if isArrowToken(token) {
            appendSpacedMathToken(token, to: &output)
        } else {
            output.append(token)
        }
    }

    private static func appendSpacedMathToken(_ token: String, to output: inout String) {
        guard !token.isEmpty else { return }
        appendSpace(to: &output)
        output.append(token)
        appendSpace(to: &output)
    }

    private static func appendSpace(to output: inout String) {
        if output.last?.isWhitespace != true {
            output.append(" ")
        }
    }

    private static func isArrowToken(_ token: String) -> Bool {
        ["→", "←", "↔", "⇒", "⇐", "⇔", "⟹", "⟸", "⟺", "↦"].contains(token)
    }

    private static func delimiterText(_ delimiter: Delimiter) -> String {
        switch delimiter {
        case .paren: return "("
        case .closeParen: return ")"
        case .bracket: return "["
        case .closeBracket: return "]"
        case .brace: return "{"
        case .closeBrace: return "}"
        case .pipe: return "|"
        case .doublePipe: return "‖"
        case .angle: return "⟨"
        case .closeAngle: return "⟩"
        case .none: return ""
        }
    }

    private static func bigOperatorText(_ kind: BigOpKind) -> String {
        switch kind {
        case .sum: return "∑"
        case .prod: return "∏"
        case .coprod: return "∐"
        case .int: return "∫"
        case .iint: return "∬"
        case .iiint: return "∭"
        case .oint: return "∮"
        case .bigcup: return "⋃"
        case .bigcap: return "⋂"
        case .bigoplus: return "⨁"
        case .bigotimes: return "⨂"
        case .lim: return "lim"
        case .sup: return "sup"
        case .inf: return "inf"
        case .min: return "min"
        case .max: return "max"
        case .det: return "det"
        case .log: return "log"
        case .ln: return "ln"
        case .sin: return "sin"
        case .cos: return "cos"
        case .tan: return "tan"
        case .exp: return "exp"
        case .xrightarrow: return "⟶"
        case .xleftarrow: return "⟵"
        }
    }

    private static func mathSymbolText(_ symbol: MathSymbol) -> String {
        switch symbol {
        case .alpha: return "α"
        case .beta: return "β"
        case .gamma: return "γ"
        case .delta: return "δ"
        case .epsilon, .varepsilon: return "ε"
        case .zeta: return "ζ"
        case .eta: return "η"
        case .theta, .vartheta: return "θ"
        case .iota: return "ι"
        case .kappa: return "κ"
        case .lambda: return "λ"
        case .mu: return "μ"
        case .nu: return "ν"
        case .xi: return "ξ"
        case .pi: return "π"
        case .rho, .varrho: return "ρ"
        case .sigma, .varsigma: return "σ"
        case .tau: return "τ"
        case .upsilon: return "υ"
        case .phi, .varphi: return "φ"
        case .chi: return "χ"
        case .psi: return "ψ"
        case .omega: return "ω"
        case .capitalGamma: return "Γ"
        case .capitalDelta: return "Δ"
        case .capitalTheta: return "Θ"
        case .capitalLambda: return "Λ"
        case .capitalXi: return "Ξ"
        case .capitalPi: return "Π"
        case .capitalSigma: return "Σ"
        case .capitalUpsilon: return "Υ"
        case .capitalPhi: return "Φ"
        case .capitalPsi: return "Ψ"
        case .capitalOmega: return "Ω"
        case .infty: return "∞"
        case .partial: return "∂"
        case .nabla: return "∇"
        case .forall: return "∀"
        case .exists: return "∃"
        case .neg: return "¬"
        case .ell: return "ℓ"
        case .hbar: return "ℏ"
        case .emptyset: return "∅"
        case .cdots: return "⋯"
        case .ldots: return "…"
        case .vdots: return "⋮"
        case .ddots: return "⋱"
        case .prime: return "′"
        case .top: return "⊤"
        }
    }

    // MARK: - Image URL Resolution

    /// Split paragraph inlines around resolvable markdown images.
    ///
    /// Image-only paragraphs become a single `.image` segment. Mixed paragraphs
    /// become text/image/text segments so syntax like
    /// `Before ![diagram](diagram.jpeg) after` renders the JPEG instead of the
    /// bracketed alt-text fallback.
    private static func resolveParagraphImageSegments(
        inlines: [MarkdownInline],
        palette: ThemePalette,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?,
        serverBaseURL: URL?,
        sourceDirectory: String? = nil,
        worktreeId: String? = nil
    ) -> [Self]? {
        #if DEBUG
        warnIfRelativeImagesNeedWorkspaceContext(inlines: inlines, workspaceID: workspaceID)
        #endif

        var segments: [Self] = []
        var pendingInlines: [MarkdownInline] = []
        var promotedAnyImage = false

        func flushPendingInlines() {
            guard inlineChunkHasVisibleFallback(pendingInlines) else {
                pendingInlines.removeAll(keepingCapacity: true)
                return
            }

            // The line break beside a promoted image or embed ends at that
            // view; kept, it would draw an empty line (with quote chrome in a quote).
            func isBreak(_ inline: MarkdownInline) -> Bool {
                if case .softBreak = inline { true } else if case .hardBreak = inline { true } else { false }
            }
            let trimmed = Array(pendingInlines.drop(while: isBreak).reversed().drop(while: isBreak).reversed())
            let attributed = attributedString(for: .paragraph(trimmed), palette: palette)
            if !attributed.characters.isEmpty {
                segments.append(.text(attributed))
            }
            pendingInlines.removeAll(keepingCapacity: true)
        }

        for inline in inlines {
            if case .math(let math) = inline, math.isDisplay {
                flushPendingInlines()
                segments.append(mathSegment(math, isClosed: true, palette: palette))
                promotedAnyImage = true
            } else if case .videoEmbed(let embed) = inline {
                flushPendingInlines()
                segments.append(.video(embed))
                promotedAnyImage = true
            } else if case .audioEmbed(let embed) = inline {
                flushPendingInlines()
                segments.append(.audio(embed))
                promotedAnyImage = true
            } else if case .usdzEmbed(let embed) = inline {
                flushPendingInlines()
                segments.append(.usdz(embed))
                promotedAnyImage = true
            } else if case .image(let alt, let source, let size) = inline,
               let imageURL = resolveImageURL(
                   source: source,
                   serverID: serverID,
                   workspaceID: workspaceID,
                   sessionID: sessionID,
                   serverBaseURL: serverBaseURL,
                   sourceDirectory: sourceDirectory,
                   worktreeId: worktreeId
               ) {
                flushPendingInlines()
                segments.append(.image(alt: alt, url: imageURL, size: size))
                promotedAnyImage = true
            } else {
                pendingInlines.append(inline)
            }
        }

        flushPendingInlines()
        return promotedAnyImage ? segments : nil
    }

    #if DEBUG
    private static func warnIfRelativeImagesNeedWorkspaceContext(
        inlines: [MarkdownInline],
        workspaceID: String?
    ) {
        guard workspaceID == nil else { return }
        for inline in inlines {
            if case .image(_, let source, _) = inline,
               let source, !source.isEmpty,
               !source.hasPrefix("data:"),
               !source.hasPrefix("http://"),
               !source.hasPrefix("https://"),
               !source.hasPrefix("/"),
               !source.hasPrefix("~") {
                print("[FlatSegment] WARNING: relative image but workspaceID is nil — workspace context not threaded to this rendering path")
                return
            }
        }
    }
    #endif

    private static func inlineChunkHasVisibleFallback(_ inlines: [MarkdownInline]) -> Bool {
        for inline in inlines {
            switch inline {
            case .text(let string), .html(let string), .code(let string):
                if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            case .image, .videoEmbed, .audioEmbed, .usdzEmbed, .math:
                return true
            case .emphasis(let children),
                 .strong(let children),
                 .strikethrough(let children),
                 .link(let children, _):
                if inlineChunkHasVisibleFallback(children) {
                    return true
                }
            case .softBreak, .hardBreak:
                continue
            }
        }
        return false
    }

    /// Resolve a markdown image source to a loadable URL.
    ///
    /// The wiki rewriter classifies origin first and already joins markdown
    /// image destinations against `sourceDirectory`. This resolver only maps
    /// an allowed source onto a fetch URL:
    /// - **Workspace-relative paths**: workspace file API when `workspaceID`
    ///   and `serverBaseURL` are set. `worktreeId` is the source-session
    ///   firstCheckout; nil/main omit the query so cache identity stays
    ///   checkout-aware.
    /// - **Owner-host paths** (`/`, `~/`, local `file://`): `HostFileURL`,
    ///   fetched later with an authenticated host-origin current-file GET.
    /// - **Absolute http(s) URLs**: passed through for tap-to-load / block.
    ///
    /// Skips `data:` URIs and other non-file schemes.
    static func resolveImageURL(
        source: String?,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?,
        serverBaseURL: URL?,
        sourceDirectory: String? = nil,
        worktreeId: String? = nil
    ) -> URL? {
        guard let source, !source.isEmpty else { return nil }
        _ = sourceDirectory

        // Skip data: URIs — they can be huge and aren't practical inline.
        if source.hasPrefix("data:") {
            return nil
        }

        // Absolute URL (http/https) — pass through directly.
        if let url = URL(string: source), let scheme = url.scheme,
           scheme == "http" || scheme == "https" {
            return url
        }

        if let hostPath = MarkdownWikiLinkRewriter.resolvedHostPath(source) {
            return HostFileURL.make(
                filePath: hostPath,
                serverID: serverID,
                serverBaseURL: serverBaseURL,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId
            )
        }

        if let url = URL(string: source), let scheme = url.scheme, scheme != "file" {
            return nil
        }

        // Relative path — resolve against workspace file API.
        // Source-directory join already happened in the rewriter.
        guard let workspaceID, !workspaceID.isEmpty,
              let baseURL = serverBaseURL else {
            return nil
        }

        return WorkspaceFileURL.make(
            baseURL: baseURL,
            workspaceID: workspaceID,
            filePath: source,
            worktreeId: worktreeId
        )
    }

    // MARK: - Inline Markdown Rendering

    enum MarkdownInlineRenderPiece {
        case attributed(NSAttributedString)
        case table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [MarkdownTableAlignment?] = [])
    }

    /// Split markdown into text runs and table blocks for hosts that can
    /// mount `NativeTableBlockView` instead of flattening tables to ASCII.
    static func renderMarkdownPieces(
        _ markdown: String,
        defaultTextColor: UIColor,
        palette: ThemePalette
    ) -> [MarkdownInlineRenderPiece] {
        let blocks = parseCommonMark(markdown)
        guard !blocks.isEmpty else {
            return [
                .attributed(NSAttributedString(string: markdown, attributes: [
                    .font: AppFont.messageBody,
                    .foregroundColor: defaultTextColor,
                ]))
            ]
        }

        var pieces: [MarkdownInlineRenderPiece] = []
        let pending = NSMutableAttributedString()
        let paragraphSep = NSAttributedString(string: "\n\n")

        func flushPendingText() {
            guard pending.length > 0 else { return }
            pieces.append(.attributed(NSAttributedString(attributedString: pending)))
            pending.setAttributedString(NSAttributedString())
        }

        func appendAttributed(_ text: NSAttributedString) {
            guard text.length > 0 else { return }
            if pending.length > 0 {
                pending.append(paragraphSep)
            }
            pending.append(text)
        }

        for block in blocks {
            switch block {
            case .table(let headers, let rows, let alignments):
                flushPendingText()
                pieces.append(.table(headers: headers, rows: rows, alignments: alignments))

            case .codeBlock(_, let code):
                let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                let codeFont = AppFont.monoMedium
                appendAttributed(NSAttributedString(string: trimmed, attributes: [
                    .font: codeFont,
                    .foregroundColor: palette.ui.mdCode,
                    .backgroundColor: palette.ui.bgHighlight,
                ]))

            case .thematicBreak:
                appendAttributed(NSAttributedString(string: "───", attributes: [
                    .foregroundColor: palette.ui.comment,
                    .font: AppFont.messageBody,
                ]))

            default:
                let attributed = attributedString(
                    for: block, palette: palette, defaultTextColor: defaultTextColor
                )
                appendAttributed(NSAttributedString(attributed))
            }
        }
        flushPendingText()
        return pieces
    }

    // MARK: - Block → AttributedString

    private static func attributedString(
        for block: MarkdownBlock,
        palette: ThemePalette,
        defaultTextColor: UIColor? = nil
    ) -> AttributedString {
        switch block {
        case .heading(let level, let inlines):
            let font = AppFont.messageHeading(level: level)
            let color = Self.headingColor(level: level, palette: palette)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacingBefore = Self.headingSpacingAbove(level: level)

            // Fast path: single text inline heading (common for simple headings).
            if inlines.count == 1, case .text(let string) = inlines[0] {
                let heading = NSAttributedString(string: string, attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle,
                ])
                return AttributedString(heading)
            }

            // Inline code keeps its chip, scaled from the body to the heading
            // as body inline code is.
            let codeFont = AppFont.messageInlineCode
            var style = inlineStyle(palette: palette, font: font, color: color)
            style.codeFont = codeFont.withSize(codeFont.pointSize * font.pointSize / AppFont.messageBody.pointSize)
            style.paragraph = paragraphStyle
            return MarkdownInlineRenderer.attributedString(inlines, style: style)

        case .paragraph(let inlines):
            let bodyFont = AppFont.messageBody
            let bodyColor = defaultTextColor ?? palette.ui.fg
            // Fast path: single text inline (most common paragraph shape).
            if inlines.count == 1, case .text(let string) = inlines[0] {
                var container = AttributeContainer()
                container.uiKit.foregroundColor = bodyColor
                container.uiKit.font = bodyFont
                return AttributedString(string, attributes: container)
            }
            return MarkdownInlineRenderer.attributedString(
                inlines,
                style: inlineStyle(palette: palette, font: bodyFont, color: bodyColor)
            )

        case .blockQuote(let children):
            var result = AttributedString("▎ ")
            result.uiKit.foregroundColor = palette.ui.mdQuoteBorder
            let bodyStart = result.endIndex
            for (i, child) in children.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                result.append(attributedString(for: child, palette: palette, defaultTextColor: defaultTextColor))
            }
            if bodyStart < result.endIndex {
                result[bodyStart..<result.endIndex].uiKit.foregroundColor = palette.ui.mdQuote
            }
            return result

        case .unorderedList(let items):
            var result = AttributedString()
            for (i, blocks) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                var bullet = AttributedString("  • ")
                bullet.uiKit.foregroundColor = palette.ui.mdListBullet
                result.append(bullet)
                for (j, block) in blocks.enumerated() {
                    if j > 0 { result.append(AttributedString("\n    ")) }
                    result.append(attributedString(for: block, palette: palette, defaultTextColor: defaultTextColor))
                }
            }
            return result

        case .orderedList(let start, let items):
            var result = AttributedString()
            for (i, blocks) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                var num = AttributedString("  \(start + i). ")
                num.uiKit.foregroundColor = palette.ui.mdListBullet
                num.uiKit.font = AppFont.messageBody
                result.append(num)
                for (j, block) in blocks.enumerated() {
                    if j > 0 { result.append(AttributedString("\n     ")) }
                    result.append(attributedString(for: block, palette: palette, defaultTextColor: defaultTextColor))
                }
            }
            return result

        case .taskList(let items):
            var result = AttributedString()
            for (i, item) in items.enumerated() {
                if i > 0 { result.append(AttributedString("\n")) }
                let layout = MarkdownTaskCheckbox.item(
                    checked: item.checked, palette: palette, line: item.sourceLine, isPartial: item.isPartial
                )
                var paragraph = layout.checkbox
                for (j, block) in item.content.enumerated() {
                    if j > 0 {
                        paragraph.setParagraphStyle(j == 1 ? layout.firstParagraph : layout.laterParagraph)
                        result.append(paragraph)
                        paragraph = AttributedString("\n")
                    }
                    // A checked item reads like any other: the box shows the state.
                    let content = attributedString(for: block, palette: palette, defaultTextColor: defaultTextColor)
                    paragraph.append(content)
                }
                paragraph.setParagraphStyle(item.content.count > 1 ? layout.laterParagraph : layout.firstParagraph)
                result.append(paragraph)
            }
            return result

        case .htmlBlock(let html):
            // A line of badges alone parses as an HTML block; it reads as the
            // paragraph it is.
            if let badges = MarkdownBadge.badges(inHTMLBlock: html) {
                return attributedString(
                    for: .paragraph(badges.map { .html($0.markup) }),
                    palette: palette,
                    defaultTextColor: defaultTextColor
                )
            }
            var result = AttributedString(html.trimmingCharacters(in: .whitespacesAndNewlines))
            result.uiKit.font = AppFont.mono
            result.uiKit.foregroundColor = palette.ui.comment
            return result

        case .math(let math, _):
            // Reached only where a block cannot stand alone (a task item):
            // the formula as written.
            var container = AttributeContainer()
            container.uiKit.foregroundColor = defaultTextColor ?? palette.ui.fg
            container.uiKit.font = AppFont.messageBody
            return AttributedString(math.source, attributes: container)

        case .codeBlock, .table, .thematicBreak:
            return AttributedString()
        }
    }

    // MARK: - UIFont Helpers

    private static func inlineStyle(palette: ThemePalette, font: UIFont, color: UIColor) -> MarkdownInlineRenderer.Style {
        MarkdownInlineRenderer.Style(
            font: font,
            color: color,
            linkColor: palette.ui.mdLink,
            codeFont: AppFont.messageInlineCode,
            codeColor: palette.ui.mdCode,
            codeBackground: palette.ui.bgHighlight,
            mutedColor: palette.ui.comment,
            palette: palette
        )
    }

    private static func headingColor(level: Int, palette: ThemePalette) -> UIColor {
        switch level {
        case 1, 2: return palette.ui.mdHeading
        case 3: return palette.ui.fg
        case 4, 5: return palette.ui.fgDim
        default: return palette.ui.comment
        }
    }

    private static func headingSpacingAbove(level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 16
        case 3: return 12
        case 4: return 8
        default: return 6
        }
    }
}

/// An inline LaTeX image with a VoiceOver label fixed at creation.
///
/// Segments build off the main actor, where `accessibilityLabel`'s setter is
/// unavailable. UIKit reads the label on the main actor through this override.
final class InlineLatexTextAttachment: NSTextAttachment {
    private static let formulaLabelKey = "oppi.formulaLabel"
    private var formulaLabel: String

    override class var supportsSecureCoding: Bool { true }

    init(formulaLabel: String) {
        self.formulaLabel = formulaLabel
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        formulaLabel = coder.decodeObject(of: NSString.self, forKey: Self.formulaLabelKey) as String? ?? ""
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(formulaLabel as NSString, forKey: Self.formulaLabelKey)
    }

    override var accessibilityLabel: String? {
        get { formulaLabel }
        set { formulaLabel = newValue ?? "" }
    }
}

private extension AttributedString {
    /// Through the attribute dictionary: the typed key needs `Sendable`, which `NSParagraphStyle`
    /// is not (it has a mutable subclass); these styles are built here and never mutated after.
    mutating func setParagraphStyle(_ style: NSParagraphStyle) {
        mergeAttributes(AttributeContainer([.paragraphStyle: style]))
    }
}
