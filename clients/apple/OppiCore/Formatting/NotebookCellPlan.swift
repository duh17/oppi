import Foundation

/// UI-free notebook cell for an expanded generic tool call.
///
/// Code-role fields fill the cell's source; any other tool shows its
/// arguments there instead. Selected from input roles and inspection facts,
/// never from a tool name. iOS paints this; the markdown document remains the
/// descriptor leaf for raw text, copy, and Mac.
struct NotebookCellPlan: Equatable, Hashable, Sendable {
    struct Source: Equatable, Hashable, Sendable {
        var label: String?
        var language: String?
        var code: String

        var languageName: String? {
            guard let language, !language.isEmpty else { return nil }
            let detected = SyntaxLanguage.detect(language)
            return detected == .unknown ? language : detected.displayName
        }

        var syntaxLanguage: SyntaxLanguage {
            SyntaxLanguage.detect(language ?? "")
        }
    }

    struct Call: Equatable, Hashable, Sendable {
        var name: String
        var status: String
        var duration: String?
        var arguments: String?
        var error: String?
    }

    enum Output: Equatable, Hashable, Sendable {
        case none
        case stdout(String)
        case rich(String)
    }

    var sources: [Source]
    /// False when the source is the call's arguments rather than code.
    var inputIsCode: Bool
    var metadata: [String]
    var calls: [Call]
    var omittedCalls: Int
    var callsIncomplete: Bool
    var output: Output
    var availabilityNote: String?
    var running: Bool
    var failed: Bool

    /// Copy and live-reader text: the source, or the output when the call
    /// had no arguments.
    var readerText: String {
        if !sources.isEmpty { return sources.map(\.code).joined(separator: "\n\n") }
        switch output {
        case .none: return ""
        case .stdout(let text), .rich(let text): return text
        }
    }

    var hasOutputWell: Bool {
        if case .none = output, calls.isEmpty, omittedCalls == 0, !callsIncomplete, availabilityNote == nil, !running {
            return false
        }
        return true
    }

    /// Nil when there is nothing to show: no arguments, calls, or output.
    /// Callers still reject terminal, file, media, and
    /// interactive inspections.
    static func make(
        input: [ToolInspection.Field],
        calls: NestedToolCalls?,
        output: String,
        details: JSONValue?,
        outputPresentation: ToolOutputPresentation? = nil,
        isDone: Bool,
        isError: Bool,
        previewOnly: Bool,
        totalBytes: Int?
    ) -> NotebookCellPlan? {
        let codeSources = input.compactMap { field -> Source? in
            guard field.role == "code" else { return nil }
            let code = codeText(field.value)
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Source(label: field.name, language: field.language, code: code)
        }
        let inputIsCode = !codeSources.isEmpty
        let sources = inputIsCode ? codeSources : argumentSource(input).map { [$0] } ?? []
        let labeled = sources.count > 1
        // The status preamble repeats the row's status and duration.
        let body = outputPresentation?.hidingStatusHeader(in: output) ?? output
        let recorded = calls?.calls ?? []
        let shown = recorded.prefix(256)
        let plan = NotebookCellPlan(
            sources: sources.map {
                Source(label: labeled ? $0.label : nil, language: $0.language, code: $0.code)
            },
            inputIsCode: inputIsCode,
            metadata: inputIsCode ? metadata(input) : [],
            calls: shown.map(call),
            omittedCalls: max(0, recorded.count - shown.count),
            callsIncomplete: calls?.complete == false,
            output: cellOutput(
                printed: body, details: details,
                detailsAreRedundant: !isDone || !recorded.isEmpty
            ),
            availabilityNote: ToolCallDocumentBuilder.previewNote(
                output: body, previewOnly: previewOnly, totalBytes: totalBytes
            ),
            running: !isDone,
            failed: isError
        )
        // Nothing to paint yet: the row keeps its waiting placeholder.
        let empty = plan.sources.isEmpty && plan.calls.isEmpty && plan.omittedCalls == 0
            && plan.output == .none && plan.availabilityNote == nil
        return empty ? nil : plan
    }

