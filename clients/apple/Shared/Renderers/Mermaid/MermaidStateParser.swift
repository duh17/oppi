import Foundation

private extension String {
    func strippingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

/// Parser for Mermaid state diagrams (`stateDiagram` / `stateDiagram-v2`).
///
/// Spec source: https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/docs/syntax/stateDiagram.md
/// This parser is deliberately conformance-driven and starts with the documented
/// grammar forms used by Mermaid's own syntax examples.
enum MermaidStateParser {
    nonisolated static func parse(lines: [String]) -> StateDiagram {
        var direction: FlowDirection = .TB
        var statesById: [String: StateNode] = [:]
        var stateOrder: [String] = []
        var transitions: [StateTransition] = []
        var notes: [StateDiagramNote] = []
        var composites: [StateComposite] = []
        var classDefs: [String: [String: String]] = [:]
        var classApplications: [String: [String]] = [:]
        var accessibilityTitle: String?
        var accessibilityDescription: String?
        var currentNote: ActiveStateNote?
        var compositeStack: [StateCompositeBuilder] = []
        var regionIndex = 0

        func upsertState(id: String, label: String? = nil, kind: StateNodeKind = .normal) {
            guard !id.isEmpty else { return }
            if var existing = statesById[id] {
                if let label, !label.isEmpty {
                    existing = StateNode(id: existing.id, label: label, kind: existing.kind, classes: existing.classes)
                }
                if existing.kind == .normal, kind != .normal {
                    existing = StateNode(id: existing.id, label: existing.label, kind: kind, classes: existing.classes)
                }
                statesById[id] = existing
            } else {
                statesById[id] = StateNode(id: id, label: label ?? id, kind: kind, classes: [])
                stateOrder.append(id)
            }
            compositeStack.last?.stateIds.insert(id)
        }

        func addTransition(from: StateEndpoint, to: StateEndpoint, label: String?) {
            transitions.append(StateTransition(
                from: from,
                to: to,
                label: label,
                scopeId: compositeStack.last?.id
            ))
            if case .state(let id) = from { upsertState(id: id) }
            if case .state(let id) = to { upsertState(id: id) }
        }

        let statements = expandStatements(lines: lines)
        for raw in statements {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if var note = currentNote {
                if line.lowercased() == "end note" {
                    notes.append(StateDiagramNote(
                        stateId: note.stateId,
                        position: note.position,
                        text: MermaidTextUtils.normalizeLabel(note.lines.joined(separator: "\n"))
                    ))
                    currentNote = nil
                } else {
                    note.lines.append(line)
                    currentNote = note
                }
                continue
            }

            if let value = parseAccessibilityDirective(line, keyword: "accTitle") {
                accessibilityTitle = value
                continue
            }
            if let value = parseAccessibilityDirective(line, keyword: "accDescr") {
                accessibilityDescription = value
                continue
            }

            if let value = line.strippingPrefix("direction ") {
                if let parsed = FlowDirection(rawValue: value.trimmingCharacters(in: .whitespaces)) {
                    if let current = compositeStack.last {
                        current.direction = parsed
                    } else {
                        direction = parsed
                    }
                }
                continue
            }

            if line == "--" {
                regionIndex += 1
                compositeStack.last?.regions.append(regionIndex)
                continue
            }

            if line.lowercased() == "end" || line == "}" {
                if let builder = compositeStack.popLast() {
                    let composite = builder.build()
                    if let parent = compositeStack.last {
                        parent.children.append(composite)
                    } else {
                        composites.append(composite)
                    }
                }
                continue
            }

            if let (id, label) = parseCompositeStart(line) {
                upsertState(id: id, label: label)
                compositeStack.append(StateCompositeBuilder(id: id, label: label))
                continue
            }

            if let (name, props) = parseClassDef(line) {
                classDefs[name] = props
                continue
            }

            if let (ids, className) = parseClassApplication(line) {
                for id in ids {
                    classApplications[id, default: []].append(className)
                    upsertState(id: id)
                }
                continue
            }

            if let note = parseInlineNote(line) {
                upsertState(id: note.stateId)
                notes.append(note)
                continue
            }
            if let noteStart = parseNoteStart(line) {
                upsertState(id: noteStart.stateId)
                currentNote = ActiveStateNote(
                    position: noteStart.position,
                    stateId: noteStart.stateId,
                    lines: []
                )
                continue
            }

            if let transition = parseTransition(line) {
                addTransition(from: transition.from, to: transition.to, label: transition.label)
                for application in transition.classApplications {
                    classApplications[application.id, default: []].append(application.className)
                    upsertState(id: application.id)
                }
                continue
            }

            if let declaration = parseStateDeclaration(line) {
                upsertState(id: declaration.id, label: declaration.label, kind: declaration.kind)
                continue
            }
        }

        while let builder = compositeStack.popLast() {
            composites.append(builder.build())
        }

        let states = stateOrder.compactMap { id -> StateNode? in
            guard let state = statesById[id] else { return nil }
            return StateNode(id: state.id, label: state.label, kind: state.kind, classes: classApplications[id] ?? state.classes)
        }

        return StateDiagram(
            direction: direction,
            states: states,
            transitions: transitions,
            notes: notes,
            composites: composites,
            classDefs: classDefs,
            accessibilityTitle: accessibilityTitle,
            accessibilityDescription: accessibilityDescription
        )
    }

