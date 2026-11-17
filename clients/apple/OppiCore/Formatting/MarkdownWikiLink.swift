import Foundation

/// Rewrites wiki links and GitHub-style Markdown file links onto the shared
/// `ResourceReference` pipeline, and classifies bang embeds after origin checks.
///
/// Supported wiki syntax: `[[target]]`, `[[target|label]]`, and `![[target]]` /
/// `![alt](path)` embeds of Oppi-backed image, audio, video, or USDZ.
///
/// The raw target stays unresolved. A workspace-relative file candidate travels
/// beside it so tap-time resolution can compare that candidate with exact Oppi
/// session matches. Extension and relative-path rules apply only to the wiki
/// file candidate: extensionless paths gain `.md`, and `./` or `../` resolve
/// against the source markdown file's directory.
///
/// Standard Markdown `[label](path)` destinations reuse the same unresolved
/// resource-reference URLs. Those paths do not gain `.md`. When a source
/// directory is known they join against it; otherwise they stay workspace-root
/// relative. `http`, `https`, `mailto`, `oppi`, `oppi-session-file`, and already
/// rewritten resource-reference destinations stay unchanged.
enum MarkdownWikiLinkRewriter {
    private struct ParsedWikiTarget {
        let path: String
        let lineAnchor: SourceLineAnchor?
        var headingAnchor: ReaderHeadingAnchor?
    }

    /// Whether `rawTarget` names a file a wiki link may open (the pre-pass asks).
    static func isPotentiallySupportedWikiTarget(_ rawTarget: String) -> Bool {
        classifyWikiTarget(rawTarget) != nil
    }

    private struct RewriteContext {
        let serverID: String?
        let workspaceID: String?
        let sessionID: String?
        let sourceDirectory: String?
        var linksHeadings = false
        /// Inside a table cell or a heading, which draw as text and cannot host
        /// a picture or a player: an embed there is a link that opens it.
        var embedsAsLinks = false
    }

    static func rewrite(
        blocks: [MarkdownBlock],
        serverID: String? = nil,
        workspaceID: String?,
        sessionID: String? = nil,
        sourceDirectory: String?,
        linksHeadings: Bool = false
    ) -> [MarkdownBlock] {
        let context = RewriteContext(
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: sourceDirectory,
            linksHeadings: linksHeadings
        )
        return rewrite(blocks: blocks, context: context)
    }

    private struct ClassifiedWikiTarget {
        let parsed: ParsedWikiTarget
        let kind: ResourceReferenceKind
        let path: String
    }

    private static func classifyWikiTarget(
        _ target: String,
        sourceDirectory: String? = nil
    ) -> ClassifiedWikiTarget? {
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRFC3986NetworkPath(trimmedTarget) else { return nil }
        guard let parsed = parseWikiTarget(target) else { return nil }

        var path = slashSeparated(parsed.path)
        let resolveFromSource = path.hasPrefix("./") || path.hasPrefix("../")
        if resolveFromSource,
           let sourceDirectory,
           !sourceDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Join before host/workspace classification so /tmp/index.md
            // containing [[./topic]] stays a host file, not tmp/topic.md.
            path = sourceDirectory + "/" + path
        }

        if let hostPath = resolvedHostPath(path) {
            let resolved = applyMarkdownExtensionIfNeeded(hostPath)
            return ClassifiedWikiTarget(parsed: parsed, kind: .hostFile, path: resolved)
        }

        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        guard !contains("?", in: path), !contains(":", in: path) else { return nil }

