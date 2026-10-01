import Foundation

/// One UI-free policy for the inline viewport and full-screen reader. Raw and
/// copy output are separate: composing a document must never change the clipboard.
enum ToolCallDocumentBuilder {
    static func build(args: [String: JSONValue]?, inputPresentation: ToolInputPresentation?,
                      nestedCalls: NestedToolCalls?, output: String, rawOutput: String,
                      details: JSONValue?, isDone: Bool, previewOnly: Bool = false, totalBytes: Int? = nil, toolName: String? = nil) -> ToolContentDescriptor.Markdown? {
        var sections: [(String, String)] = []
        let hints = inputPresentation?.fields.filter { $0.value.role == "code" }.mapValues(\.language) ?? [:]
        let input = (toolName.map { "**Tool**\n\n" + inlineCode($0) + "\n\n" } ?? "") + input(args ?? [:], hints: hints)
        if !input.isEmpty { sections.append(("Input", input)) }
        if let nestedCalls { sections.append(("Calls", calls(nestedCalls))) }
        let body = outputBody(output, details: details)
        if !body.isEmpty { sections.append(("Output", body)) }
        else if !isDone && !sections.isEmpty { sections.append(("Output", "Waiting for output…")) }
        guard !sections.isEmpty else { return nil }
        let text = sections.map { sections.count > 1 ? "## \($0.0)\n\n\($0.1)" : $0.1 }.joined(separator: "\n\n")
        let rawArgs = OrderedJSON.from(.object(args ?? [:])).json(pretty: true)
        let availability = previewOnly
            ? "Output preview only" + (totalBytes.map { " (\(rawOutput.utf8.count) of \($0) bytes)" } ?? "") + ". Full output may be unavailable for a stopped session.\n\n"
            : ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let rawCalls = nestedCalls.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        let identity = toolName.map { "Tool\n\n" + $0 + "\n\n" } ?? ""
        return .init(text: text, filePath: details?.objectValue?["filePath"]?.stringValue,
                     rawText: identity + "Input\n\n" + rawArgs + (rawCalls.map { "\n\nCalls\n\n" + $0 } ?? "") + "\n\nOutput\n\n" + availability + rawOutput)
    }

    private static func input(_ args: [String: JSONValue], hints: [String: String]) -> String {
        let nonEmpty = args.keys.sorted().filter { args[$0] != .null && args[$0] != .string("") }
        let fields = Array((nonEmpty.filter { hints[$0] != nil } + nonEmpty.filter { hints[$0] == nil }).prefix(200))
        var blocks: [String] = []
        let codeKeys = fields.filter { hints[$0] != nil }
        for key in codeKeys {
            let value = args[key]!
            let text = value.stringValue ?? OrderedJSON.from(value).json(pretty: true)
            let language = safeLanguage(hints[key] ?? "text")
            blocks.append((fields.count == 1 ? "" : label(key) + "\n\n") + boundedFence(text, language: language))
        }
        let others = fields.filter { hints[$0] == nil }
        let scalars = others.filter { let value = OrderedJSON.from(args[$0]!); return value.scalar != nil && !(value.scalar?.contains("\n") ?? false) }
        if !scalars.isEmpty {
            blocks.append(table(headers: ["Field", "Value"], rows: scalars.map { [$0, OrderedJSON.from(args[$0]!).scalar ?? ""] }))
        }
        for key in others.filter({ !scalars.contains($0) }) {
            let value = OrderedJSON.from(args[key]!)
            blocks.append(label(key) + "\n\n" + boundedFence(value.scalar ?? value.json(pretty: true), language: value.scalar == nil ? "json" : "text"))
        }
        if nonEmpty.count > fields.count { blocks.append("… \(nonEmpty.count - fields.count) more fields") }
        return blocks.joined(separator: "\n\n")
    }