    /// A call's arguments as YAML-style source, one `name: value` per field.
    /// Multi-line text and structured values continue on indented lines.
    private static func argumentSource(_ input: [ToolInspection.Field]) -> Source? {
        let lines = input.compactMap { field -> String? in
            guard field.value != .null, field.value != .string("") else { return nil }
            let value = OrderedJSON.from(field.value)
            let text = value.scalar ?? value.json(pretty: true)
            guard text.contains("\n") else {
                // Quote a one-line string YAML would misread, such as `fix #123`.
                let shown = field.value.stringValue != nil && yamlNeedsQuotes(text)
                    ? OrderedJSON.string(text).json() : text
                return field.name + ": " + shown
            }
            let indented = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "  " + $0 }.joined(separator: "\n")
            return field.name + (value.scalar == nil ? ":\n" : ": |\n") + indented
        }
        guard !lines.isEmpty else { return nil }
        return Source(label: nil, language: "yaml", code: lines.joined(separator: "\n"))
    }

    private static func yamlNeedsQuotes(_ text: String) -> Bool {
        guard let first = text.first else { return true }
        return text.contains(" #") || text.contains(": ") || text != text.trimmingCharacters(in: .whitespaces)
            || "#-?:,[]{}&*!|>'\"%@`".contains(first)
    }

    /// First meaningful code line. Directive comments such as `// @options:`
    /// or `# @flag` configure the run and say nothing about what it does.
    static func collapsedTitle(from fields: [ToolInspection.Field]) -> String? {
        for field in fields where field.role == "code" {
            let text = codeText(field.value)
            if let line = text.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty && !isDirectiveComment($0) }) {
                return String(line.prefix(240))
            }
        }
        return nil
    }

    private static func isDirectiveComment(_ line: String) -> Bool {
        for marker in ["//", "#", "--"] where line.hasPrefix(marker) {
            return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).hasPrefix("@")
        }
        return false
    }

    static func languageBadge(from fields: [ToolInspection.Field]) -> String? {
        fields.first { $0.role == "code" }?.language.flatMap { language in
            guard !language.isEmpty else { return nil }
            let detected = SyntaxLanguage.detect(language)
            return detected == .unknown ? language : detected.displayName
        }
    }

    private static func codeText(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        return OrderedJSON.from(value).json(pretty: true)
    }

    private static func metadata(_ input: [ToolInspection.Field]) -> [String] {
        let fields = input.filter { field in
            field.role != "code" && field.value != .null && field.value != .string("")
        }
        let shown = fields.prefix(4).map { field in
            let value = OrderedJSON.from(field.value)
            let text = value.scalar ?? value.json()
            return field.name + " " + clip(text, 40)
        }
        var lines = [shown.joined(separator: " · ")]
        if fields.count > shown.count {
            lines.append("\(fields.count - shown.count) more fields")
        }
        return lines.filter { !$0.isEmpty }
    }

    private static func call(_ record: NestedToolCallRecord) -> Call {
        let arguments: String?
        if let args = record.arguments {
            arguments = argumentSummary(args).map { clip($0, 240) }
        } else if let bytes = record.argumentsBytes {
            arguments = "[\(bytes) bytes]"
        } else {
            arguments = nil
        }
        let error = record.status == "error" ? record.error.flatMap { error in
            let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : clip(trimmed.replacingOccurrences(of: "\n", with: " "), 240)
        } : nil
        return Call(
            name: record.display?.label(fallback: record.name) ?? record.name,
            status: record.status,
            duration: record.durationMs.map(duration),
            arguments: arguments,
            error: error
        )
    }

    /// One readable line: a lone scalar argument is the value itself
    /// (`git log -5`), otherwise `name: value` pairs sorted by name.
    private static func argumentSummary(_ args: [String: JSONValue]) -> String? {
        guard case .object(let fields) = OrderedJSON.from(.object(args)) else { return nil }
        let present = fields.filter { $0.value != .null && $0.value != .string("") }
        func flat(_ value: OrderedJSON) -> String {
            (value.scalar ?? value.json()).replacingOccurrences(of: "\n", with: " ")
        }
        if present.count == 1, let only = present.first, only.value.scalar != nil {
            return flat(only.value)
        }
        let text = present.map { $0.key + ": " + flat($0.value) }.joined(separator: "  ")
        return text.isEmpty ? nil : text
    }

    private static func duration(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms)) ms" : String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), ms / 1000)
    }

    /// Printed text stays printed, the way a notebook shows stdout. Only a
    /// result that is entirely one JSON object, array, or string, or producer `expandedText`,
    /// takes the rendered document (tables, lists).
    ///
    /// With no printed text the document falls back to raw `details`. While
    /// the script runs, or when nested calls are already listed, those details
    /// are progress records that repeat the CALLS section, so the cell shows
    /// no output instead.
    ///
    /// The document is formatted only on those paths: printed output, the
    /// common case on every streaming delta, never pays for JSON/patch/Markdown
    /// detection.
    private static func cellOutput(
        printed: String,
        details: JSONValue?,
        detailsAreRedundant: Bool
    ) -> Output {
        func document() -> String { ToolCallDocumentBuilder.formattedOutput(printed, details: details) }
        let text = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = details?.objectValue?["expandedText"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if text.isEmpty, !expanded, detailsAreRedundant { return .none }
        // A bare number, boolean, or null prints as is. Objects and arrays
        // format, and a JSON string is decoded so it does not show quoted.
        // Only text that opens like a JSON object, array, or string is parsed,
        // so ordinary printed output skips the parse on every streaming delta.
        let structured: Bool = switch text.first.flatMap({ "{[\"".contains($0) ? OrderedJSON.parse(text) : nil }) {
        case .object?, .array?, .string?: true
        case .number?, .bool?, .null?, nil: false
        }
        if text.isEmpty || expanded || structured {
            return classify(document())
        }
        return .stdout(ANSIParser.strip(text))
    }

    /// The formatted document is always Markdown (JSON forms render as nested
    /// lists and tables). Only a document that is exactly one plain-text fence
    /// reads as printed text; a code or diff fence keeps its highlighting.
    private static func classify(_ body: String) -> Output {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if let inner = unwrapSingleFence(trimmed) {
            return .stdout(inner)
        }
        return .rich(trimmed)
    }

    /// A document that is exactly one fence. The cell shows the inside as stdout.
    private static func unwrapSingleFence(_ text: String) -> String? {
        guard text.hasPrefix("`") else { return nil }
        let markerCount = text.prefix { $0 == "`" }.count
        guard markerCount >= 3 else { return nil }
        let marker = String(repeating: "`", count: markerCount)
        guard text.hasSuffix("\n" + marker), !text.dropFirst(markerCount).hasPrefix(marker) else { return nil }
        let rest = text.dropFirst(markerCount)
        guard let newline = rest.firstIndex(of: "\n") else { return nil }
        let info = rest[..<newline].trimmingCharacters(in: .whitespaces)
        guard info.isEmpty || info == "text" else { return nil }
        let inner = rest[rest.index(after: newline)...].dropLast(marker.count + 1)
        guard !inner.contains("\n" + marker) else { return nil }
        return String(inner)
    }

    private static func clip(_ text: String, _ cap: Int) -> String {
        text.count > cap ? String(text.prefix(cap - 1)) + "…" : text
    }
}