    private static func parseAccessibilityDirective(_ line: String, keyword: String) -> String? {
        let colonPrefix = "\(keyword):"
        if let value = line.strippingPrefix(colonPrefix) {
            return MermaidTextUtils.normalizeLabel(value)
        }
        if let value = line.strippingPrefix("\(keyword) ") {
            return MermaidTextUtils.normalizeLabel(value)
        }
        return nil
    }

    private final class StateCompositeBuilder {
        let id: String
        let label: String?
        var direction: FlowDirection?
        var stateIds: Set<String> = []
        var regions: [Int] = []
        var children: [StateComposite] = []

        init(id: String, label: String?) {
            self.id = id
            self.label = label
        }

        func build() -> StateComposite {
            StateComposite(
                id: id,
                label: label,
                direction: direction,
                stateIds: Array(stateIds.sorted()),
                regions: regions,
                children: children
            )
        }
    }

    private static func expandStatements(lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("note ") {
                result.append(line)
                continue
            }
            result.append(contentsOf: splitStatements(in: line))
        }
        return result
    }

    private static func splitStatements(in line: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var inDoubleQuote = false
        var index = line.startIndex

        while index < line.endIndex {
            let char = line[index]
            if char == "\"" {
                inDoubleQuote.toggle()
                current.append(char)
                index = line.index(after: index)
                continue
            }

            if char == ";", !inDoubleQuote, !isEntitySemicolon(in: line, at: index) {
                statements.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index = line.index(after: index)
        }

        statements.append(current)
        return statements
    }

    private static func isEntitySemicolon(in line: String, at semicolon: String.Index) -> Bool {
        guard semicolon > line.startIndex else { return false }
        var index = line.index(before: semicolon)
        while true {
            let char = line[index]
            if char == "#" || char == "&" {
                return true
            }
            if !char.isLetter && !char.isNumber {
                return false
            }
            if index == line.startIndex {
                return false
            }
            index = line.index(before: index)
        }
    }

    private struct ActiveStateNote {
        let position: StateNotePosition
        let stateId: String
        var lines: [String]
    }

    private struct StateDeclaration {
        let id: String
        let label: String?
        let kind: StateNodeKind
    }

    private static func parseCompositeStart(_ line: String) -> (id: String, label: String?)? {
        guard line.hasSuffix("{") else { return nil }
        let prefix = line.dropLast().trimmingCharacters(in: .whitespaces)
        guard let rest = prefix.strippingPrefix("state ") else { return nil }
        if let declaration = parseStateDeclaration(rest) {
            return (declaration.id, declaration.label)
        }
        return (rest, nil)
    }

    private static func parseStateDeclaration(_ line: String) -> StateDeclaration? {
        if let rest = line.strippingPrefix("state ") {
            if rest.contains("<<choice>>") {
                return StateDeclaration(
                    id: rest.replacingOccurrences(of: "<<choice>>", with: "")
                        .trimmingCharacters(in: .whitespaces),
                    label: nil,
                    kind: .choice
                )
            }
            if rest.contains("<<fork>>") {
                return StateDeclaration(
                    id: rest.replacingOccurrences(of: "<<fork>>", with: "")
                        .trimmingCharacters(in: .whitespaces),
                    label: nil,
                    kind: .fork
                )
            }
            if rest.contains("<<join>>") {
                return StateDeclaration(
                    id: rest.replacingOccurrences(of: "<<join>>", with: "")
                        .trimmingCharacters(in: .whitespaces),
                    label: nil,
                    kind: .join
                )
            }
            if rest.hasPrefix("\"") {
                let afterOpeningQuote = rest.index(after: rest.startIndex)
                if let closingQuote = rest[afterOpeningQuote...].firstIndex(of: "\"") {
                    let label = String(rest[afterOpeningQuote..<closingQuote])
                    let suffix = rest[rest.index(after: closingQuote)...].trimmingCharacters(in: .whitespaces)
                    if let id = suffix.strippingPrefix("as ")?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
                        return StateDeclaration(
                            id: id,
                            label: MermaidTextUtils.normalizeLabel(label),
                            kind: .normal
                        )
                    }
                }
            }
            return StateDeclaration(id: rest, label: nil, kind: .normal)
        }

        if let colon = line.firstIndex(of: ":") {
            let id = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let label = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, !label.isEmpty {
                return StateDeclaration(
                    id: id,
                    label: MermaidTextUtils.normalizeLabel(label),
                    kind: .normal
                )
            }
        }

        if !line.contains(" "), !line.contains("-->") {
            return StateDeclaration(id: line, label: nil, kind: .normal)
        }
        return nil
    }

