import Foundation

/// A GitHub-style, one-based inclusive source line anchor.
///
/// The parser is intentionally strict: a fragment that is not exactly `#L12`
/// or `#L12-L18` is not an anchor and must remain literal wiki-link text.
struct SourceLineAnchor: Hashable, Sendable {
    let range: ClosedRange<Int>

    init?(startLine: Int, endLine: Int) {
        guard startLine > 0, endLine >= startLine else { return nil }
        range = (startLine...endLine)
    }

    init?(range: ClosedRange<Int>) {
        self.init(startLine: range.lowerBound, endLine: range.upperBound)
    }

    var fragment: String {
        if range.lowerBound == range.upperBound {
            return "#L\(range.lowerBound)"
        }
        return "#L\(range.lowerBound)-L\(range.upperBound)"
    }

    static func parse(_ fragment: String) -> SourceLineAnchor? {
        guard fragment.first == "#" else { return nil }
        let body = fragment.dropFirst()
        let pieces = body.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2,
              let startLine = parseLineNumber(pieces[0]) else {
            return nil
        }

        let endLine = pieces.count == 2
            ? parseLineNumber(pieces[1])
            : startLine
        guard let endLine else { return nil }
        return SourceLineAnchor(startLine: startLine, endLine: endLine)
    }

    func resolution(fileLineCount: Int, firstFileLine: Int = 1) -> SourceLineAnchorResolution {
        let normalizedLineCount = max(0, fileLineCount)
        let firstAvailableLine = max(1, firstFileLine)
        let availableRange: ClosedRange<Int>?
        if normalizedLineCount > 0 {
            availableRange = firstAvailableLine...(firstAvailableLine + normalizedLineCount - 1)
        } else {
            availableRange = nil
        }

        let existingRange: ClosedRange<Int>?
        if let availableRange,
           range.upperBound >= availableRange.lowerBound,
           range.lowerBound <= availableRange.upperBound {
            let lower = max(range.lowerBound, availableRange.lowerBound)
            let upper = min(range.upperBound, availableRange.upperBound)
            existingRange = lower...upper
        } else {
            existingRange = nil
        }

        return SourceLineAnchorResolution(
            requestedRange: range,
            existingRange: existingRange,
            fileLineCount: normalizedLineCount,
            availableRange: availableRange
        )
    }

    func resolution(fileContent: String, firstFileLine: Int = 1) -> SourceLineAnchorResolution {
        resolution(
            fileLineCount: SourceLineMetrics.count(fileContent),
            firstFileLine: firstFileLine
        )
    }

    private static func parseLineNumber(_ value: Substring) -> Int? {
        guard value.count >= 2,
              value.first == "L" else {
            return nil
        }
        let digits = value.dropFirst()
        guard !digits.isEmpty,
              digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let line = Int(digits),
              line > 0 else {
            return nil
        }
        return line
    }
}

struct SourceLineAnchorResolution: Equatable, Sendable {
    let requestedRange: ClosedRange<Int>
    let existingRange: ClosedRange<Int>?
    let fileLineCount: Int
    let availableRange: ClosedRange<Int>?

    var message: String? {
        guard let availableRange else {
            return "Requested lines \(requestedRange.lowerBound)–\(requestedRange.upperBound) are past the end of this empty file. Opened at the end."
        }

        let startsBeforeFile = requestedRange.lowerBound < availableRange.lowerBound
        let continuesPastFile = requestedRange.upperBound > availableRange.upperBound
        guard startsBeforeFile || continuesPastFile else { return nil }

        var details: [String] = []
        if startsBeforeFile {
            details.append("starts before line \(availableRange.lowerBound)")
        }
        if continuesPastFile {
            details.append("continues past line \(availableRange.upperBound)")
        }
        let detailText = details.joined(separator: " and ")
        if let existingRange {
            return "Showing lines \(existingRange.lowerBound)–\(existingRange.upperBound). The requested range \(detailText) (\(fileLineCount) lines)."
        }
        return "Requested lines \(requestedRange.lowerBound)–\(requestedRange.upperBound) \(detailText) (\(fileLineCount) lines). Opened at the end."
    }