    private static func calls(_ nested: NestedToolCalls) -> String {
        var lines = nested.calls.prefix(256).map { call in
            let mark = call.status == "ok" ? "✓" : call.status == "error" ? "✗" : "…"
            let args = call.arguments.map { OrderedJSON.from(.object($0)).json() }
                ?? call.argumentsBytes.map { "[\($0) bytes]" } ?? ""
            let duration = call.durationMs.map { ms in
                ms < 1000 ? "\(Int(ms)) ms" : String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), ms / 1000)
            }
            var text = "- \(mark) \(inline(call.display?.label(fallback: call.name) ?? call.name)) \(inlineCode(clipped(args, cap: 120)))"
            if let duration { text += " · " + duration }
            if call.status == "error", let error = call.error, !error.isEmpty {
                text += "\n\n" + boundedFence(error, language: "text").components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")
            }
            return text
        }
        if !nested.complete { lines.append("Some calls not recorded.") }
        return lines.joined(separator: "\n\n")
    }

    private static func outputBody(_ output: String, details: JSONValue?) -> String {
        let metadata = details?.objectValue ?? [:]
        if let expanded = metadata["expandedText"]?.stringValue, !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return formatted(expanded, format: metadata["presentationFormat"]?.stringValue,
                             language: metadata["language"]?.stringValue,
                             filePath: metadata["filePath"]?.stringValue)
        }
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Presentation metadata describes expandedText, never ordinary output.
            return formatted(output)
        }
        if let tui = metadata["tuiRender"]?.objectValue,
           let text = tui["expandedText"]?.stringValue, !text.isEmpty { return boundedFence(ANSIParser.strip(text), language: "text") }
        return ""
    }

    private static func formatted(_ text: String, format: String? = nil, language: String? = nil, filePath: String? = nil) -> String {
        guard text.utf8.count <= OrderedJSON.byteBudget else {
            return boundedFence(ANSIParser.strip(text), language: "text")
        }
        switch format?.lowercased() {
        case "markdown": return text
        case "code":
            let hint = language ?? filePath.flatMap { FileType.detect(from: $0).syntaxLanguage?.displayName.lowercased() } ?? "text"
            return fence(text, language: safeLanguage(hint))
        case "diff": return fence(text, language: "diff")
        case "terminal": return fence(ANSIParser.strip(text), language: "text")
        default: break
        }
        if let json = OrderedJSON.parse(text) { var renderer = Renderer(); return renderer.render(json) }
        if let (preamble, json) = OrderedJSON.parseLineSuffix(text) {
            var renderer = Renderer()
            return preamble.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", omittingEmptySubsequences: false).map { inline(String($0)) }.joined(separator: "  \n")
                + "\n\n" + renderer.render(json)
        }
        if UnifiedPatchParser.parse(text, options: .lenient) != nil { return fence(text, language: "diff") }
        if ToolContentDescriptorBuilder.looksLikeMarkdownContent(text) { return text }
        return fence(ANSIParser.strip(text), language: "text")
    }

    private static func unwrap(_ value: OrderedJSON, decodes: Int = 0) -> OrderedJSON {
        if case .string(let text) = value, decodes < 3 {
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = s.first, ["{", "[", "\""].contains(String(first)), let parsed = OrderedJSON.parse(s) {
                return unwrap(parsed, decodes: decodes + 1)
            }
        }
        guard case .object(let fields) = value else { return value }
        let keys = Set(fields.map(\.key))
        if keys == ["status", "value"], value["status"] == .string("fulfilled"), let result = value["value"] { return unwrap(result, decodes: decodes) }
        if keys == ["status", "reason"], value["status"] == .string("rejected"), let reason = value["reason"] {
            return .object([.init(key: "✗ Error", value: reason)])
        }
        if case .array(let content) = value["content"], !content.isEmpty,
           keys.isSubset(of: ["content", "structuredContent", "isError", "_meta"]),
           content.allSatisfy({ ["text", "image", "audio", "resource", "resource_link"].contains($0["type"]?.scalar ?? "") }) {
            let result: OrderedJSON
            if let structured = value["structuredContent"], structured != .null, structured != .object([]), structured != .array([]), structured != .string("") { result = structured }
            else {
                let items: [OrderedJSON] = content.compactMap { item in
                    switch item["type"]?.scalar {
                    case "text": return item["text"].map { unwrap($0, decodes: decodes) }
                    case "image": return .string("[image \(item["mimeType"]?.scalar ?? "unknown")]")
                    case "resource_link": return .string([item["name"]?.scalar, item["uri"]?.scalar].compactMap { $0 }.joined(separator: " · "))
                    case "resource":
                        let resource = item["resource"]
                        return .string([resource?["uri"]?.scalar, resource?["text"]?.scalar ?? resource?["mimeType"]?.scalar].compactMap { $0 }.joined(separator: "\n"))
                    default: return .string("[\(item["type"]?.scalar ?? "content")]")
                    }
                }
                result = items.count == 1 ? items[0] : .array(items)
            }
            if value["isError"] == .bool(true) { return .object([.init(key: "✗ Error", value: result)]) }
            return unwrap(result, decodes: decodes)
        }
        return value
    }

    private struct Renderer {
        var nodes = 0
        mutating func render(_ original: OrderedJSON, depth: Int = 0) -> String {
            nodes += 1
            guard depth < 4, nodes <= 2000 else { return fence(original.json(pretty: true), language: "json") }
            let value = unwrap(original)
            switch value {
            case .string(let s):
                if s.contains("\n") { return ToolContentDescriptorBuilder.looksLikeMarkdownContent(s) ? s : fence(s, language: "text") }
                return inline(s)
            case .number, .bool, .null: return inline(value.scalar ?? "null")
            case .object(let fields):
                if fields.isEmpty { return "(empty object)" }
                let shown = Array(fields.prefix(200))
                let scalars = shown.filter { let v = unwrap($0.value); return v.scalar != nil && !(v.scalar?.contains("\n") ?? false) }
                var blocks: [String] = []
                if !scalars.isEmpty { blocks.append(table(headers: ["Field", "Value"], rows: scalars.map { [$0.key, unwrap($0.value).scalar ?? ""] })) }
                for field in shown where !scalars.contains(where: { $0.key == field.key }) {
                    blocks.append(label(field.key) + "\n\n" + render(field.value, depth: depth + 1))
                }
                if fields.count > 200 { blocks.append("… \(fields.count - 200) more fields") }
                return blocks.joined(separator: "\n\n")
            case .array(let values):
                if values.isEmpty { return "(empty array)" }
                let shown = values.prefix(200).map { unwrap($0) }
                var result: String
                if shown.allSatisfy({ $0.scalar != nil }) {
                    let multiline = shown.contains { $0.scalar?.contains("\n") == true }
                    result = shown.map { item in
                        let body = render(item, depth: depth)
                        return "- " + body.components(separatedBy: "\n").joined(separator: "\n  ")
                    }.joined(separator: multiline ? "\n\n" : "\n")
                } else if let rows = objectRows(shown) {
                    result = table(headers: rows.0, rows: rows.1)
                } else if let rows = matrixRows(shown) {
                    result = table(headers: (1...rows[0].count).map { String($0) }, rows: rows)
                } else {
                    var items: [String] = []
                    for (index, item) in shown.enumerated() {
                        // List wrappers do not spend an object-field depth level. This
                        // keeps nested result/lap forms readable without raising the cap.
                        let itemDepth = if case .array = item { depth + 1 } else { depth }
                        let body = render(item, depth: itemDepth)
                        items.append("\(index + 1). " + body.components(separatedBy: "\n").joined(separator: "\n   "))
                    }
                    result = items.joined(separator: "\n\n")
                }
                if values.count > 200 { result += "\n\n… \(values.count - 200) more" }
                return result
            }
        }
        private func objectRows(_ values: [OrderedJSON]) -> ([String], [[String]])? {
            var keys: [String] = []
            for value in values {
                guard case .object(let fields) = value, !fields.isEmpty, fields.allSatisfy({ unwrap($0.value).scalar != nil && !(unwrap($0.value).scalar?.contains("\n") ?? false) }) else { return nil }
                for field in fields where !keys.contains(field.key) { keys.append(field.key) }
                if keys.count > 8 { return nil }
            }
            return (keys, values.map { value in keys.map { value[$0].map { unwrap($0).scalar ?? "" } ?? "" } })
        }
        private func matrixRows(_ values: [OrderedJSON]) -> [[String]]? {
            var rows: [[String]] = []
            for value in values {
                guard case .array(let cells) = value, !cells.isEmpty, cells.count <= 12,
                      cells.allSatisfy({ $0.scalar != nil && !($0.scalar?.contains("\n") ?? false) }),
                      rows.isEmpty || cells.count == rows[0].count else { return nil }
                rows.append(cells.map { $0.scalar ?? "" })
            }
            return rows
        }
    }

    static func fence(_ text: String, language: String) -> String {
        var longest = 0; var run = 0
        for char in text { if char == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let marker = String(repeating: "`", count: max(3, longest + 1))
        return marker + language + "\n" + text + "\n" + marker
    }
    private static func boundedFence(_ text: String, language: String) -> String {
        guard text.utf8.count > OrderedJSON.byteBudget else { return fence(text, language: language) }
        var bytes = 0
        let preview = String(text.unicodeScalars.prefix { scalar in
            bytes += scalar.utf8.count; return bytes <= OrderedJSON.byteBudget
        })
        return fence(preview, language: language) + "\n\nPreview limited to 64 KB. See Raw for available input and output; output completeness is noted there."
    }
    private static func inlineCode(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        // Code spans have no backslash escape. Use a delimiter longer than any
        // backtick run and padding so JSON quotes and backticks stay literal.
        let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let marker = String(repeating: "`", count: longest + 1)
        return marker + " " + text.replacingOccurrences(of: "\n", with: " ") + " " + marker
    }
    private static func safeLanguage(_ language: String) -> String {
        language.range(of: "^[a-zA-Z0-9_+-]{1,40}$", options: .regularExpression) != nil ? language : "text"
    }
    private static func clipped(_ text: String, cap: Int) -> String { text.count > cap ? String(text.prefix(cap - 1)) + "…" : text }
    private static func label(_ text: String) -> String { "**" + inline(text) + "**" }
    private static func inline(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_{}[]<>#!|~+-".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
    private static func table(headers: [String], rows: [[String]]) -> String {
        func row(_ values: [String]) -> String {
            "| " + values.map { inline(clipped($0, cap: 200)).replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
        }
        return ([row(headers), "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"] + rows.map(row)).joined(separator: "\n")
    }
}
