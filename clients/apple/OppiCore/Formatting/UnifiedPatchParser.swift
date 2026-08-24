import Foundation

// MARK: - Unified patch document

/// One file section from a unified patch. Lines never include another file.
struct UnifiedPatchFile: Sendable {
    let oldPath: String?
    let newPath: String?
    let hunks: [UnifiedPatchHunk]

    var lines: [DiffLine] {
        hunks.flatMap(\.lines)
    }

    var displayPath: String? {
        newPath ?? oldPath
    }
}

/// One hunk with the absolute old/new starts from its header.
struct UnifiedPatchHunk: Sendable {
    let oldStart: Int
    let newStart: Int
    let lines: [DiffLine]
}

/// Parsed unified patch. Multi-file documents stay split; callers must not flatten them.
struct UnifiedPatchDocument: Sendable {
    let files: [UnifiedPatchFile]
    /// File sections seen in the patch, including binary/rename/mode-only
    /// sections that have no renderable hunks.
    let detectedFileCount: Int

    var isMultiFile: Bool { detectedFileCount > 1 }
}

// MARK: - Parser

/// Platform-neutral unified-patch parser for raw Apple tool output.
///
/// Strict mode requires hunk headers and keeps absolute line numbers (edit results).
/// Lenient mode also accepts a headerless single-file replacement. Multi-file
/// input is returned as separate files so generic UI can keep the original text.
enum UnifiedPatchParser {

    struct Options: Sendable {
        var allowHeaderlessReplacement: Bool

        static let strict = Options(allowHeaderlessReplacement: false)
        static let lenient = Options(allowHeaderlessReplacement: true)
    }

    static func parse(_ text: String, options: Options) -> UnifiedPatchDocument? {
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var files: [FileBuilder] = []
        var current = FileBuilder()
        var hasFile = false

        func ensureFile() {
            if !hasFile {
                files.append(current)
                hasFile = true
            }
        }

        func persistCurrent() {
            guard hasFile else { return }
            files[files.count - 1] = current
        }

        func startFile() {
            persistCurrent()
            current = FileBuilder()
            files.append(current)
            hasFile = true
        }

        func beginFileIfNeededForHeader() {
            if !hasFile {
                ensureFile()
                return
            }
            if current.hasContent || current.newPath != nil {
                startFile()
            }
        }

        for rawLine in rawLines {
            if rawLine.hasPrefix("diff --git ") {
                if hasFile && (current.hasContent || current.hasPath || current.sawSectionMarker) {
                    startFile()
                } else {
                    ensureFile()
                }
                current.sawSectionMarker = true
                persistCurrent()
                continue
            }

            if rawLine.hasPrefix("@@") {
                guard let header = parseHunkHeader(rawLine) else { continue }
                ensureFile()
                current.finishHunk()
                current.startHunk(
                    oldStart: header.old,
                    oldCount: header.oldCount,
                    newStart: header.new,
                    newCount: header.newCount
                )
                persistCurrent()
                continue
            }

            if rawLine.hasPrefix("\\ No newline") {
                continue
            }

            if rawLine.hasPrefix("index ")
                || rawLine.hasPrefix("new file mode ")
                || rawLine.hasPrefix("deleted file mode ")
                || rawLine.hasPrefix("old mode ")
                || rawLine.hasPrefix("new mode ")
                || rawLine.hasPrefix("similarity index ")
                || rawLine.hasPrefix("rename from ")
                || rawLine.hasPrefix("rename to ")
                || rawLine.hasPrefix("copy from ")
                || rawLine.hasPrefix("copy to ")
                || rawLine.hasPrefix("Binary files ") {
                continue
            }

            if !current.inHunk && (rawLine.hasPrefix("--- ") || rawLine.hasPrefix("+++ ")) {
                if rawLine.hasPrefix("--- ") {
                    beginFileIfNeededForHeader()
                    current.oldPath = parseDiffPath(rawLine, prefix: "--- ")
                } else {
                    ensureFile()
                    current.newPath = parseDiffPath(rawLine, prefix: "+++ ")
                }
                current.sawSectionMarker = true
                persistCurrent()
                continue
            }

            guard let prefix = rawLine.first else { continue }
            let body = String(rawLine.dropFirst())

            if current.inHunk {
                if current.appendHunkLine(prefix: prefix, text: body) {
                    persistCurrent()
                }
                continue
            }

            if options.allowHeaderlessReplacement,
               prefix == "+" || prefix == "-" || prefix == " " {
                ensureFile()
                current.appendHeaderlessLine(prefix: prefix, text: body)
                persistCurrent()
            }
        }

        persistCurrent()

        let completed = files.compactMap { file -> UnifiedPatchFile? in file.finish(options: options) }
        let detectedFileCount = files.filter { $0.sawSectionMarker || $0.hasPath || $0.hasContent }.count
        guard !completed.isEmpty else { return nil }
        return UnifiedPatchDocument(files: completed, detectedFileCount: detectedFileCount)
    }

