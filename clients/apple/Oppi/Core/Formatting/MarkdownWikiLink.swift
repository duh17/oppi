import Foundation

/// Unresolved `[[target]]` carried through the attributed-link pipeline.
///
/// Resolution stays client-local and happens only when the user taps. The
/// source scope identifies the workspace file candidate without constraining
/// exact session-ID matches to one server.
struct ResourceReference: Hashable, Sendable {
    let target: String
    let sourceServerID: String?
    let workspaceID: String?
    let sourceSessionID: String?
    let fileCandidatePath: String?
}

struct SessionResourceReference: Hashable, Sendable {
    let serverID: String
    let sessionID: String
    let workspaceID: String?
    let displayName: String
    let workspaceName: String?
    let serverName: String
}

struct WorkspaceFileResourceReference: Hashable, Sendable {
    let serverID: String
    let workspaceID: String
    let worktreeID: String?
    let path: String
    let workspaceName: String
    let serverName: String
}

enum ResourceReferenceMatch: Hashable, Sendable {
    case session(SessionResourceReference)
    case workspaceFile(WorkspaceFileResourceReference)

    var id: String {
        switch self {
        case .session(let session):
            return "session|\(session.serverID)|\(session.sessionID)"
        case .workspaceFile(let file):
            return "file|\(file.serverID)|\(file.workspaceID)|\(file.worktreeID ?? "")|\(file.path)"
        }
    }

    var choiceLabel: String {
        switch self {
        case .session(let session):
            let workspace = session.workspaceName ?? "Oppi Control"
            return "Session: \(session.displayName) — \(workspace) on \(serverLabel(name: session.serverName, id: session.serverID))"
        case .workspaceFile(let file):
            let fileName = (file.path as NSString).lastPathComponent
            return "File: \(fileName) — \(file.workspaceName) on \(serverLabel(name: file.serverName, id: file.serverID))"
        }
    }

    private func serverLabel(name: String, id: String) -> String {
        let normalizedID = id.lowercased().hasPrefix("sha256:")
            ? String(id.dropFirst("sha256:".count))
            : id
        let discriminator = String(normalizedID.prefix(8))
        return discriminator.isEmpty ? name : "\(name) [\(discriminator)]"
    }

    var accessibilityLabel: String { choiceLabel }

    fileprivate func matches(_ reference: ResourceReference) -> Bool {
        switch self {
        case .session(let session):
            return session.sessionID == reference.target
        case .workspaceFile(let file):
            guard let workspaceID = reference.workspaceID,
                  let fileCandidatePath = reference.fileCandidatePath else {
                return false
            }
            return file.workspaceID == workspaceID
                && file.path == fileCandidatePath
                && (reference.sourceServerID == nil || file.serverID == reference.sourceServerID)
        }
    }

    fileprivate var sortKey: String {
        switch self {
        case .session(let session):
            return "0|\(session.serverID)|\(session.sessionID)"
        case .workspaceFile(let file):
            return "1|\(file.serverID)|\(file.workspaceID)|\(file.worktreeID ?? "")|\(file.path)"
        }
    }
}

enum ResourceReferenceResolution: Equatable, Sendable {
    case unresolved(String)
    case resolved(ResourceReferenceMatch)
    case ambiguous([ResourceReferenceMatch])
}

enum ResourceReferenceResolver {
    static func resolve(
        _ reference: ResourceReference,
        matches: [ResourceReferenceMatch]
    ) -> ResourceReferenceResolution {
        let uniqueMatches = Array(Set(matches.filter { $0.matches(reference) }))
            .sorted { $0.sortKey < $1.sortKey }
        switch uniqueMatches.count {
        case 0:
            return .unresolved(reference.target)
        case 1:
            return .resolved(uniqueMatches[0])
        default:
            return .ambiguous(uniqueMatches)
        }
    }
}

enum ResourceReferenceFileLookup: Equatable, Sendable {
    case notApplicable
    case complete([ResourceReferenceMatch])
    case unavailable
}

enum ResourceReferenceCandidateCollectionResult: Equatable, Sendable {
    case resolution(ResourceReferenceResolution)
    case unavailable
}