    var accessibilityLabel: String {
        if let existingRange {
            if existingRange.lowerBound == existingRange.upperBound {
                return "Focused line \(existingRange.lowerBound)"
            }
            return "Focused lines \(existingRange.lowerBound) through \(existingRange.upperBound)"
        }
        return "No focused lines; opened at the end of the file"
    }
}

enum SourceLineMetrics {
    /// Counts logical source lines, including the empty line after a trailing
    /// newline. An empty file has zero lines; viewers may still render one
    /// empty row for layout purposes.
    static func count(_ source: String) -> Int {
        guard !source.isEmpty else { return 0 }
        return logicalLineContentRanges(in: source as NSString).count
    }

    /// Returns UTF-16 ranges for logical lines without their newline characters.
    /// TextKit uses the same UTF-16 coordinate space, so these ranges can be
    /// passed directly to `NSLayoutManager`.
    static func logicalLineContentRanges(in source: NSString) -> [NSRange] {
        guard source.length > 0 else { return [NSRange(location: 0, length: 0)] }

        var ranges: [NSRange] = []
        var location = 0
        while location < source.length {
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            ranges.append(NSRange(location: location, length: max(0, contentsEnd - location)))
            guard lineEnd > location else { break }
            location = lineEnd
        }

        if isNewline(source.character(at: source.length - 1)) {
            ranges.append(NSRange(location: source.length, length: 0))
        }
        return ranges
    }

    private static func isNewline(_ value: unichar) -> Bool {
        value == 10 || value == 13
    }
}

/// Distinguishes a workspace-relative file candidate from an exact host path.
/// Tap resolution must not infer this from a leading `/`.
enum ResourceReferenceKind: String, Hashable, Sendable {
    case workspaceFile
    case hostFile
}

/// Unresolved `[[target]]` carried through the attributed-link pipeline.
///
/// Resolution stays client-local and happens only when the user taps. The
/// source scope identifies the workspace file candidate without constraining
/// exact session-ID matches to one server. Anchored references are file-only.
struct ResourceReference: Hashable, Sendable {
    let target: String
    let sourceServerID: String?
    let workspaceID: String?
    let sourceSessionID: String?
    let fileCandidatePath: String?
    let kind: ResourceReferenceKind
    let lineAnchor: SourceLineAnchor?
    let visibleLabel: String?

    init(
        target: String,
        sourceServerID: String?,
        workspaceID: String?,
        sourceSessionID: String?,
        fileCandidatePath: String?,
        kind: ResourceReferenceKind = .workspaceFile,
        lineAnchor: SourceLineAnchor? = nil,
        visibleLabel: String? = nil
    ) {
        self.target = target
        self.sourceServerID = sourceServerID
        self.workspaceID = workspaceID
        self.sourceSessionID = sourceSessionID
        self.fileCandidatePath = fileCandidatePath
        self.kind = kind
        self.lineAnchor = lineAnchor
        self.visibleLabel = visibleLabel
    }
}

/// Authenticated file reference carried by a native Markdown video segment.
///
/// This type cannot represent a remote URL or stored attachment ID: those
/// targets fail origin classification before an embed is constructed.
struct MarkdownVideoEmbed: Hashable, Sendable {
    let reference: ResourceReference

    var displayLabel: String {
        let label = reference.visibleLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, !label.isEmpty { return label }
        return reference.target
    }

    var filePath: String {
        reference.fileCandidatePath ?? reference.target
    }
}

/// Authenticated file reference carried by a native Markdown audio segment.
///
/// Remote URLs, HTML audio, and stored attachment IDs fail origin
/// classification before an embed is constructed.
struct MarkdownAudioEmbed: Hashable, Sendable {
    let reference: ResourceReference

    var displayLabel: String {
        let label = reference.visibleLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, !label.isEmpty { return label }
        return reference.target
    }

    var filePath: String {
        reference.fileCandidatePath ?? reference.target
    }
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

struct HostFileResourceReference: Hashable, Sendable {
    let serverID: String
    let path: String
    let serverName: String
}

enum ResourceReferenceMatch: Hashable, Sendable {
    case session(SessionResourceReference)
    case workspaceFile(WorkspaceFileResourceReference)
    case hostFile(HostFileResourceReference)