    private static func parseHunkHeader(_ line: String) -> (old: Int, oldCount: Int, new: Int, newCount: Int)? {
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 5,
              let oldRange = Range(match.range(at: 1), in: line),
              let newRange = Range(match.range(at: 3), in: line),
              let old = Int(String(line[oldRange])),
              let new = Int(String(line[newRange])) else {
            return nil
        }
        let oldCount = Range(match.range(at: 2), in: line).flatMap { Int(String(line[$0])) } ?? 1
        let newCount = Range(match.range(at: 4), in: line).flatMap { Int(String(line[$0])) } ?? 1
        return (old, oldCount, new, newCount)
    }

    private static func parseDiffPath(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var candidate = String(line.dropFirst(prefix.count))

        if let tabIndex = candidate.firstIndex(of: "\t") {
            candidate = String(candidate[..<tabIndex])
        }

        if let timestamp = candidate.range(of: #" \d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            candidate = String(candidate[..<timestamp.lowerBound])
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.count >= 2, candidate.hasPrefix("\""), candidate.hasSuffix("\"") {
            candidate = String(candidate.dropFirst().dropLast())
        }

        if candidate == "/dev/null" || candidate.isEmpty {
            return nil
        }

        if candidate.hasPrefix("a/") || candidate.hasPrefix("b/") {
            candidate.removeFirst(2)
        }

        return candidate.isEmpty ? nil : candidate
    }
}

private struct FileBuilder {
    var oldPath: String?
    var newPath: String?
    var sawSectionMarker = false
    var hunks: [UnifiedPatchHunk] = []
    var headerlessLines: [DiffLine] = []
    var hunkOldStart = 0
    var hunkNewStart = 0
    var oldLineNumber: Int?
    var newLineNumber: Int?
    var remainingOld = 0
    var remainingNew = 0
    var inHunk = false
    var currentHunkLines: [DiffLine] = []

    var hasPath: Bool { oldPath != nil || newPath != nil }
    var hasContent: Bool {
        !hunks.isEmpty || !headerlessLines.isEmpty || !currentHunkLines.isEmpty
    }

    mutating func startHunk(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        hunkOldStart = oldStart
        hunkNewStart = newStart
        oldLineNumber = oldStart
        newLineNumber = newStart
        remainingOld = oldCount
        remainingNew = newCount
        inHunk = oldCount > 0 || newCount > 0
        currentHunkLines = []
    }

    mutating func finishHunk() {
        guard inHunk else { return }
        if !currentHunkLines.isEmpty {
            hunks.append(UnifiedPatchHunk(
                oldStart: hunkOldStart,
                newStart: hunkNewStart,
                lines: currentHunkLines
            ))
        }
        inHunk = false
        currentHunkLines = []
    }

    mutating func appendHunkLine(prefix: Character, text: String) -> Bool {
        switch prefix {
        case " ":
            guard let currentOldLine = oldLineNumber,
                  let currentNewLine = newLineNumber else { return false }
            currentHunkLines.append(DiffLine(
                kind: .context,
                text: text,
                oldLineNumber: positiveLineNumber(currentOldLine),
                newLineNumber: positiveLineNumber(currentNewLine)
            ))
            increment(&oldLineNumber)
            increment(&newLineNumber)
            remainingOld -= 1
            remainingNew -= 1
        case "-":
            guard let currentOldLine = oldLineNumber else { return false }
            currentHunkLines.append(DiffLine(
                kind: .removed,
                text: text,
                oldLineNumber: positiveLineNumber(currentOldLine),
                newLineNumber: nil
            ))
            increment(&oldLineNumber)
            remainingOld -= 1
        case "+":
            guard let currentNewLine = newLineNumber else { return false }
            currentHunkLines.append(DiffLine(
                kind: .added,
                text: text,
                oldLineNumber: nil,
                newLineNumber: positiveLineNumber(currentNewLine)
            ))
            increment(&newLineNumber)
            remainingNew -= 1
        default:
            return false
        }
        if remainingOld <= 0 && remainingNew <= 0 {
            finishHunk()
        }
        return true
    }

    mutating func appendHeaderlessLine(prefix: Character, text: String) {
        switch prefix {
        case " ":
            headerlessLines.append(DiffLine(kind: .context, text: text))
        case "-":
            headerlessLines.append(DiffLine(kind: .removed, text: text))
        case "+":
            headerlessLines.append(DiffLine(kind: .added, text: text))
        default:
            break
        }
    }

    func finish(options: UnifiedPatchParser.Options) -> UnifiedPatchFile? {
        var finished = self
        finished.finishHunk()

        var hunks = finished.hunks
        if hunks.isEmpty && !finished.headerlessLines.isEmpty {
            let added = finished.headerlessLines.contains { $0.kind == .added }
            let removed = finished.headerlessLines.contains { $0.kind == .removed }
            let allow = options.allowHeaderlessReplacement
                && (finished.hasPath || (added && removed))
            guard allow else { return nil }
            hunks = [
                UnifiedPatchHunk(oldStart: 0, newStart: 0, lines: finished.headerlessLines),
            ]
        }

        guard !hunks.isEmpty else { return nil }
        return UnifiedPatchFile(oldPath: finished.oldPath, newPath: finished.newPath, hunks: hunks)
    }
}

private func positiveLineNumber(_ value: Int) -> Int? {
    value > 0 ? value : nil
}

private func increment(_ value: inout Int?) {
    value = (value ?? 0) + 1
}
