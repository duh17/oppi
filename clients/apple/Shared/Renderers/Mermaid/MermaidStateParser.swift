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
        var currentNote: (position: StateNotePosition, stateId: String, lines: [String])?
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
            transitions.append(StateTransition(from: from, to: to, label: label))
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
                        text: MermaidTextUtils.normalizeBrTags(note.lines.joined(separator: "\n"))
                    ))
                    currentNote = nil
                } else {
                    note.lines.append(line)
                    currentNote = note
                }
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
                currentNote = (noteStart.position, noteStart.stateId, [])
                continue
            }

            if let transition = parseTransition(line) {
                addTransition(from: transition.from, to: transition.to, label: transition.label)
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
            classDefs: classDefs
        )
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
            for part in line.split(separator: ";", omittingEmptySubsequences: false) {
                result.append(String(part))
            }
        }
        return result
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

    private static func parseStateDeclaration(_ line: String) -> (id: String, label: String?, kind: StateNodeKind)? {
        if let rest = line.strippingPrefix("state ") {
            if rest.contains("<<choice>>") {
                return (rest.replacingOccurrences(of: "<<choice>>", with: "").trimmingCharacters(in: .whitespaces), nil, .choice)
            }
            if rest.contains("<<fork>>") {
                return (rest.replacingOccurrences(of: "<<fork>>", with: "").trimmingCharacters(in: .whitespaces), nil, .fork)
            }
            if rest.contains("<<join>>") {
                return (rest.replacingOccurrences(of: "<<join>>", with: "").trimmingCharacters(in: .whitespaces), nil, .join)
            }
            if rest.hasPrefix("\"") {
                let afterOpeningQuote = rest.index(after: rest.startIndex)
                if let closingQuote = rest[afterOpeningQuote...].firstIndex(of: "\"") {
                    let label = String(rest[afterOpeningQuote..<closingQuote])
                    let suffix = rest[rest.index(after: closingQuote)...].trimmingCharacters(in: .whitespaces)
                    if let id = suffix.strippingPrefix("as ")?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
                        return (id, MermaidTextUtils.normalizeBrTags(label), .normal)
                    }
                }
            }
            return (rest, nil, .normal)
        }

        if let colon = line.firstIndex(of: ":") {
            let id = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let label = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, !label.isEmpty {
                return (id, MermaidTextUtils.normalizeBrTags(label), .normal)
            }
        }

        if !line.contains(" "), !line.contains("-->") {
            return (line, nil, .normal)
        }
        return nil
    }

    private static func parseTransition(_ line: String) -> (from: StateEndpoint, to: StateEndpoint, label: String?)? {
        guard let arrowRange = line.range(of: "-->") else { return nil }
        let left = String(line[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rightAndLabel = String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let parts = rightAndLabel.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let right = parts.first?.trimmingCharacters(in: .whitespaces), !left.isEmpty, !right.isEmpty else { return nil }
        let label = parts.count > 1 ? MermaidTextUtils.normalizeBrTags(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (parseEndpoint(left), parseEndpoint(right), label?.isEmpty == true ? nil : label)
    }

    private static func parseEndpoint(_ raw: String) -> StateEndpoint {
        let withoutClass = raw.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        if withoutClass == "[*]" { return .terminal }
        return .state(withoutClass.trimmingCharacters(in: .whitespaces))
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
        return StateDiagramNote(stateId: note.stateId, position: note.position, text: MermaidTextUtils.normalizeBrTags(text))
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
