import Foundation

/// Parser for Mermaid `kanban` body syntax.
///
/// Spec: https://mermaid.js.org/syntax/kanban.html
///
/// Covered:
/// - `columnId[Title]` then indented `taskId[Description]`
/// - `@{ assigned, ticket, priority }` with official priority values
/// - `ticketBaseUrl` with `#TICKET#` substitution stored on each task
///
/// Tapping ticket URLs is deferred (no link surface). Leftover priority
/// values stay `.unsupported` so the renderer can fail visibly.
enum MermaidKanbanParser {

    nonisolated static func parse(
        lines: [String],
        ticketBaseUrl: String? = nil
    ) -> KanbanDiagram {
        var columns: [KanbanColumn] = []
        var currentId: String?
        var currentTitle: String?
        var currentTasks: [KanbanTask] = []
        var columnIndent: Int?

        func flushColumn() {
            guard let id = currentId, let title = currentTitle else { return }
            columns.append(KanbanColumn(id: id, title: title, tasks: currentTasks))
            currentId = nil
            currentTitle = nil
            currentTasks = []
        }

        for rawLine in lines {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("%%") { continue }
            let withoutComment = stripTrailingComment(rawLine)
            let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.lowercased() == "kanban" { continue }

            let indent = leadingWhitespaceCount(withoutComment)
            guard let node = parseNode(trimmed) else { continue }

            let isColumn = currentId == nil || columnIndent.map { indent <= $0 } ?? (indent == 0)
            if isColumn {
                flushColumn()
                currentId = node.id
                currentTitle = node.title
                currentTasks = []
                columnIndent = indent
            } else {
                let meta = parseMetadata(node.metadata)
                let ticket = meta.ticket
                let ticketURL: String?
                if let ticket, let ticketBaseUrl, ticketBaseUrl.contains("#TICKET#") {
                    ticketURL = ticketBaseUrl.replacingOccurrences(of: "#TICKET#", with: ticket)
                } else if let ticket, let ticketBaseUrl, !ticketBaseUrl.isEmpty {
                    ticketURL = ticketBaseUrl + ticket
                } else {
                    ticketURL = nil
                }
                currentTasks.append(KanbanTask(
                    id: node.id,
                    description: node.title,
                    assigned: meta.assigned,
                    ticket: ticket,
                    ticketURL: ticketURL,
                    priority: meta.priority
                ))
            }
        }
        flushColumn()
        return KanbanDiagram(columns: columns, ticketBaseUrl: ticketBaseUrl)
    }

    private struct Node {
        let id: String
        let title: String
        let metadata: String?
    }

    private static func parseNode(_ line: String) -> Node? {
        var rest = line
        var metadata: String?
        if let at = rest.range(of: "@{") {
            let rawMeta = String(rest[at.upperBound...])
            if let close = rawMeta.firstIndex(of: "}") {
                metadata = String(rawMeta[..<close])
            } else {
                metadata = rawMeta
            }
            rest = String(rest[..<at.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        if let open = rest.firstIndex(of: "["), let close = rest.lastIndex(of: "]"), close > open {
            let id = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            let title = MermaidTextUtils.normalizeLabel(
                String(rest[rest.index(after: open)..<close])
            )
            guard !id.isEmpty else { return nil }
            return Node(id: id, title: title.isEmpty ? id : title, metadata: metadata)
        }

        let id = rest.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        return Node(id: id, title: id, metadata: metadata)
    }

    private struct Metadata {
        var assigned: String?
        var ticket: String?
        var priority: KanbanPriority?
    }

    private static func parseMetadata(_ raw: String?) -> Metadata {
        var meta = Metadata()
        guard let raw, !raw.isEmpty else { return meta }
        for piece in splitMetadata(raw) {
            guard let colon = piece.firstIndex(of: ":") else { continue }
            let key = String(piece[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(String(piece[piece.index(after: colon)...]))
            switch key {
            case "assigned":
                meta.assigned = value.isEmpty ? nil : value
            case "ticket":
                meta.ticket = value.isEmpty ? nil : value
            case "priority":
                meta.priority = parsePriority(value)
            default:
                break
            }
        }
        return meta
    }

    private static func splitMetadata(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in raw {
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    nonisolated static func parsePriority(_ raw: String) -> KanbanPriority? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "very high": return .veryHigh
        case "high": return .high
        case "low": return .low
        case "very low": return .veryLow
        default: return .unsupported(trimmed)
        }
    }

    private static func unquote(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        if (trimmed.first == "\"" || trimmed.first == "'"),
           trimmed.count >= 2,
           trimmed.last == trimmed.first {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return MermaidTextUtils.normalizeLabel(trimmed)
    }

    private static func leadingWhitespaceCount(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 }
            else if character == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private static func stripTrailingComment(_ line: String) -> String {
        var inQuote = false
        let chars = Array(line)
        for i in 0..<chars.count {
            if chars[i] == "\"" { inQuote.toggle() }
            if !inQuote, i + 1 < chars.count, chars[i] == "%", chars[i + 1] == "%" {
                return String(chars[0..<i])
            }
        }
        return line
    }
}