    var id: String {
        switch self {
        case .session(let session):
            return "session|\(session.serverID)|\(session.sessionID)"
        case .workspaceFile(let file):
            return "file|\(file.serverID)|\(file.workspaceID)|\(file.worktreeID ?? "")|\(file.path)"
        case .hostFile(let file):
            return "hostfile|\(file.serverID)|\(file.path)"
        }
    }

    var choiceLabel: String {
        switch self {
        case .session(let session):
            let workspace = session.workspaceName ?? "Pi Control"
            return "Session: \(session.displayName) — \(workspace) on \(serverLabel(name: session.serverName, id: session.serverID))"
        case .workspaceFile(let file):
            let fileName = (file.path as NSString).lastPathComponent
            return "File: \(fileName) — \(file.workspaceName) on \(serverLabel(name: file.serverName, id: file.serverID))"
        case .hostFile(let file):
            let fileName = (file.path as NSString).lastPathComponent
            return "Host file: \(fileName) — \(file.path) on \(serverLabel(name: file.serverName, id: file.serverID))"
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
            guard reference.lineAnchor == nil else { return false }
            return session.sessionID == reference.target
        case .workspaceFile(let file):
            guard reference.kind == .workspaceFile,
                  let workspaceID = reference.workspaceID,
                  let fileCandidatePath = reference.fileCandidatePath else {
                return false
            }
            return file.workspaceID == workspaceID
                && file.path == fileCandidatePath
                && (reference.sourceServerID == nil || file.serverID == reference.sourceServerID)
        case .hostFile(let file):
            guard reference.kind == .hostFile,
                  reference.fileCandidatePath != nil else {
                return false
            }
            // HEAD /files/raw may replace a tilde or symlink candidate with
            // the canonical realpath. Matching still uses source-server scope.
            return reference.sourceServerID == nil || file.serverID == reference.sourceServerID
        }
    }