    private struct ParsedEndpoint {
        let endpoint: StateEndpoint
        let classApplication: (id: String, className: String)?
    }

    private struct ParsedTransition {
        let from: StateEndpoint
        let to: StateEndpoint
        let label: String?
        let classApplications: [(id: String, className: String)]
    }

    private static func parseTransition(_ line: String) -> ParsedTransition? {
        guard let arrowRange = line.range(of: "-->") else { return nil }
        let left = String(line[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rightAndLabel = String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let split = splitTransitionTargetAndLabel(rightAndLabel)
        let right = split.target
        guard !left.isEmpty, !right.isEmpty else { return nil }
        let label = split.label.map { MermaidTextUtils.normalizeLabel($0.trimmingCharacters(in: .whitespaces)) }
        let from = parseEndpoint(left)
        let to = parseEndpoint(right)
        let classApplications = [from.classApplication, to.classApplication].compactMap { $0 }
        return ParsedTransition(
            from: from.endpoint,
            to: to.endpoint,
            label: label?.isEmpty == true ? nil : label,
            classApplications: classApplications
        )
    }

    private static func splitTransitionTargetAndLabel(_ text: String) -> (target: String, label: String?) {
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == ":" {
                let prevIsColon = index > text.startIndex && text[text.index(before: index)] == ":"
                let nextIndex = text.index(after: index)
                let nextIsColon = nextIndex < text.endIndex && text[nextIndex] == ":"
                if !prevIsColon, !nextIsColon {
                    let target = String(text[..<index]).trimmingCharacters(in: .whitespaces)
                    let label = String(text[nextIndex...]).trimmingCharacters(in: .whitespaces)
                    return (target, label)
                }
            }
            index = text.index(after: index)
        }
        return (text.trimmingCharacters(in: .whitespaces), nil)
    }

    private static func parseEndpoint(_ raw: String) -> ParsedEndpoint {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let stateId: String
        let className: String?
        if let classRange = trimmed.range(of: ":::") {
            stateId = String(trimmed[..<classRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let classStart = classRange.upperBound
            className = String(trimmed[classStart...]).trimmingCharacters(in: .whitespaces)
        } else {
            stateId = trimmed
            className = nil
        }

        if stateId == "[*]" {
            return ParsedEndpoint(endpoint: .terminal, classApplication: nil)
        }
        let application = className.flatMap { name -> (id: String, className: String)? in
            name.isEmpty ? nil : (stateId, name)
        }
        return ParsedEndpoint(endpoint: .state(stateId), classApplication: application)
    }

    private static func parseNoteStart(_ line: String) -> (position: StateNotePosition, stateId: String)? {
        guard let rest = line.strippingPrefix("note ") else { return nil }
        for token in ["right of", "left of"] {
            if let value = rest.strippingPrefix("\(token) ") {
                let position: StateNotePosition = token == "right of" ? .rightOf : .leftOf
                return (position, value.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func parseInlineNote(_ line: String) -> StateDiagramNote? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let prefix = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard let note = parseNoteStart(prefix) else { return nil }
        let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return StateDiagramNote(stateId: note.stateId, position: note.position, text: MermaidTextUtils.normalizeLabel(text))
    }

    private static func parseClassDef(_ line: String) -> (String, [String: String])? {
        guard let rest = line.strippingPrefix("classDef ") else { return nil }
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        var props: [String: String] = [:]
        for pair in parts[1].split(separator: ",") {
            let kv = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";")) }
            if kv.count == 2 { props[kv[0]] = kv[1] }
        }
        return (parts[0], props)
    }

    private static func parseClassApplication(_ line: String) -> ([String], String)? {
        guard let rest = line.strippingPrefix("class ") else { return nil }
        guard let separator = rest.lastIndex(of: " ") else { return nil }
        let idsRaw = String(rest[..<separator])
        let className = String(rest[rest.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !className.isEmpty else { return nil }
        let ids = idsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (ids, className)
    }
}
