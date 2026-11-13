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
    let headingAnchor: ReaderHeadingAnchor?
    let visibleLabel: String?

    init(
        target: String,
        sourceServerID: String?,
        workspaceID: String?,
        sourceSessionID: String?,
        fileCandidatePath: String?,
        kind: ResourceReferenceKind = .workspaceFile,
        lineAnchor: SourceLineAnchor? = nil,
        headingAnchor: ReaderHeadingAnchor? = nil,
        visibleLabel: String? = nil
    ) {
        self.target = target
        self.sourceServerID = sourceServerID
        self.workspaceID = workspaceID
        self.sourceSessionID = sourceSessionID
        self.fileCandidatePath = fileCandidatePath
        self.kind = kind
        self.lineAnchor = lineAnchor
        self.headingAnchor = headingAnchor
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

/// Authenticated file reference carried by a native Markdown USDZ segment.
///
/// Remote URLs, attachment IDs, `.blend`, and `.glb` fail origin or file-type
/// classification before an embed is constructed.
struct MarkdownUSDZEmbed: Hashable, Sendable {
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

/// Resolves one policy-checked Markdown USDZ reference to a retained local file.
/// RealityKit loading stays in the platform UI layer.
typealias MarkdownUSDZFileProvider = (_ embed: MarkdownUSDZEmbed) async throws -> USDZLocalFileStore.Handle

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
            let workspace = session.workspaceName ?? "Oppi Control"
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
            // A host-origin HEAD may replace a tilde or symlink candidate with
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
            // A file catalog that cannot answer says nothing about a session this device
            // already has: a link naming a session opens that session. Only when the
            // sessions alone name none, or several, does the tap report "right now".
            let sessionsOnly = ResourceReferenceResolver.resolve(reference, matches: sessionMatches)
            if case .resolved = sessionsOnly { return .resolution(sessionsOnly) }
            return .unavailable
        case .authorizationFailed:
            return .authorizationFailed
        }
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
        if let heading = reference.headingAnchor { queryItems.append(URLQueryItem(name: "heading", value: heading.fragment)) }
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

    /// Whether `url` points at a file through the resource-reference pipeline.
    static func isReference(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    static func parse(_ url: URL) -> ResourceReference? {
        guard isReference(url),
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
            headingAnchor: queryValue("heading", in: queryItems).flatMap { ReaderHeadingAnchor(fragment: $0) },
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