        guard var normalized = normalizeWorkspacePath(path) else { return nil }
        if (normalized as NSString).pathExtension.isEmpty {
            normalized += ".md"
        }
        return ClassifiedWikiTarget(parsed: parsed, kind: .workspaceFile, path: normalized)
    }

    /// Accept absolute POSIX paths, bare `~` / `~/...`, and local `file://` URLs.
    /// Reject `~user`, non-local file URLs, query strings, and relative leftovers.
    static func resolvedHostPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !contains("?", in: trimmed),
              !contains("\0", in: trimmed),
              !isRFC3986NetworkPath(trimmed) else {
            return nil
        }

        if trimmed.lowercased().hasPrefix("file://") {
            return expandLocalFileURL(trimmed)
        }
        if trimmed.lowercased().hasPrefix("file:") {
            return nil
        }

        if trimmed == "~" || trimmed.hasPrefix("~/") {
            return trimmed
        }

        if trimmed.hasPrefix("~") {
            return nil
        }

        guard trimmed.hasPrefix("/") else { return nil }
        return normalizeAbsoluteHostPath(trimmed)
    }

    /// Collapse `.` and `..` after source-directory join so `/tmp/./topic`
    /// and `/tmp/notes/../topic` stay host files at `/tmp/topic`.
    private static func normalizeAbsoluteHostPath(_ path: String) -> String? {
        var output: [String] = []
        for partSubsequence in path.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(partSubsequence).trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if !output.isEmpty { output.removeLast() }
                continue
            }
            output.append(part)
        }
        guard !output.isEmpty else { return nil }
        return "/" + output.joined(separator: "/")
    }

    private static func expandLocalFileURL(_ raw: String) -> String? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "file",
              url.isFileURL,
              (url.host ?? "").isEmpty,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }

        let path = url.path
        guard path.hasPrefix("/"), !path.isEmpty else { return nil }
        return path
    }

    private static func applyMarkdownExtensionIfNeeded(_ path: String) -> String {
        if (path as NSString).pathExtension.isEmpty, path != "~" {
            return path + ".md"
        }
        return path
    }

    private static func rewrite(blocks: [MarkdownBlock], context: RewriteContext) -> [MarkdownBlock] {
        blocks.map { rewrite(block: $0, context: context) }
    }

    private static func rewrite(block: MarkdownBlock, context: RewriteContext) -> MarkdownBlock {
        var linking = context
        linking.embedsAsLinks = true
        switch block {
        case .heading(let level, let inlines):
            return .heading(level: level, inlines: rewrite(inlines: inlines, context: linking))
        case .paragraph(let inlines):
            return .paragraph(rewrite(inlines: inlines, context: context))
        case .blockQuote(let children):
            return .blockQuote(rewrite(blocks: children, context: context))
        case .unorderedList(let items):
            return .unorderedList(items.map { rewrite(blocks: $0, context: context) })
        case .orderedList(let start, let items):
            return .orderedList(start: start, items.map { rewrite(blocks: $0, context: context) })
        case .taskList(let items):
            return .taskList(items.map { item in
                MarkdownBlock.TaskItem(
                    checked: item.checked,
                    content: rewrite(blocks: item.content, context: context),
                    sourceLine: item.sourceLine,
                    isPartial: item.isPartial
                )
            })
        case .table(let headers, let rows, let alignments):
            return .table(
                headers: headers.map { rewrite(inlines: $0, context: linking) },
                rows: rows.map { row in row.map { rewrite(inlines: $0, context: linking) } },
                alignments: alignments
            )
        case .codeBlock, .thematicBreak, .htmlBlock, .math:
            return block
        }
    }

    private static func rewrite(inlines: [MarkdownInline], context: RewriteContext) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        result.reserveCapacity(inlines.count)

        for inline in inlines {
            switch inline {
            case .text(let text):
                result.append(contentsOf: rewriteText(text, context: context))
            case .emphasis(let children):
                result.append(.emphasis(rewrite(inlines: children, context: context)))
            case .strong(let children):
                result.append(.strong(rewrite(inlines: children, context: context)))
            case .strikethrough(let children):
                result.append(.strikethrough(rewrite(inlines: children, context: context)))
            case .styled(let style, let children):
                result.append(.styled(style, rewrite(inlines: children, context: context)))
            case .link(let children, let destination):
                result.append(contentsOf: rewriteMarkdownLink(
                    children: rewrite(inlines: children, context: context),
                    destination: destination,
                    context: context
                ))
            case .image(let alt, let source, _):
                result.append(contentsOf: rewriteMarkdownImage(
                    alt: alt,
                    source: source,
                    context: context
                ))
            case .code, .videoEmbed, .audioEmbed, .usdzEmbed, .softBreak, .hardBreak, .html, .math:
                result.append(inline)
            }
        }

        return result
    }

    private static func rewriteText(_ text: String, context: RewriteContext) -> [MarkdownInline] {
        // Every text node of every block comes through here: a byte search, not
        // Foundation's `contains`, which cost more than parsing the document.
        guard UTF8Search.range(of: "[[", in: text) != nil else { return [.text(text)] }

        var result: [MarkdownInline] = []
        var cursor = text.startIndex

        while cursor < text.endIndex,
              let open = text.range(of: "[[", range: cursor ..< text.endIndex) {
            let bangIndex: String.Index? = {
                guard open.lowerBound > cursor else { return nil }
                let candidate = text.index(before: open.lowerBound)
                return text[candidate] == "!" ? candidate : nil
            }()
            let prefixEnd = bangIndex ?? open.lowerBound
            if prefixEnd > cursor {
                result.append(.text(String(text[cursor ..< prefixEnd])))
            }

            let contentStart = open.upperBound
            guard let close = text.range(of: "]]", range: contentStart ..< text.endIndex) else {
                result.append(.text(String(text[prefixEnd ..< text.endIndex])))
                return result
            }

            let rawContent = String(text[contentStart ..< close.lowerBound])
            if bangIndex != nil {
                result.append(contentsOf: rewriteWikiBang(
                    rawContent: rawContent,
                    literal: String(text[open.lowerBound ..< close.upperBound]),
                    context: context
                ))
            } else if let rewritten = inline(forWikiLinkContent: rawContent, context: context) {
                result.append(rewritten)
            } else {
                result.append(.text(String(text[open.lowerBound ..< close.upperBound])))
            }
            cursor = close.upperBound
        }

        if cursor < text.endIndex {
            result.append(.text(String(text[cursor ..< text.endIndex])))
        }

        return result.isEmpty ? [.text(text)] : result
    }

    private static func inline(
        forWikiLinkContent rawContent: String,
        context: RewriteContext
    ) -> MarkdownInline? {
        guard let reference = resourceReference(
            forWikiLinkContent: rawContent,
            context: context
        ) else { return nil }
        guard let url = ResourceReferenceURL.make(reference) else {
            return .text(reference.visibleLabel ?? reference.target)
        }
        return .link(
            children: [.text(reference.visibleLabel ?? reference.target)],
            destination: url.absoluteString
        )
    }

    private enum BangEmbedDialect {
        case wiki
        case markdown
    }

    /// Shared bang-embed decision: dialect parse → origin/scheme → allowed
    /// ResourceReference or remote-image → FileKind category.
    private enum BangEmbedOutcome {
        case image(source: String)
        case video(MarkdownVideoEmbed)
        case audio(MarkdownAudioEmbed)
        case usdz(MarkdownUSDZEmbed)
        case fileLink(MarkdownInline)
        case remoteImage(source: String)
        case failClosed
    }

    private static func rewriteWikiBang(
        rawContent: String,
        literal: String,
        context: RewriteContext
    ) -> [MarkdownInline] {
        let parsed = wikiLinkParts(rawContent)
        // Text after the first pipe that ends in `|300` or `|300x200` sizes
        // the embed; the rest is its label.
        let sized: (label: String, size: MarkdownEmbedSize?) = rawContent.contains("|")
            ? MarkdownEmbedSize.split(label: parsed.label)
            : (parsed.label, nil)
        let label = sized.label.isEmpty ? parsed.target : sized.label
        switch bangEmbedOutcome(
            rawTarget: parsed.target,
            visibleLabel: label,
            dialect: .wiki,
            context: context
        ) {
        case .image(let source):
            return [.image(alt: label, source: source, size: sized.size)]
        case .video(let embed):
            return [.videoEmbed(embed)]
        case .audio(let embed):
            return [.audioEmbed(embed)]
        case .usdz(let embed):
            return [.usdzEmbed(embed)]
        case .fileLink(let inline):
            return [inline]
        case .remoteImage, .failClosed:
            if let rewritten = inline(forWikiLinkContent: rawContent, context: context) {
                return [.text("!"), rewritten]
            }
            return [.text("!"), .text(literal)]
        }
    }

    private static func rewriteMarkdownImage(
        alt: String,
        source: String?,
        context: RewriteContext
    ) -> [MarkdownInline] {
        // Obsidian sizes an image from its alt text: `![250](url)`, `![Chart|250x100](url)`.
        let (alt, size) = MarkdownEmbedSize.split(label: alt)
        guard let source, !source.isEmpty else {
            return [.image(alt: alt, source: source, size: size)]
        }
        let trimmedAlt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleLabel = trimmedAlt.isEmpty ? source : trimmedAlt
        switch bangEmbedOutcome(
            rawTarget: source,
            visibleLabel: visibleLabel,
            dialect: .markdown,
            context: context
        ) {
        case .image(let resolvedSource):
            return [.image(alt: alt, source: resolvedSource, size: size)]
        case .video(let embed):
            return [.videoEmbed(embed)]
        case .audio(let embed):
            return [.audioEmbed(embed)]
        case .usdz(let embed):
            return [.usdzEmbed(embed)]
        case .fileLink(let inline):
            return [inline]
        case .remoteImage(let remoteSource):
            return [.image(alt: alt, source: remoteSource, size: size)]
        case .failClosed:
            return [.image(alt: alt, source: nil, size: size)]
        }
    }

    private static func bangEmbedOutcome(
        rawTarget: String,
        visibleLabel: String,
        dialect: BangEmbedDialect,
        context: RewriteContext
    ) -> BangEmbedOutcome {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failClosed }

        if let scheme = rfc3986Scheme(of: trimmed), scheme != "file" {
            if scheme == "https" || scheme == "http" {
                return remoteImageOrFailClosedAV(trimmed)
            }
            return .failClosed
        }

        // RFC 3986 network-path (`//host/path`) is not a POSIX file.
        if isRFC3986NetworkPath(trimmed) {
            return .failClosed
        }

        let classified: ClassifiedWikiTarget?
        switch dialect {
        case .wiki:
            classified = classifyWikiTarget(trimmed, sourceDirectory: context.sourceDirectory)
        case .markdown:
            classified = classifyMarkdownLinkTarget(trimmed, sourceDirectory: context.sourceDirectory)
        }
        guard let classified else { return .failClosed }

        if classified.parsed.lineAnchor != nil || context.embedsAsLinks {
            return .fileLink(fileLinkInline(
                rawTarget: trimmed,
                classified: classified,
                visibleLabel: visibleLabel,
                context: context
            ))
        }

        // Origin is an allowed workspace or owner-host file. FileKind decides
        // the embed category only after that origin check.
        let fileKind = FileKind.detect(from: classified.path)
        switch fileKind.previewCategory {
        case .image:
            return .image(source: classified.path)
        case .video:
            return .video(MarkdownVideoEmbed(reference: embedReference(
                rawTarget: trimmed,
                classified: classified,
                visibleLabel: visibleLabel,
                context: context
            )))
        case .audio:
            return .audio(MarkdownAudioEmbed(reference: embedReference(
                rawTarget: trimmed,
                classified: classified,
                visibleLabel: visibleLabel,
                context: context
            )))
        case .usdz:
            return .usdz(MarkdownUSDZEmbed(reference: embedReference(
                rawTarget: trimmed,
                classified: classified,
                visibleLabel: visibleLabel,
                context: context
            )))
        default:
            // Markdown `![]()` is image syntax. Extensionless workspace/host
            // targets stay images so byte inspection can still choose GIF/WebP/
            // SVG. Wiki `![[]]` keeps the `.md` suffix and file-link behavior.
            if dialect == .markdown, fileKind == .plain {
                return .image(source: classified.path)
            }
            return .fileLink(fileLinkInline(
                rawTarget: trimmed,
                classified: classified,
                visibleLabel: visibleLabel,
                context: context
            ))
        }
    }

    private static func remoteImageOrFailClosedAV(_ source: String) -> BangEmbedOutcome {
        let typePath = URL(string: source)?.path ?? source
        switch FileKind.detect(from: typePath).previewCategory {
        case .video, .audio, .usdz:
            return .failClosed
        default:
            return .remoteImage(source: source)
        }
    }

    private static func wikiLinkParts(_ rawContent: String) -> (target: String, label: String) {
        let normalizedContent = rawContent.replacingOccurrences(of: #"\|"#, with: "|")
        let pieces = normalizedContent.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = pieces.first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let rawLabel = pieces.count == 2 ? String(pieces[1]) : target
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return (target, label.isEmpty ? target : label)
    }

    private static func fileLinkInline(
        rawTarget: String,
        classified: ClassifiedWikiTarget,
        visibleLabel: String,
        context: RewriteContext
    ) -> MarkdownInline {
        let reference = resourceReference(
            rawTarget: rawTarget,
            classified: classified,
            visibleLabel: visibleLabel,
            context: context,
            includeWorkspaceCandidateWithoutScope: false
        )
        guard let url = ResourceReferenceURL.make(reference) else {
            return .text(visibleLabel)
        }
        return .link(
            children: [.text(visibleLabel)],
            destination: url.absoluteString
        )
    }

    private static func embedReference(
        rawTarget: String,
        classified: ClassifiedWikiTarget,
        visibleLabel: String,
        context: RewriteContext
    ) -> ResourceReference {
        // Classification, not workspace scope, decides embed eligibility so
        // image/PDF export without chat context still gets a static AV card.
        resourceReference(
            rawTarget: rawTarget,
            classified: classified,
            visibleLabel: visibleLabel,
            context: context,
            includeWorkspaceCandidateWithoutScope: true
        )
    }

    private static func resourceReference(
        rawTarget: String,
        classified: ClassifiedWikiTarget,
        visibleLabel: String,
        context: RewriteContext,
        includeWorkspaceCandidateWithoutScope: Bool
    ) -> ResourceReference {
        let workspaceID = context.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasWorkspaceScope = workspaceID?.isEmpty == false
        let fileCandidatePath: String?
        switch classified.kind {
        case .hostFile:
            fileCandidatePath = classified.path
        case .workspaceFile:
            fileCandidatePath = (hasWorkspaceScope || includeWorkspaceCandidateWithoutScope)
                ? classified.path
                : nil
        }
        return ResourceReference(
            target: rawTarget,
            sourceServerID: context.serverID,
            workspaceID: hasWorkspaceScope ? workspaceID : nil,
            sourceSessionID: context.sessionID,
            fileCandidatePath: fileCandidatePath,
            kind: classified.kind,
            lineAnchor: classified.parsed.lineAnchor,
            visibleLabel: visibleLabel
        )
    }

    private static func resourceReference(
        forWikiLinkContent rawContent: String,
        context: RewriteContext
    ) -> ResourceReference? {
        let normalizedContent = rawContent.replacingOccurrences(of: #"\|"#, with: "|")
        let pieces = normalizedContent.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawTarget = pieces.first else { return nil }

        let target = String(rawTarget).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let classified = classifyWikiTarget(target, sourceDirectory: context.sourceDirectory) else {
            return nil
        }

        let rawLabel = pieces.count == 2 ? String(pieces[1]) : target
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = label.isEmpty ? target : label
        let workspaceID = context.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasWorkspaceScope = workspaceID?.isEmpty == false
        let fileCandidatePath: String?
        switch classified.kind {
        case .hostFile:
            fileCandidatePath = classified.path
        case .workspaceFile:
            fileCandidatePath = hasWorkspaceScope ? classified.path : nil
        }
        return ResourceReference(
            target: target,
            sourceServerID: context.serverID,
            workspaceID: hasWorkspaceScope ? workspaceID : nil,
            sourceSessionID: context.sessionID,
            fileCandidatePath: fileCandidatePath,
            kind: classified.kind,
            lineAnchor: classified.parsed.lineAnchor,
            visibleLabel: display
        )
    }

    private static let passThroughMarkdownLinkSchemes: Set<String> = [
        "http",
        "https",
        "mailto",
        "oppi",
        "oppi-session-file",
        ReaderHeadingAnchor.linkScheme,
        ResourceReferenceURL.scheme,
    ]

    /// GitHub-style file links share the wiki-link tap pipeline. Unknown and
    /// unsafe schemes fail closed by dropping the destination instead of
    /// leaving a tappable URL.
    private static func rewriteMarkdownLink(
        children: [MarkdownInline],
        destination: String?,
        context: RewriteContext
    ) -> [MarkdownInline] {
        let passthrough: [MarkdownInline] = [.link(children: children, destination: destination)]
        guard let rawDestination = destination?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDestination.isEmpty else {
            return passthrough
        }

        if let scheme = rfc3986Scheme(of: rawDestination) {
            if passThroughMarkdownLinkSchemes.contains(scheme) || AgentInternalURL.schemes.contains(scheme) {
                return passthrough
            }
            if scheme != "file" {
                return children
            }
        } else if rawDestination.hasPrefix("#") {
            return context.linksHeadings ? ReaderHeadingAnchor.markdownLink(children, rawDestination) ?? passthrough : passthrough
        }

        guard let classified = classifyMarkdownLinkTarget(
            rawDestination,
            sourceDirectory: context.sourceDirectory
        ) else {
            return rfc3986Scheme(of: rawDestination) == nil ? passthrough : children
        }

        let workspaceID = context.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasWorkspaceScope = workspaceID?.isEmpty == false
        let fileCandidatePath: String?
        switch classified.kind {
        case .hostFile:
            fileCandidatePath = classified.path
        case .workspaceFile:
            fileCandidatePath = hasWorkspaceScope ? classified.path : nil
        }

        let label = plainText(from: children).trimmingCharacters(in: .whitespacesAndNewlines)
        let display = label.isEmpty ? rawDestination : label
        guard let url = ResourceReferenceURL.make(ResourceReference(
            target: rawDestination,
            sourceServerID: context.serverID,
            workspaceID: hasWorkspaceScope ? workspaceID : nil,
            sourceSessionID: context.sessionID,
            fileCandidatePath: fileCandidatePath,
            kind: classified.kind,
            lineAnchor: classified.parsed.lineAnchor,
            headingAnchor: classified.parsed.headingAnchor,
            visibleLabel: display
        )) else {
            return children
        }

        return [.link(children: children, destination: url.absoluteString)]
    }

    /// Markdown file links always join against the source directory when it is
    /// known. Wiki links stay workspace-root-relative unless they start with
    /// `./` or `../`. Neither query strings nor `.md` suffixing apply here.
    private static func classifyMarkdownLinkTarget(
        _ destination: String,
        sourceDirectory: String?
    ) -> ClassifiedWikiTarget? {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRFC3986NetworkPath(trimmedDestination) else { return nil }
        guard !contains("?", in: destination),
              let parsed = parseMarkdownLinkTarget(destination) else {
            return nil
        }

        var path = slashSeparated(parsed.path)
        let trimmedSource = sourceDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSourceDirectory = trimmedSource?.isEmpty == false
        let isExplicitHostForm = path.hasPrefix("/")
            || path.hasPrefix("~")
            || path.lowercased().hasPrefix("file:")

        if hasSourceDirectory, !isExplicitHostForm, let trimmedSource {
            path = trimmedSource + "/" + path
        }

        if let hostPath = resolvedHostPath(path) {
            return ClassifiedWikiTarget(parsed: parsed, kind: .hostFile, path: hostPath)
        }

        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        guard !contains("?", in: path), !contains(":", in: path) else { return nil }
        guard let normalized = normalizeWorkspacePath(path) else { return nil }
        return ClassifiedWikiTarget(parsed: parsed, kind: .workspaceFile, path: normalized)
    }

    private static func parseMarkdownLinkTarget(_ rawTarget: String) -> ParsedWikiTarget? {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        guard let hash = target.firstIndex(of: "#") else {
            return ParsedWikiTarget(path: target, lineAnchor: nil)
        }

        let path = String(target[..<hash]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let fragment = String(target[hash...])
        if let lineAnchor = SourceLineAnchor.parse(fragment) {
            return ParsedWikiTarget(path: path, lineAnchor: lineAnchor)
        }
        return ParsedWikiTarget(path: path, lineAnchor: nil, headingAnchor: ReaderHeadingAnchor(fragment: String(fragment.dropFirst())))
    }

    /// RFC 3986 network-path reference. Not a POSIX file and must not become
    /// an owner-host read.
    private static func isRFC3986NetworkPath(_ destination: String) -> Bool {
        destination.hasPrefix("//")
    }

    private static func rfc3986Scheme(of destination: String) -> String? {
        guard let colon = destination.firstIndex(of: ":") else { return nil }
        let scheme = destination[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return nil }
        let isSchemeCharacter = { (character: Character) -> Bool in
            character.isASCII && (
                character.isLetter
                    || character.isNumber
                    || character == "+"
                    || character == "-"
                    || character == "."
            )
        }
        guard scheme.allSatisfy(isSchemeCharacter) else { return nil }
        return scheme.lowercased()
    }

    private static func parseWikiTarget(_ rawTarget: String) -> ParsedWikiTarget? {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        guard let hash = target.firstIndex(of: "#") else {
            return ParsedWikiTarget(path: target, lineAnchor: nil)
        }

        let path = String(target[..<hash]).trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment = String(target[hash...])
        guard !path.isEmpty,
              let lineAnchor = SourceLineAnchor.parse(fragment) else {
            return nil
        }
        return ParsedWikiTarget(path: path, lineAnchor: lineAnchor)
    }

    /// Whether `text` holds the ASCII character `ascii`, by bytes: Foundation's
    /// `contains` costs more than the rest of classifying a target, and every
    /// link in a document is classified.
    private static func contains(_ ascii: Unicode.Scalar, in text: String) -> Bool {
        text.utf8.contains(UInt8(ascii: ascii))
    }

    /// `path` with Windows separators as `/`.
    private static func slashSeparated(_ path: String) -> String {
        contains("\\", in: path) ? path.replacingOccurrences(of: "\\", with: "/") : path
    }

    private static func normalizeWorkspacePath(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        var output: [String] = []
        output.reserveCapacity(parts.count)

        for partSubsequence in parts {
            let part = String(partSubsequence).trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty || part == "." {
                continue
            }
            if part == ".." {
                guard !output.isEmpty else { return nil }
                output.removeLast()
            } else {
                output.append(part)
            }
        }

        guard !output.isEmpty else { return nil }
        return output.joined(separator: "/")
    }
}
