import Foundation

/// Parser for Mermaid `journey` body syntax.
///
/// Spec: https://mermaid.js.org/syntax/userJourney.html
///
/// Covered:
/// - `title`
/// - `section`
/// - `Task name: <score 1-5>: actor, actor`
/// - `%%` comments and blank lines
///
/// Score outside 1...5 is recorded on `JourneyDiagram.error` so the
/// renderer can fail visibly.
enum MermaidJourneyParser {

    nonisolated static func parse(lines: [String]) -> JourneyDiagram {
        var title: String?
        var sections: [JourneySection] = []
        var currentName: String?
        var currentTasks: [JourneyTask] = []
        var error: String?

        func flushSection() {
            guard let name = currentName else { return }
            sections.append(JourneySection(name: name, tasks: currentTasks))
            currentName = nil
            currentTasks = []
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("%%") { continue }

            if consumingKeyword(line, "journey") != nil {
                continue
            }

            if let value = consumingKeyword(line, "title") {
                title = parseTitleValue(value)
                continue
            }

            if let value = consumingKeyword(line, "section") {
                flushSection()
                currentName = parseTitleValue(value) ?? value.trimmingCharacters(in: .whitespaces)
                continue
            }

            if let task = parseTask(line) {
                if currentName == nil {
                    currentName = ""
                }
                currentTasks.append(task)
                continue
            }

            if let leftover = parseIllegalScore(line) {
                error = leftover
                continue
            }
        }

        flushSection()
        return JourneyDiagram(title: title, sections: sections, error: error)
    }

    /// `Task name: <score>: actor, actor`
    private static func parseTask(_ line: String) -> JourneyTask? {
        let pattern = #"^(.+):\s*([1-5])\s*:\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let nameRange = Range(match.range(at: 1), in: line),
              let scoreRange = Range(match.range(at: 2), in: line),
              let actorsRange = Range(match.range(at: 3), in: line)
        else { return nil }

        let name = MermaidTextUtils.normalizeLabel(String(line[nameRange]))
        guard !name.isEmpty, let score = Int(line[scoreRange]) else { return nil }
        let actors = String(line[actorsRange])
            .split(separator: ",")
            .map { MermaidTextUtils.normalizeLabel($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        return JourneyTask(name: name, score: score, actors: actors)
    }

    private static func parseIllegalScore(_ line: String) -> String? {
        let pattern = #"^(.+):\s*(-?\d+)\s*:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let scoreRange = Range(match.range(at: 2), in: line),
              let score = Int(line[scoreRange]),
              score < 1 || score > 5
        else { return nil }
        return "Journey score must be 1-5, got \(score)"
    }

    private static func consumingKeyword(_ text: String, _ keyword: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let key = keyword.lowercased()
        guard trimmed.lowercased().hasPrefix(key) else { return nil }
        if trimmed.count == key.count { return "" }
        let nextIndex = trimmed.index(trimmed.startIndex, offsetBy: key.count)
        let next = trimmed[nextIndex]
        if next.isWhitespace || next == "\"" || next == "'" {
            return String(trimmed[nextIndex...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func parseTitleValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if (trimmed.first == "\"" || trimmed.first == "'"),
           trimmed.count >= 2,
           trimmed.last == trimmed.first {
            return MermaidTextUtils.normalizeLabel(String(trimmed.dropFirst().dropLast()))
        }
        let normalized = MermaidTextUtils.normalizeLabel(trimmed)
        return normalized.isEmpty ? nil : normalized
    }
}
