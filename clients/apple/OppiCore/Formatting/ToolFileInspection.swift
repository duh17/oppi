import Foundation

/// File semantics translated once from producer facts. No tool identity or summary parsing.
struct ToolFileInspection: Equatable, Sendable {
    enum Operation: Equatable, Sendable { case content, mutation, edits }
    enum Provenance: String, Equatable, Sendable { case requested, result }
    var operation: Operation
    var path: String?
    var fileType: FileType?
    var startLine: Int
    var text: String
    var diff: [DiffLine]?
    var provenance: Provenance
    var prefix: String {
        switch operation { case .content: return "file-content"; case .mutation: return "file-mutation"; case .edits: return "file-diff" }
    }
    var stats: ToolCallFormatting.DiffStats? {
        guard let diff else { return nil }
        let stats = DiffEngine.stats(diff)
        return .init(added: stats.added, removed: stats.removed)
    }

    static func resolve(args: [String: JSONValue]?, input: ToolInputPresentation?, output: ToolOutputPresentation?,
                        details: JSONValue?, text: String, isDone: Bool, isError: Bool) -> Self? {
        guard output?.provenance == nil || output?.provenance == "requested" || output?.provenance == "result" else { return nil }
        guard output?.kind == "fileContent" || output?.kind == "diffOfEdits" else { return nil }
        func field(_ role: String) -> JSONValue? {
            guard let key = input?.fields.keys.sorted().first(where: { input?.fields[$0]?.role == role }) else { return nil }
            return args?[key]
        }
        let path = field("filePath")?.stringValue
        let offset = field("lineOffset")?.numberValue
        let startLine = offset.flatMap { $0.isFinite && $0 >= 1 && $0 < Double(Int.max) ? Int($0) : nil } ?? 1
        let requested = output?.provenance == "requested"
        let operation: Operation = output?.kind == "diffOfEdits" ? .edits : (requested ? .mutation : .content)
        let changes = field("edits")?.arrayValue ?? []
        let requestedDiff = requestedDiffLines(changes)
        let resultDiff = isDone && !isError ? resultDiffLines(details) : nil
        let body: String
        let diff: [DiffLine]?
        let provenance: Provenance
        if operation == .edits {
            diff = isError ? nil : (resultDiff ?? (requestedDiff.isEmpty ? nil : requestedDiff))
            provenance = resultDiff != nil ? .result : .requested
            // Partial newText remains previewable before a complete old/new pair exists.
            body = changes.compactMap { $0.objectValue?["newText"]?.stringValue ?? $0.objectValue?["oldText"]?.stringValue }.joined(separator: "\n")
        } else {
            body = requested ? (field("fileContent")?.stringValue ?? "") : text
            diff = nil
            provenance = requested ? .requested : .result
        }
        // Geographic JSON is the single documented content sniff, owned here (including ambiguous .json).
        let fileType = path.map { FileType.detect(from: $0, content: body) } ?? GeographicJSONSniffer.fileType(from: body)
        return .init(operation: operation, path: path, fileType: fileType, startLine: startLine,
                     text: body, diff: diff, provenance: provenance)
    }

    static func requestedDiffLines(_ changes: [JSONValue]) -> [DiffLine] {
        changes.flatMap { change -> [DiffLine] in
            guard let pair = change.objectValue, let old = pair["oldText"]?.stringValue, let new = pair["newText"]?.stringValue else { return [] }
            return DiffEngine.compute(old: old, new: new)
        }
    }

    /// Pi's standard patch is authoritative; older Pi results carry a numbered display diff.
    static func resultDiffLines(_ details: JSONValue?) -> [DiffLine]? {
        guard let object = details?.objectValue else { return nil }
        if let patch = object["patch"]?.stringValue,
           let document = UnifiedPatchParser.parse(patch, options: .strict), !document.isMultiFile,
           let file = document.files.first { return file.lines }
        guard let diff = object["diff"]?.stringValue else { return nil }
        if diff.isEmpty { return [] }
        if let document = UnifiedPatchParser.parse(diff, options: .strict), !document.isMultiFile,
           let file = document.files.first { return file.lines }
        var lines: [DiffLine] = []
        var lineDelta = 0
        // A producer may terminate the display diff with a newline; that is not a malformed row.
        for line in diff.trimmingCharacters(in: .newlines).components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "..." { continue }
            guard let sign = line.first, sign == "+" || sign == "-" || sign == " " else { return nil }
            let rest = line.dropFirst().drop(while: { $0 == " " })
            let digits = rest.prefix(while: { $0.isNumber })
            guard let number = Int(digits), rest.dropFirst(digits.count).first == " " else { return nil }
            let kind: DiffLine.Kind = sign == "+" ? .added : (sign == "-" ? .removed : .context)
            lines.append(.init(kind: kind, text: String(rest.dropFirst(digits.count + 1)),
                               oldLineNumber: kind == .added ? nil : number,
                               newLineNumber: kind == .removed ? nil : (kind == .context ? number + lineDelta : number)))
            if kind == .added { lineDelta += 1 }
            if kind == .removed { lineDelta -= 1 }
        }
        return lines.isEmpty ? nil : lines
    }
}
