import Foundation

/// mpv-style sidecar matching and parsers for workspace/session lyrics and captions.
///
/// Same directory, same stem, optional language suffix:
/// `stem(.lang)?.(lrc|vtt|srt|ass|ssa)`. Times are never invented.
enum TimedText {
    enum MediaKind: Equatable, Sendable {
        case audio
        case video
    }

    enum Format: String, Equatable, Sendable, CaseIterable {
        case lrc
        case vtt
        case srt
        case ass
        case ssa

        static let audioPriority: [Format] = [.lrc, .vtt, .srt, .ass, .ssa]
        static let videoPriority: [Format] = [.vtt, .srt, .ass, .ssa]

        static func priority(for kind: MediaKind) -> [Format] {
            switch kind {
            case .audio: return audioPriority
            case .video: return videoPriority
            }
        }
    }

    struct Cue: Equatable, Sendable {
        var text: String
        var startTime: TimeInterval?
        var endTime: TimeInterval?
    }

    struct Candidate: Equatable, Sendable {
        var fileName: String
        var path: String
        var format: Format
        /// `nil` means a bare stem match with no language suffix.
        var language: String?
    }

    struct Track: Equatable, Sendable {
        var candidate: Candidate
        var cues: [Cue]

        var languageLabel: String {
            candidate.language ?? "Default"
        }
    }

    struct LoadResult: Equatable, Sendable {
        var tracks: [Track]
        var selectedIndex: Int

        static let empty = LoadResult(tracks: [], selectedIndex: 0)

        var selected: Track? {
            tracks.indices.contains(selectedIndex) ? tracks[selectedIndex] : nil
        }

        var showsLanguageControl: Bool { tracks.count > 1 }
    }

    enum SourceKind: Equatable, Sendable {
        case host
        case session
        case workspace
    }

    struct Access: Sendable {
        var sourceKind: SourceKind
        var listDirectory: (@Sendable (String) async throws -> [String])?
        var fetchFile: @Sendable (String) async throws -> Data
        var isMissing: @Sendable (Error) -> Bool

        init(
            sourceKind: SourceKind,
            listDirectory: (@Sendable (String) async throws -> [String])? = nil,
            fetchFile: @escaping @Sendable (String) async throws -> Data,
            isMissing: @escaping @Sendable (Error) -> Bool = { error in
                if case APIError.server(let status, _) = error, status == 404 {
                    return true
                }
                return false
            }
        ) {
            self.sourceKind = sourceKind
            self.listDirectory = listDirectory
            self.fetchFile = fetchFile
            self.isMissing = isMissing
        }
    }

    static func parentDirectoryPath(forMediaPath path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "." || parent == "/" {
            return ""
        }
        return parent.hasSuffix("/") ? parent : parent + "/"
    }

    static func join(_ directory: String, fileName: String) -> String {
        if directory.isEmpty { return fileName }
        if directory.hasSuffix("/") { return directory + fileName }
        return directory + "/" + fileName
    }