enum ResourceReferenceSelfLinkPolicy {
    /// A rendered chat carries its own server/session identity. Check that
    /// immutable source scope before any mutable catalog lookup, activation, or
    /// navigation so a current-session wiki link is genuinely inert.
    static func isCurrentSession(_ reference: ResourceReference) -> Bool {
        guard reference.sourceServerID != nil,
              let sourceSessionID = reference.sourceSessionID else {
            return false
        }
        return reference.target == sourceSessionID
    }
}

enum ResourceReferenceCandidateCollector {
    static func resolve(
        _ reference: ResourceReference,
        sessionMatches: [ResourceReferenceMatch],
        fileLookup: ResourceReferenceFileLookup
    ) -> ResourceReferenceCandidateCollectionResult {
        switch fileLookup {
        case .notApplicable:
            return .resolution(ResourceReferenceResolver.resolve(reference, matches: sessionMatches))
        case .complete(let fileMatches):
            return .resolution(ResourceReferenceResolver.resolve(
                reference,
                matches: sessionMatches + fileMatches
            ))
        case .unavailable:
            return .unavailable
        }
    }
}

/// Cancels superseded tap work and provides a generation token for guarding
/// UI commits after asynchronous session/file lookup.
@MainActor
final class ResourceReferenceRequestCoordinator {
    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    func perform(_ operation: @escaping @MainActor (Token) async -> Void) {
        cancel()
        generation &+= 1
        let token = Token(generation: generation)
        task = Task { @MainActor [weak self] in
            await operation(token)
            guard let self, isCurrent(token) else { return }
            task = nil
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    func isCurrent(_ token: Token) -> Bool {
        token.generation == generation && !Task.isCancelled
    }
}

enum ResourceFileCandidatePolicy {
    /// Nil means the parent-directory listing was truncated before it could
    /// prove that the candidate is absent.
    static func directoryResult(
        fileName: String,
        entries: [FileEntry],
        truncated: Bool
    ) -> Bool? {
        if entries.contains(where: { $0.name == fileName && $0.isFile }) {
            return true
        }
        return truncated ? nil : false
    }
}

/// Client-local URL for unresolved resource references.
/// The URL is never sent to the server.
enum ResourceReferenceURL {
    static let scheme = "oppi-resource-reference"

    static func make(_ reference: ResourceReference) -> URL? {
        let target = reference.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        var queryItems = [URLQueryItem(name: "target", value: target)]
        if let workspaceID = nonEmpty(reference.workspaceID),
           let fileCandidatePath = nonEmpty(reference.fileCandidatePath) {
            queryItems.append(URLQueryItem(name: "workspaceId", value: workspaceID))
            queryItems.append(URLQueryItem(name: "fileCandidate", value: fileCandidatePath))
        }
        if let sourceServerID = nonEmpty(reference.sourceServerID) {
            queryItems.append(URLQueryItem(name: "sourceServerId", value: sourceServerID))
        }
        if let sourceSessionID = nonEmpty(reference.sourceSessionID) {
            queryItems.append(URLQueryItem(name: "sourceSessionId", value: sourceSessionID))
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "resolve"
        components.queryItems = queryItems
        return components.url
    }

    static func parse(_ url: URL) -> ResourceReference? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == "resolve",
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let target = queryValue("target", in: queryItems) else {
            return nil
        }

        return ResourceReference(
            target: target,
            sourceServerID: queryValue("sourceServerId", in: queryItems),
            workspaceID: queryValue("workspaceId", in: queryItems),
            sourceSessionID: queryValue("sourceSessionId", in: queryItems),
            fileCandidatePath: queryValue("fileCandidate", in: queryItems)
        )
    }

    private static func queryValue(_ name: String, in queryItems: [URLQueryItem]) -> String? {
        nonEmpty(queryItems.first(where: { $0.name == name })?.value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Rewrites the supported wiki-link subset into normal markdown link inlines.
///
/// Supported syntax:
/// - `[[target]]`
/// - `[[target|label]]`
///
/// The raw target stays unresolved. A workspace-relative file candidate travels
/// beside it so tap-time resolution can compare that candidate with exact Oppi
/// session matches. Extension and relative-path rules apply only to the file
/// candidate: extensionless paths gain `.md`, and `./` or `../` resolve against
/// the source markdown file's directory.
enum MarkdownWikiLinkRewriter {
    struct ParserInput {
        let source: String
        let restoration: Restoration
    }

    struct Restoration {
        fileprivate let labelSeparatorToken: String?

        func restore(_ literal: String) -> String {
            guard let labelSeparatorToken else { return literal }
            return literal.replacingOccurrences(of: labelSeparatorToken, with: "|")
        }
    }

    private static let parserBoundaryTokens = [
        "q0q", "q1q", "q2q", "q3q", "q4q", "q5q", "q6q", "q7q",
    ]
    private static let maximumTokenSelectionAttempts = 8
    private static let parserBoundaryTokenByteCount = 3

    private struct ParserBoundaryCandidate {
        let end: String.Index
        let separator: String.Index?
        let canProtect: Bool
    }

    /// Selects at most eight source-absent, three-byte alphanumeric tokens.
    /// Returning nil is the fail-closed result when the bounded set is exhausted.
    static func selectParserBoundaryToken(
        absentFrom source: String,
        candidates: [String]
    ) -> String? {
        for candidate in candidates.prefix(maximumTokenSelectionAttempts) {
            guard candidate.utf8.count == parserBoundaryTokenByteCount,
                  candidate.utf8.allSatisfy(isASCIILetterOrDigit) else {
                continue
            }
            if !source.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Protect wiki-link separators before cmark-gfm decides table cell
    /// boundaries. This deliberately knows nothing about CommonMark containers:
    /// transformed bytes are restored from every literal field during AST
    /// conversion, including code and HTML where wiki syntax stays literal.
    ///
    /// Candidate recognition is atomic. Nested opens, escaped closes, multiple
    /// unescaped separators, empty labels/targets, unsupported targets, and
    /// unmatched candidates are copied without transforming any bytes. A valid
    /// minimum `[[a|b]]` grows from seven to nine bytes, so total parser input
    /// amplification is at most 9/7. Token selection is capped at eight checks;
    /// exhaustion returns the original source with no restoration context.
    static func parserInput(_ source: String) -> ParserInput {
        guard source.contains("[["), source.contains("|"),
              let token = selectParserBoundaryToken(
                absentFrom: source,
                candidates: parserBoundaryTokens
              ) else {
            return unchangedParserInput(source)
        }

        var result = ""
        result.reserveCapacity(source.utf8.count)
        var cursor = source.startIndex
        var replacedSeparator = false

        while cursor < source.endIndex,
              let open = source.range(of: "[[", range: cursor ..< source.endIndex) {
            guard let candidate = parserBoundaryCandidate(in: source, opening: open) else {
                result.append(contentsOf: source[cursor ..< source.endIndex])
                cursor = source.endIndex
                break
            }

            if candidate.canProtect, let separator = candidate.separator {
                result.append(contentsOf: source[cursor ..< separator])
                result += token
                let afterSeparator = source.index(after: separator)
                result.append(contentsOf: source[afterSeparator ..< candidate.end])
                replacedSeparator = true
            } else {
                result.append(contentsOf: source[cursor ..< candidate.end])
            }
            cursor = candidate.end
        }

        if cursor < source.endIndex {
            result.append(contentsOf: source[cursor ..< source.endIndex])
        }

        guard replacedSeparator else { return unchangedParserInput(source) }
        return ParserInput(source: result, restoration: Restoration(labelSeparatorToken: token))
    }

    private static func parserBoundaryCandidate(
        in source: String,
        opening: Range<String.Index>
    ) -> ParserBoundaryCandidate? {
        var cursor = opening.upperBound
        var precedingBackslashes = 0
        var separator: String.Index?
        var canProtect = true

        while cursor < source.endIndex {
            let character = source[cursor]
            let next = source.index(after: cursor)
            let escaped = precedingBackslashes % 2 == 1

            if character == "[", next < source.endIndex, source[next] == "[" {
                canProtect = false
            } else if character == "]", escaped {
                canProtect = false
            } else if character == "]", next < source.endIndex, source[next] == "]" {
                let end = source.index(after: next)
                guard let separator else {
                    return ParserBoundaryCandidate(end: end, separator: nil, canProtect: false)
                }
                let target = source[opening.upperBound ..< separator]
                let labelStart = source.index(after: separator)
                let label = source[labelStart ..< cursor]
                return ParserBoundaryCandidate(
                    end: end,
                    separator: separator,
                    canProtect: canProtect
                        && isPotentiallySupportedWikiTarget(target)
                        && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            } else if character == "|", !escaped {
                if separator == nil {
                    separator = cursor
                } else {
                    canProtect = false
                }
            }

            precedingBackslashes = character == "\\" ? precedingBackslashes + 1 : 0
            cursor = next
        }

        return nil
    }

    private static func isPotentiallySupportedWikiTarget(_ rawTarget: Substring) -> Bool {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }

        let path = target.replacingOccurrences(of: "\\", with: "/")
        return !path.hasPrefix("/")
            && !path.hasPrefix("~")
            && !path.contains("#")
            && !path.contains("?")
            && !path.contains(":")
    }

    private static func unchangedParserInput(_ source: String) -> ParserInput {
        ParserInput(source: source, restoration: Restoration(labelSeparatorToken: nil))
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }

    private struct RewriteContext {
        let serverID: String?
        let workspaceID: String?
        let sessionID: String?
        let sourceDirectory: String?
    }

    static func rewrite(
        blocks: [MarkdownBlock],
        serverID: String? = nil,
        workspaceID: String?,
        sessionID: String? = nil,
        sourceDirectory: String?
    ) -> [MarkdownBlock] {
        let context = RewriteContext(
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: sourceDirectory
        )
        return rewrite(blocks: blocks, context: context)
    }

    static func resolvedWorkspacePath(target: String, sourceDirectory: String?) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var path = trimmed.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        guard !path.contains("#"), !path.contains("?"), !path.contains(":") else { return nil }

        let resolveFromSource = path.hasPrefix("./") || path.hasPrefix("../")
        if resolveFromSource,
           let sourceDirectory,
           !sourceDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path = sourceDirectory + "/" + path
        }

        guard var normalized = normalizeWorkspacePath(path) else { return nil }
        if (normalized as NSString).pathExtension.isEmpty {
            normalized += ".md"
        }
        return normalized
    }

    private static func rewrite(blocks: [MarkdownBlock], context: RewriteContext) -> [MarkdownBlock] {
        blocks.map { rewrite(block: $0, context: context) }
    }

    private static func rewrite(block: MarkdownBlock, context: RewriteContext) -> MarkdownBlock {
        switch block {
        case .heading(let level, let inlines):
            return .heading(level: level, inlines: rewrite(inlines: inlines, context: context))
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
                    content: rewrite(blocks: item.content, context: context)
                )
            })
        case .table(let headers, let rows):
            return .table(
                headers: headers.map { rewrite(inlines: $0, context: context) },
                rows: rows.map { row in row.map { rewrite(inlines: $0, context: context) } }
            )
        case .codeBlock, .thematicBreak, .htmlBlock:
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
            case .link, .code, .image, .softBreak, .hardBreak, .html:
                result.append(inline)
            }
        }

        return result
    }

    private static func rewriteText(_ text: String, context: RewriteContext) -> [MarkdownInline] {
        guard text.contains("[[") else { return [.text(text)] }

        var result: [MarkdownInline] = []
        var cursor = text.startIndex

        while cursor < text.endIndex,
              let open = text.range(of: "[[", range: cursor ..< text.endIndex) {
            if open.lowerBound > cursor {
                result.append(.text(String(text[cursor ..< open.lowerBound])))
            }

            let contentStart = open.upperBound
            guard let close = text.range(of: "]]", range: contentStart ..< text.endIndex) else {
                result.append(.text(String(text[open.lowerBound ..< text.endIndex])))
                return result
            }

            let rawContent = String(text[contentStart ..< close.lowerBound])
            if let rewritten = inline(forWikiLinkContent: rawContent, context: context) {
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
        let normalizedContent = rawContent.replacingOccurrences(of: #"\|"#, with: "|")
        let pieces = normalizedContent.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawTarget = pieces.first else { return nil }

        let target = String(rawTarget).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let filePath = resolvedWorkspacePath(target: target, sourceDirectory: context.sourceDirectory) else {
            return nil
        }

        let rawLabel = pieces.count == 2 ? String(pieces[1]) : target
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = label.isEmpty ? target : label

        let workspaceID = context.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasWorkspaceScope = workspaceID?.isEmpty == false
        guard let url = ResourceReferenceURL.make(ResourceReference(
            target: target,
            sourceServerID: context.serverID,
            workspaceID: hasWorkspaceScope ? workspaceID : nil,
            sourceSessionID: context.sessionID,
            fileCandidatePath: hasWorkspaceScope ? filePath : nil
        )) else {
            return .text(display)
        }

        return .link(children: [.text(display)], destination: url.absoluteString)
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