    fileprivate var sortKey: String {
        switch self {
        case .session(let session):
            return "0|\(session.serverID)|\(session.sessionID)"
        case .workspaceFile(let file):
            return "1|\(file.serverID)|\(file.workspaceID)|\(file.worktreeID ?? "")|\(file.path)"
        case .hostFile(let file):
            return "2|\(file.serverID)|\(file.path)"
        }
    }
}

enum ResourceReferenceFileLookupPolicy {
    static func kind(for reference: ResourceReference) -> ResourceReferenceKind {
        reference.kind
    }
}

enum ResourceReferenceTapScope {
    /// Workspace-relative taps stay scoped to the rendered chat.
    /// Host-file taps only need the source server, so control chats still work.
    static func matches(
        _ reference: ResourceReference,
        serverID: String?,
        workspaceID: String?
    ) -> Bool {
        if let sourceServerID = reference.sourceServerID,
           let serverID,
           sourceServerID != serverID {
            return false
        }
        if reference.kind == .hostFile {
            return true
        }
        return reference.workspaceID == workspaceID
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
    case authorizationFailed
}

enum ResourceReferenceCandidateCollectionResult: Equatable, Sendable {
    case resolution(ResourceReferenceResolution)
    case unavailable
    case authorizationFailed
}

enum ResourceReferenceSelfLinkPolicy {
    /// A rendered chat carries its own server/session identity. Check that
    /// immutable source scope before any mutable catalog lookup, activation, or
    /// navigation so a current-session wiki link is genuinely inert.
    static func isCurrentSession(_ reference: ResourceReference) -> Bool {
        guard reference.lineAnchor == nil,
              reference.sourceServerID != nil,
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
        case .authorizationFailed:
            return .authorizationFailed
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

/// Deterministic outcome of one exact parent-directory listing for a wiki-link
/// file candidate. `.absent` means the server answered and the file is not in
/// that checkout; `.truncated` and `.unavailable` cannot prove either way.
enum ExactFileListingOutcome: Equatable, Sendable {
    case present
    case absent
    case truncated
    case unavailable
}

enum WorkspaceWikiLinkFileLookupPolicy {
    /// A 404 from the directory-listing endpoint is a deterministic "this
    /// checkout has no such parent directory", not a transient failure. The
    /// client treats it as absence instead of surfacing "right now".
    static func isDeterministicAbsence(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .server(status: 404, message: _), .codedServer(status: 404, message: _, code: _):
            return true
        default:
            return false
        }
    }

    /// Checkout an exact wiki-link file lookup should list first.
    ///
    /// `sourceSessionResolved` is true only when the reference's source session
    /// is present in the in-memory store AND belongs to the target workspace. A
    /// missing or foreign source session means the checkout is unknown, so the
    /// lookup lists the main checkout (`nil`) rather than failing closed: a
    /// gitignored workspace file (for example `.pi/skills/...`) may exist only
    /// on the main checkout.
    static func firstCheckout(
        sourceSessionResolved: Bool,
        sourceSessionWorktreeID: String?
    ) -> String? {
        guard sourceSessionResolved else { return nil }
        return sourceSessionWorktreeID
    }

    /// A git-ignored workspace file (for example `.pi/skills/...`) is not
    /// checked out into a fresh worktree. When a non-main worktree lookup is a
    /// deterministic absence, fall back to the main checkout for the same
    /// workspace-relative path. Truncated listings and transient failures stay
    /// "right now" because they cannot prove the file is absent.
    static func shouldFallBackToMainCheckout(
        worktreeID: String?,
        outcome: ExactFileListingOutcome
    ) -> Bool {
        guard let worktreeID,
              !worktreeID.isEmpty,
              worktreeID != "main" else {
            return false
        }
        return outcome == .absent
    }

    /// Combined checkout decision for one exact wiki-link file lookup.
    ///
    /// A missing or foreign source session lists the main checkout instead of
    /// failing closed as "right now". A worktree listing that is deterministically
    /// absent then retries the same workspace-relative path on main, so a
    /// gitignored file such as `.pi/skills/...` can still open.
    static func resolvedCheckout(
        sourceSessionResolved: Bool,
        sourceSessionWorktreeID: String?,
        firstOutcome: ExactFileListingOutcome
    ) -> String? {
        let first = firstCheckout(
            sourceSessionResolved: sourceSessionResolved,
            sourceSessionWorktreeID: sourceSessionWorktreeID
        )
        if shouldFallBackToMainCheckout(worktreeID: first, outcome: firstOutcome) {
            return nil
        }
        return first
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
        if let workspaceID = nonEmpty(reference.workspaceID) {
            queryItems.append(URLQueryItem(name: "workspaceId", value: workspaceID))
        }
        if let fileCandidatePath = nonEmpty(reference.fileCandidatePath) {
            queryItems.append(URLQueryItem(name: "fileCandidate", value: fileCandidatePath))
        }
        if let sourceServerID = nonEmpty(reference.sourceServerID) {
            queryItems.append(URLQueryItem(name: "sourceServerId", value: sourceServerID))
        }
        if let sourceSessionID = nonEmpty(reference.sourceSessionID) {
            queryItems.append(URLQueryItem(name: "sourceSessionId", value: sourceSessionID))
        }
        if let lineAnchor = reference.lineAnchor {
            queryItems.append(URLQueryItem(name: "lineAnchor", value: lineAnchor.fragment))
        }
        if reference.kind == .hostFile {
            queryItems.append(URLQueryItem(name: "kind", value: ResourceReferenceKind.hostFile.rawValue))
        }
        if let visibleLabel = nonEmpty(reference.visibleLabel) {
            queryItems.append(URLQueryItem(name: "label", value: visibleLabel))
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

        let lineAnchor: SourceLineAnchor?
        if let rawLineAnchor = queryValue("lineAnchor", in: queryItems) {
            guard let parsedLineAnchor = SourceLineAnchor.parse(rawLineAnchor) else { return nil }
            lineAnchor = parsedLineAnchor
        } else {
            lineAnchor = nil
        }

        let kind: ResourceReferenceKind
        if let rawKind = queryValue("kind", in: queryItems) {
            guard let parsedKind = ResourceReferenceKind(rawValue: rawKind) else { return nil }
            kind = parsedKind
        } else {
            kind = .workspaceFile
        }

        return ResourceReference(
            target: target,
            sourceServerID: queryValue("sourceServerId", in: queryItems),
            workspaceID: queryValue("workspaceId", in: queryItems),
            sourceSessionID: queryValue("sourceSessionId", in: queryItems),
            fileCandidatePath: queryValue("fileCandidate", in: queryItems),
            kind: kind,
            lineAnchor: lineAnchor,
            visibleLabel: queryValue("label", in: queryItems)
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

/// Rewrites wiki links and GitHub-style Markdown file links onto the shared
/// `ResourceReference` pipeline, and classifies bang embeds after origin checks.
///
/// Supported wiki syntax:
/// - `[[target]]`
/// - `[[target|label]]`
/// - `![[target]]` / `![alt](path)` embed Oppi-backed image, audio, or video
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

    private struct ParsedWikiTarget {
        let path: String
        let lineAnchor: SourceLineAnchor?
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
        classifyWikiTarget(String(rawTarget)) != nil
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
        guard let classified = classifyWikiTarget(target, sourceDirectory: sourceDirectory),
              classified.kind == .workspaceFile else {
            return nil
        }
        return classified.path
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
        guard let parsed = parseWikiTarget(target) else { return nil }

        var path = parsed.path.replacingOccurrences(of: "\\", with: "/")
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
        guard !path.contains("?"), !path.contains(":") else { return nil }

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
              !trimmed.contains("?"),
              !trimmed.contains("\0") else {
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
            case .link(let children, let destination):
                result.append(contentsOf: rewriteMarkdownLink(
                    children: rewrite(inlines: children, context: context),
                    destination: destination,
                    context: context
                ))
            case .image(let alt, let source):
                result.append(contentsOf: rewriteMarkdownImage(
                    alt: alt,
                    source: source,
                    context: context
                ))
            case .code, .videoEmbed, .audioEmbed, .softBreak, .hardBreak, .html:
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
    /// ResourceReference or remote-image → FileType category.
    private enum BangEmbedOutcome {
        case image(source: String)
        case video(MarkdownVideoEmbed)
        case audio(MarkdownAudioEmbed)
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
        switch bangEmbedOutcome(
            rawTarget: parsed.target,
            visibleLabel: parsed.label,
            dialect: .wiki,
            context: context
        ) {
        case .image(let source):
            return [.image(alt: parsed.label, source: source)]
        case .video(let embed):
            return [.videoEmbed(embed)]
        case .audio(let embed):
            return [.audioEmbed(embed)]
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
        guard let source, !source.isEmpty else {
            return [.image(alt: alt, source: source)]
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
            return [.image(alt: alt, source: resolvedSource)]
        case .video(let embed):
            return [.videoEmbed(embed)]
        case .audio(let embed):
            return [.audioEmbed(embed)]
        case .fileLink(let inline):
            return [inline]
        case .remoteImage(let remoteSource):
            return [.image(alt: alt, source: remoteSource)]
        case .failClosed:
            return [.image(alt: alt, source: nil)]
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

        let classified: ClassifiedWikiTarget?
        switch dialect {
        case .wiki:
            classified = classifyWikiTarget(trimmed, sourceDirectory: context.sourceDirectory)
        case .markdown:
            classified = classifyMarkdownLinkTarget(trimmed, sourceDirectory: context.sourceDirectory)
        }
        guard let classified else { return .failClosed }

        if classified.parsed.lineAnchor != nil {
            return .fileLink(fileLinkInline(
                rawTarget: trimmed,
                classified: classified,
                visibleLabel: visibleLabel,
                context: context
            ))
        }

        // Origin is an allowed workspace or owner-host file. FileType decides
        // the embed category only after that origin check.
        switch FileType.detect(from: classified.path).previewCategory {
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
        default:
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
        switch FileType.detect(from: typePath).previewCategory {
        case .video, .audio:
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
            if passThroughMarkdownLinkSchemes.contains(scheme) {
                return passthrough
            }
            if scheme != "file" {
                return children
            }
        } else if rawDestination.hasPrefix("#") {
            return passthrough
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
        guard !destination.contains("?"),
              let parsed = parseMarkdownLinkTarget(destination) else {
            return nil
        }

        var path = parsed.path.replacingOccurrences(of: "\\", with: "/")
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
        guard !path.contains("?"), !path.contains(":") else { return nil }
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
        // Heading fragments are not anchors. Open the file and ignore the heading.
        return ParsedWikiTarget(path: path, lineAnchor: nil)
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