    static func stem(ofMediaPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func candidates(
        mediaPath: String,
        directoryNames: [String],
        kind: MediaKind
    ) -> [Candidate] {
        let stem = stem(ofMediaPath: mediaPath)
        guard !stem.isEmpty else { return [] }
        let parent = parentDirectoryPath(forMediaPath: mediaPath)
        let extensions = Format.priority(for: kind).map(\.rawValue).joined(separator: "|")
        let pattern = "^\(NSRegularExpression.escapedPattern(for: stem))(?:\\.([A-Za-z][A-Za-z0-9-]*))?\\.(\(extensions))$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        var matches: [Candidate] = []
        for name in directoryNames {
            let range = NSRange(name.startIndex..., in: name)
            guard let match = regex.firstMatch(in: name, range: range) else { continue }
            let language: String?
            if match.numberOfRanges > 1,
               match.range(at: 1).location != NSNotFound,
               let langRange = Range(match.range(at: 1), in: name) {
                language = String(name[langRange])
            } else {
                language = nil
            }
            guard match.numberOfRanges > 2,
                  let extRange = Range(match.range(at: 2), in: name),
                  let format = Format(rawValue: String(name[extRange]).lowercased()) else {
                continue
            }
            matches.append(
                Candidate(
                    fileName: name,
                    path: join(parent, fileName: name),
                    format: format,
                    language: language
                )
            )
        }
        return matches
    }

    static func pick(
        _ candidates: [Candidate],
        locale: Locale,
        kind: MediaKind? = nil
    ) -> Candidate? {
        let resolvedKind = kind ?? inferredKind(from: candidates)
        let ranked = ranked(candidates, kind: resolvedKind)
        guard !ranked.isEmpty else { return nil }
        if let bare = ranked.first(where: { $0.language == nil }) {
            return bare
        }
        if let localized = ranked.first(where: { candidate in
            guard let language = candidate.language else { return false }
            return matches(language: language, locale: locale)
        }) {
            return localized
        }
        return ranked.first
    }

    static func sessionProbePaths(mediaPath: String, kind: MediaKind) -> [String] {
        let parent = parentDirectoryPath(forMediaPath: mediaPath)
        let stem = stem(ofMediaPath: mediaPath)
        guard !stem.isEmpty else { return [] }
        return Format.priority(for: kind).map { format in
            join(parent, fileName: "\(stem).\(format.rawValue)")
        }
    }

    static func parse(_ text: String, format: Format) -> [Cue] {
        switch format {
        case .lrc:
            return parseLRC(text)
        case .srt:
            return parseSRT(text)
        case .vtt:
            return parseVTT(text)
        case .ass, .ssa:
            return parseASS(text)
        }
    }

    static func lyricsLines(from cues: [Cue]) -> [AudioLyrics.Line] {
        cues.map { AudioLyrics.Line(text: $0.text, startTime: $0.startTime) }
    }

    static func currentCue(in cues: [Cue], at time: TimeInterval) -> Cue? {
        guard time.isFinite else { return nil }
        var best: Cue?
        var bestStart: TimeInterval?
        for cue in cues {
            guard let start = cue.startTime, start.isFinite, start <= time else { continue }
            if let end = cue.endTime {
                guard end.isFinite, time < end else { continue }
            }
            if let bestStart, start < bestStart {
                continue
            }
            best = cue
            bestStart = start
        }
        return best
    }

    static func load(
        mediaPath: String,
        kind: MediaKind,
        locale: Locale,
        access: Access
    ) async -> LoadResult {
        switch access.sourceKind {
        case .host:
            return .empty
        case .session:
            return await loadSession(mediaPath: mediaPath, kind: kind, access: access)
        case .workspace:
            return await loadWorkspace(mediaPath: mediaPath, kind: kind, locale: locale, access: access)
        }
    }

    /// Sidecar loading follows file origin, not the media-byte session collapse.
    static func sidecarSourceKind(
        fileKind: ResourceReferenceKind,
        sessionID _: String?,
        workspaceRuntime: WorkspaceRuntime?
    ) -> SourceKind {
        switch fileKind {
        case .workspaceFile:
            return .workspace
        case .hostFile:
            return workspaceRuntime == .sandbox ? .session : .host
        }
    }

    static func access(for route: MarkdownVideoMediaSourceRoute, api: APIClient) -> Access {
        switch route {
        case .host:
            return Access(
                sourceKind: .host,
                fetchFile: { _ in throw CocoaError(.fileNoSuchFile) }
            )
        case .session(let workspaceID, let sessionID, _):
            return Access(
                sourceKind: .session,
                fetchFile: { path in
                    try await api.getSessionFileData(
                        workspaceId: workspaceID,
                        sessionId: sessionID,
                        path: path
                    )
                }
            )
        case .workspace(let workspaceID, _, let worktreeID):
            return Access(
                sourceKind: .workspace,
                listDirectory: { path in
                    try await api.listWorkspaceDirectory(
                        workspaceId: workspaceID,
                        path: path,
                        worktreeId: worktreeID
                    ).entries.filter { !$0.isDirectory }.map(\.name)
                },
                fetchFile: { path in
                    try await api.browseWorkspaceFile(
                        workspaceId: workspaceID,
                        path: path,
                        worktreeId: worktreeID
                    )
                }
            )
        }
    }

    static func load(
        mediaPath: String,
        kind: MediaKind,
        fileKind: ResourceReferenceKind,
        workspaceID: String?,
        sessionID: String?,
        worktreeID: String?,
        workspaceRuntime: WorkspaceRuntime?,
        locale: Locale = .current,
        api: APIClient
    ) async -> LoadResult {
        let sourceKind = sidecarSourceKind(
            fileKind: fileKind,
            sessionID: sessionID,
            workspaceRuntime: workspaceRuntime
        )
        let workspace = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sourceKind {
        case .host:
            return .empty
        case .workspace:
            guard let workspace, !workspace.isEmpty else { return .empty }
            return await load(
                mediaPath: mediaPath,
                kind: kind,
                locale: locale,
                access: access(
                    for: .workspace(workspaceID: workspace, path: mediaPath, worktreeID: worktreeID),
                    api: api
                )
            )
        case .session:
            guard let workspace, !workspace.isEmpty,
                  let session, !session.isEmpty else { return .empty }
            return await load(
                mediaPath: mediaPath,
                kind: kind,
                locale: locale,
                access: access(
                    for: .session(workspaceID: workspace, sessionID: session, path: mediaPath),
                    api: api
                )
            )
        }
    }

    // MARK: - Matching helpers

    private static func inferredKind(from candidates: [Candidate]) -> MediaKind {
        candidates.contains(where: { $0.format == .lrc }) ? .audio : .video
    }

    static func ranked(_ candidates: [Candidate], kind: MediaKind) -> [Candidate] {
        let order = Dictionary(
            uniqueKeysWithValues: Format.priority(for: kind).enumerated().map { ($0.element, $0.offset) }
        )
        return candidates.sorted { left, right in
            let leftOrder = order[left.format] ?? 99
            let rightOrder = order[right.format] ?? 99
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if (left.language == nil) != (right.language == nil) {
                return left.language == nil
            }
            return left.fileName.localizedStandardCompare(right.fileName) == .orderedAscending
        }
    }

    private static func matches(language: String, locale: Locale) -> Bool {
        let candidate = languageTagParts(language)
        let localeFromIdentifier = languageTagParts(locale.identifier)
        let localePrimary = locale.language.languageCode?.identifier.lowercased()
            ?? localeFromIdentifier.primary
        guard !localePrimary.isEmpty, candidate.primary == localePrimary else { return false }
        let localeScript = locale.language.script?.identifier.lowercased()
            ?? localeFromIdentifier.script
        if let candidateScript = candidate.script, let localeScript {
            return candidateScript == localeScript
        }
        return true
    }

    private static func languageTagParts(_ tag: String) -> (primary: String, script: String?) {
        let parts = tag.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { String($0) }
        guard let primary = parts.first?.lowercased(), !primary.isEmpty else {
            return ("", nil)
        }
        if parts.count >= 2, parts[1].count == 4, parts[1].allSatisfy(\.isLetter) {
            return (primary, parts[1].lowercased())
        }
        return (primary, nil)
    }

    // MARK: - Load

    private static func loadSession(
        mediaPath: String,
        kind: MediaKind,
        access: Access
    ) async -> LoadResult {
        for path in sessionProbePaths(mediaPath: mediaPath, kind: kind) {
            do {
                let data = try await access.fetchFile(path)
                guard !data.isEmpty,
                      let text = decodeText(data),
                      !text.isEmpty else { continue }
                let fileName = (path as NSString).lastPathComponent
                let ext = (fileName as NSString).pathExtension.lowercased()
                guard let format = Format(rawValue: ext) else { continue }
                let cues = parse(text, format: format)
                guard !cues.isEmpty else { continue }
                let candidate = Candidate(
                    fileName: fileName,
                    path: path,
                    format: format,
                    language: nil
                )
                return LoadResult(
                    tracks: [Track(candidate: candidate, cues: cues)],
                    selectedIndex: 0
                )
            } catch {
                if access.isMissing(error) { continue }
                continue
            }
        }
        return .empty
    }

    private static func loadWorkspace(
        mediaPath: String,
        kind: MediaKind,
        locale: Locale,
        access: Access
    ) async -> LoadResult {
        guard let listDirectory = access.listDirectory else { return .empty }
        let names: [String]
        do {
            names = try await listDirectory(parentDirectoryPath(forMediaPath: mediaPath))
        } catch {
            return .empty
        }
        let matches = ranked(
            candidates(mediaPath: mediaPath, directoryNames: names, kind: kind),
            kind: kind
        )
        guard !matches.isEmpty else { return .empty }

        var tracks: [Track] = []
        for candidate in matches {
            do {
                let data = try await access.fetchFile(candidate.path)
                guard !data.isEmpty,
                      let text = decodeText(data),
                      !text.isEmpty else { continue }
                let cues = parse(text, format: candidate.format)
                guard !cues.isEmpty else { continue }
                tracks.append(Track(candidate: candidate, cues: cues))
            } catch {
                continue
            }
        }
        guard !tracks.isEmpty else { return .empty }
        let picked = pick(tracks.map(\.candidate), locale: locale, kind: kind)
        let selectedIndex = tracks.firstIndex(where: { $0.candidate == picked }) ?? 0
        return LoadResult(tracks: tracks, selectedIndex: selectedIndex)
    }

    private static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf16)
    }

    // MARK: - LRC

    private static func parseLRC(_ text: String) -> [Cue] {
        let timestamp = /\[(?:(\d{1,2}):)?(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]/
        var cues: [Cue] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var times: [TimeInterval] = []
            var cursor = line.startIndex
            while cursor < line.endIndex,
                  let match = line[cursor...].firstMatch(of: timestamp),
                  match.range.lowerBound == cursor {
                if let time = clock(
                    hours: match.1.map(String.init),
                    minutes: String(match.2),
                    seconds: String(match.3),
                    fraction: match.4.map(String.init)
                ) {
                    times.append(time)
                }
                cursor = match.range.upperBound
            }
            guard !times.isEmpty else { continue }
            let payload = String(line[cursor...]).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { continue }
            for time in times {
                cues.append(Cue(text: payload, startTime: time, endTime: nil))
            }
        }
        return cues
    }

    // MARK: - SRT / VTT

    private static func parseSRT(_ text: String) -> [Cue] {
        parseCuedBlocks(text, isVTT: false)
    }

    private static func parseVTT(_ text: String) -> [Cue] {
        parseCuedBlocks(text, isVTT: true)
    }

    private static func parseCuedBlocks(_ text: String, isVTT: Bool) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        var cues: [Cue] = []

        if isVTT {
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            if index < lines.count, lines[index].uppercased().hasPrefix("WEBVTT") {
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
            }
        }

        while index < lines.count {
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            guard index < lines.count else { break }

            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if isVTT, isVTTIgnoredBlock(trimmed) {
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
                continue
            }

            var timingLine = trimmed
            if !timingLine.contains("-->"),
               index + 1 < lines.count,
               lines[index + 1].contains("-->") {
                index += 1
                timingLine = lines[index].trimmingCharacters(in: .whitespaces)
            }
            guard timingLine.contains("-->"),
                  let (start, end) = parseArrowTimes(timingLine) else {
                index += 1
                continue
            }

            index += 1
            var payload: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                payload.append(lines[index])
                index += 1
            }
            let text = payload
                .map { isVTT ? stripMarkupTags($0) : $0 }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(Cue(text: text, startTime: start, endTime: end))
        }
        return cues
    }

    private static func isVTTIgnoredBlock(_ line: String) -> Bool {
        let upper = line.uppercased()
        return upper.hasPrefix("NOTE") || upper.hasPrefix("STYLE") || upper.hasPrefix("REGION")
    }

    private static func parseArrowTimes(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2,
              let start = parseClockToken(parts[0]),
              let end = parseClockToken(parts[1].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "") else {
            return nil
        }
        return (start, end)
    }

    // MARK: - ASS / SSA

    private static func parseASS(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            let payload = String(line.dropFirst("dialogue:".count)).trimmingCharacters(in: .whitespaces)
            let fields = splitASSFields(payload)
            guard fields.count >= 10,
                  let start = parseASSClock(fields[1]),
                  let end = parseASSClock(fields[2]) else {
                continue
            }
            let flattened = flattenASSText(fields[9...].joined(separator: ","))
            guard !flattened.isEmpty else { continue }
            cues.append(Cue(text: flattened, startTime: start, endTime: end))
        }
        return cues
    }

    private static func splitASSFields(_ payload: String) -> [String] {
        payload.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
    }

    private static func flattenASSText(_ text: String) -> String {
        var flattened = text
        while let match = flattened.firstMatch(of: /\{[^}]*\}/) {
            flattened.replaceSubrange(match.range, with: "")
        }
        flattened = flattened
            .replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\n", with: " ")
        return flattened
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Clocks

    private static func parseClockToken(_ raw: String) -> TimeInterval? {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard let match = token.wholeMatch(of: /(?:(\d{1,3}):)?(\d{1,3}):(\d{2})[,.](\d{1,3})/) else {
            return nil
        }
        return clock(
            hours: match.1.map(String.init),
            minutes: String(match.2),
            seconds: String(match.3),
            fraction: String(match.4)
        )
    }

    private static func parseASSClock(_ raw: String) -> TimeInterval? {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard let match = token.wholeMatch(of: /(\d+):(\d{2}):(\d{2})\.(\d{1,3})/) else {
            return nil
        }
        return clock(
            hours: String(match.1),
            minutes: String(match.2),
            seconds: String(match.3),
            fraction: String(match.4)
        )
    }

    private static func clock(
        hours: String?,
        minutes: String,
        seconds: String,
        fraction: String?
    ) -> TimeInterval? {
        guard let minuteValue = Double(minutes),
              let secondValue = Double(seconds),
              minuteValue.isFinite,
              secondValue.isFinite else {
            return nil
        }
        let hourValue = hours.flatMap(Double.init) ?? 0
        guard hourValue.isFinite else { return nil }
        return (hourValue * 3600) + (minuteValue * 60) + secondValue + fractionValue(fraction)
    }

    private static func fractionValue(_ digits: String?) -> TimeInterval {
        guard let digits, !digits.isEmpty, let value = Double(digits) else { return 0 }
        return value / pow(10, Double(digits.count))
    }

    private static func stripMarkupTags(_ text: String) -> String {
        var stripped = text
        while let match = stripped.firstMatch(of: /<[^>]+>/) {
            stripped.replaceSubrange(match.range, with: "")
        }
        return stripped
    }
}

typealias TimedTextSidecarProvider = (
    _ mediaPath: String,
    _ kind: TimedText.MediaKind,
    _ reference: ResourceReference
) async -> TimedText.LoadResult
