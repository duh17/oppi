import Foundation

// MARK: - Class diagram types
//
// `MermaidNode.swift` is phase-locked to the Phase 1 owner, so the
// `classDiagram` AST lives here until the integrator hook adds
// `case classDiagram(ClassDiagram)` to `MermaidDiagram` and dispatches
// `MermaidClassParser.parse(lines:)` from the shared parser / renderer.

/// Class diagram AST (Mermaid `classDiagram`).
///
/// Spec source (pinned): https://github.com/mermaid-js/mermaid/blob/mermaid%4011.17.0/packages/mermaid/src/docs/syntax/classDiagram.md
struct ClassDiagram: Equatable, Sendable {
    /// Layout direction. Class diagrams accept TB, TD, BT, LR, RL; default is TB.
    let direction: FlowDirection
    /// Classes in first-appearance order.
    let classes: [ClassNode]
    /// Relations in source order.
    let relations: [ClassRelation]

    static let empty = Self(direction: .TB, classes: [], relations: [])
}

/// One UML class box.
///
/// `id` is the token used by relations (`Square` from `class Square~Shape~`).
/// `label` is the optional display label from `class Animal["…"]` or backticks.
/// The generic argument is not part of the class name (spec: drop `~Type~`
/// when referring to the class).
struct ClassNode: Equatable, Sendable {
    let id: String
    var label: String
    var generic: String?
    var stereotype: String?
    var attributes: [ClassMember]
    var methods: [ClassMember]

    /// Name drawn in the top compartment: explicit label, else `Id<Generic>`, else `id`.
    var displayName: String {
        if label != id { return label }
        if let generic, !generic.isEmpty { return "\(id)<\(generic)>" }
        return id
    }
}

/// One attribute or method row.
///
/// Mermaid treats a member as a method when `()` is present; everything else
/// is an attribute. Visibility is the optional leading `+` `-` `#` `~`.
struct ClassMember: Equatable, Sendable {
    let displayText: String
    let visibility: ClassVisibility
    let kind: ClassMemberKind
    let isAbstract: Bool
    let isStatic: Bool
}

enum ClassVisibility: String, Equatable, Sendable {
    case publicAccess = "+"
    case privateAccess = "-"
    case protected = "#"
    case package = "~"
    case unspecified = ""
}

enum ClassMemberKind: Equatable, Sendable {
    case attribute
    case method
}

/// Marker drawn at one end of a relation.
///
/// Built from the spec's two-way grammar: `[Relation Type][Link][Relation Type]`
/// where the type is `<|` / `|>` inheritance, `*` composition, `o` aggregation,
/// `<` / `>` association. Realization is inheritance + a dashed link.
enum ClassRelationEnd: Equatable, Sendable {
    case none
    case inheritance
    case composition
    case aggregation
    case association
}

enum ClassLineStyle: Equatable, Sendable {
    case solid
    case dashed
}

/// A relation between two classes.
///
/// Endpoints are stored in source order. Cardinalities are the quoted
/// multiplicity strings (`"1"`, `"*"`, `"1..*"`).
struct ClassRelation: Equatable, Sendable {
    let from: String
    let to: String
    let fromEnd: ClassRelationEnd
    let toEnd: ClassRelationEnd
    let line: ClassLineStyle
    let label: String?
    let fromCardinality: String?
    let toCardinality: String?
}

// MARK: - Parser

/// Parser for Mermaid class diagrams (`classDiagram`).
///
/// Spec source (pinned): https://github.com/mermaid-js/mermaid/blob/mermaid%4011.17.0/packages/mermaid/src/docs/syntax/classDiagram.md
///
/// v1 scope: class compartments, visibility `+ - # ~`, relations
/// `<|--` `*--` `o--` `-->` `..>` `..|>` `--` (plus reverse / two-way forms
/// from the same grammar), labels, cardinalities, and `<<stereotype>>`.
/// Notes, click/link/callback, and CSS/style statements are accepted and
/// ignored so real-world sources do not crash.
enum MermaidClassParser {

    private enum Block {
        case classBody(String)
        case namespace
    }

    nonisolated static func parse(lines: [String]) -> ClassDiagram {
        var direction: FlowDirection = .TB
        var classesById: [String: ClassNode] = [:]
        var classOrder: [String] = []
        var relations: [ClassRelation] = []
        var stack: [Block] = []

        func register(
            id: String,
            label: String? = nil,
            generic: String? = nil,
            stereotype: String? = nil
        ) -> String {
            if var existing = classesById[id] {
                if let label, existing.label == existing.id {
                    existing.label = label
                }
                if existing.generic == nil, let generic {
                    existing.generic = generic
                }
                if let stereotype {
                    existing.stereotype = stereotype
                }
                classesById[id] = existing
            } else {
                classesById[id] = ClassNode(
                    id: id,
                    label: label ?? id,
                    generic: generic,
                    stereotype: stereotype,
                    attributes: [],
                    methods: []
                )
                classOrder.append(id)
            }
            return id
        }

        func addMember(classId: String, member: ClassMember) {
            _ = register(id: classId)
            guard var node = classesById[classId] else { return }
            switch member.kind {
            case .attribute:
                node.attributes.append(member)
            case .method:
                node.methods.append(member)
            }
            classesById[classId] = node
        }

        func currentClassId() -> String? {
            for block in stack.reversed() {
                if case .classBody(let id) = block { return id }
            }
            return nil
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("%%") { continue }

            // Close the current class body or namespace.
            if line == "}" {
                if !stack.isEmpty { _ = stack.removeLast() }
                continue
            }

            if let classId = currentClassId() {
                if let stereotype = parseBareStereotype(line) {
                    _ = register(id: classId, stereotype: stereotype)
                    continue
                }
                if let member = parseMember(line) {
                    addMember(classId: classId, member: member)
                }
                continue
            }

            if let parsedDirection = parseDirection(line) {
                direction = parsedDirection
                continue
            }

            if isHeaderLine(line) || isIgnoredStatement(line) {
                continue
            }

            if isNamespaceDeclaration(line) {
                if line.hasSuffix("{") {
                    stack.append(.namespace)
                }
                continue
            }

            if let declaration = parseClassDeclaration(line) {
                _ = register(
                    id: declaration.id,
                    label: declaration.label,
                    generic: declaration.generic,
                    stereotype: declaration.stereotype
                )
                for member in declaration.inlineMembers {
                    addMember(classId: declaration.id, member: member)
                }
                if declaration.opensBody {
                    stack.append(.classBody(declaration.id))
                }
                continue
            }

            if let annotation = parseAnnotationLine(line) {
                _ = register(id: annotation.classId, stereotype: annotation.stereotype)
                continue
            }

            if let relation = parseRelation(line) {
                _ = register(id: relation.from)
                _ = register(id: relation.to)
                relations.append(relation)
                continue
            }

            if let colon = parseColonMember(line) {
                addMember(classId: colon.classId, member: colon.member)
                continue
            }
        }

        return ClassDiagram(
            direction: direction,
            classes: classOrder.compactMap { classesById[$0] },
            relations: relations
        )
    }

    // MARK: - Headers / ignored statements

    private static func isHeaderLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower == "classdiagram"
            || lower == "classdiagram-v2"
            || lower.hasPrefix("classdiagram ")
            || lower.hasPrefix("classdiagram-v2 ")
    }

    /// Notes, interaction, and CSS are accepted and dropped (v1).
    private static func isIgnoredStatement(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("note ")
            || lower == "note"
            || lower.hasPrefix("click ")
            || lower.hasPrefix("link ")
            || lower.hasPrefix("callback ")
            || lower.hasPrefix("style ")
            || lower.hasPrefix("classdef ")
            || lower.hasPrefix("cssclass ")
            || lower.hasPrefix("acctitle")
            || lower.hasPrefix("accdescr")
            || lower == "title"
            || lower.hasPrefix("title ")
            || lower.hasPrefix("title:")
    }

    private static func isNamespaceDeclaration(_ line: String) -> Bool {
        line.lowercased().hasPrefix("namespace ")
    }

    private static func parseDirection(_ line: String) -> FlowDirection? {
        let lower = line.lowercased()
        guard lower.hasPrefix("direction ") else { return nil }
        let value = String(line.dropFirst("direction ".count))
            .trimmingCharacters(in: .whitespaces)
        return FlowDirection(rawValue: value)
    }

    // MARK: - Class declarations

    private struct ClassDeclaration {
        let id: String
        let label: String?
        let generic: String?
        let stereotype: String?
        let opensBody: Bool
        let inlineMembers: [ClassMember]
    }

    /// `class Animal`, `class Animal["label"]`, `class Square~Shape~{`, …
    private static func parseClassDeclaration(_ line: String) -> ClassDeclaration? {
        guard let rest = strippingClassKeyword(line) else { return nil }
        var scanner = rest.trimmingCharacters(in: .whitespaces)
        guard let name = consumeClassName(&scanner) else { return nil }

        var generic = name.generic
        var label = name.label
        var stereotype: String?
        var opensBody = false
        var inlineMembers: [ClassMember] = []

        skipTrivia(&scanner)
        while !scanner.isEmpty {
            skipTrivia(&scanner)
            if scanner.hasPrefix("~"), generic == nil {
                if let parsed = consumeGeneric(&scanner) {
                    generic = parsed
                    continue
                }
            }
            if scanner.hasPrefix("[") {
                if let parsed = consumeBracketLabel(&scanner) {
                    label = parsed
                    continue
                }
                break
            }
            if scanner.hasPrefix("<<") {
                if let parsed = consumeStereotype(&scanner) {
                    stereotype = parsed
                    continue
                }
                break
            }
            if scanner.hasPrefix(":::") {
                consumeCssClass(&scanner)
                continue
            }
            if scanner.hasPrefix("{") {
                scanner.removeFirst()
                opensBody = true
                let inner = scanner.trimmingCharacters(in: .whitespaces)
                if let close = inner.firstIndex(of: "}") {
                    let body = String(inner[..<close]).trimmingCharacters(in: .whitespaces)
                    if !body.isEmpty, parseBareStereotype(body) == nil, let member = parseMember(body) {
                        inlineMembers.append(member)
                    } else if let stereo = parseBareStereotype(body) {
                        stereotype = stereo
                    }
                    opensBody = false
                } else if !inner.isEmpty {
                    if let stereo = parseBareStereotype(inner) {
                        stereotype = stereo
                    } else if let member = parseMember(inner) {
                        inlineMembers.append(member)
                    }
                }
                break
            }
            break
        }

        return ClassDeclaration(
            id: name.id,
            label: label,
            generic: generic,
            stereotype: stereotype,
            opensBody: opensBody,
            inlineMembers: inlineMembers
        )
    }

    /// `class` keyword followed by a separator, not an identifier like `classA`.
    private static func strippingClassKeyword(_ line: String) -> String? {
        guard line.hasPrefix("class") else { return nil }
        let rest = String(line.dropFirst(5))
        guard let first = rest.first else { return "" }
        if first.isWhitespace || first == "`" || first == "{" || first == "~" || first == "[" {
            return rest
        }
        return nil
    }

    private struct ParsedName {
        let id: String
        let label: String?
        let generic: String?
    }

    private static func consumeClassName(_ scanner: inout String) -> ParsedName? {
        skipTrivia(&scanner)
        guard !scanner.isEmpty else { return nil }

        if scanner.hasPrefix("`") {
            scanner.removeFirst()
            guard let close = scanner.firstIndex(of: "`") else { return nil }
            let id = String(scanner[..<close])
            scanner = String(scanner[scanner.index(after: close)...])
            guard !id.isEmpty else { return nil }
            return ParsedName(id: id, label: id, generic: nil)
        }

        var id = ""
        while let char = scanner.first, isNameChar(char) {
            id.append(char)
            scanner.removeFirst()
        }
        guard !id.isEmpty else { return nil }

        var generic: String?
        if scanner.hasPrefix("~") {
            generic = consumeGeneric(&scanner)
        }
        return ParsedName(id: id, label: nil, generic: generic)
    }

    private static func consumeGeneric(_ scanner: inout String) -> String? {
        guard scanner.hasPrefix("~") else { return nil }
        scanner.removeFirst()
        guard let close = scanner.firstIndex(of: "~") else { return nil }
        let value = String(scanner[..<close])
        scanner = String(scanner[scanner.index(after: close)...])
        return value
    }

    private static func consumeBracketLabel(_ scanner: inout String) -> String? {
        guard scanner.hasPrefix("[") else { return nil }
        scanner.removeFirst()
        guard let close = scanner.firstIndex(of: "]") else { return nil }
        let inner = String(scanner[..<close])
        scanner = String(scanner[scanner.index(after: close)...])
        let normalized = MermaidTextUtils.normalizeLabel(inner)
        return normalized.isEmpty ? nil : normalized
    }

    private static func consumeStereotype(_ scanner: inout String) -> String? {
        guard scanner.hasPrefix("<<") else { return nil }
        guard let close = scanner.range(of: ">>") else { return nil }
        let inner = String(scanner[scanner.index(scanner.startIndex, offsetBy: 2)..<close.lowerBound])
        scanner = String(scanner[close.upperBound...])
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func consumeCssClass(_ scanner: inout String) {
        guard scanner.hasPrefix(":::") else { return }
        scanner.removeFirst(3)
        while let char = scanner.first, !char.isWhitespace, char != "{", char != "<" {
            scanner.removeFirst()
        }
    }

    private static func parseBareStereotype(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<<"), trimmed.hasSuffix(">>"), trimmed.count >= 4 else {
            return nil
        }
        let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }

    private struct AnnotationLine {
        let classId: String
        let stereotype: String
    }

    /// Separate-line annotation: `<<interface>> Shape`.
    private static func parseAnnotationLine(_ line: String) -> AnnotationLine? {
        var scanner = line
        guard let stereotype = consumeStereotype(&scanner) else { return nil }
        skipTrivia(&scanner)
        guard let name = consumeClassName(&scanner), !name.id.isEmpty else { return nil }
        return AnnotationLine(classId: name.id, stereotype: stereotype)
    }

    // MARK: - Members

    private struct ColonMember {
        let classId: String
        let member: ClassMember
    }

    /// `BankAccount : +String owner` / `Animal: +isMammal()`.
    private static func parseColonMember(_ line: String) -> ColonMember? {
        let (before, after) = splitLabel(line)
        guard let after else { return nil }
        var scanner = before
        guard let name = consumeClassName(&scanner) else { return nil }
        skipTrivia(&scanner)
        guard scanner.isEmpty else { return nil }
        guard let member = parseMember(after) else { return nil }
        return ColonMember(classId: name.id, member: member)
    }

    /// Parse one attribute or method. `()` decides the compartment.
    private static func parseMember(_ line: String) -> ClassMember? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if parseBareStereotype(text) != nil { return nil }

        var visibility: ClassVisibility = .unspecified
        if let first = text.first, let parsed = ClassVisibility(rawValue: String(first)), parsed != .unspecified {
            visibility = parsed
            text.removeFirst()
        }

        var isAbstract = false
        var isStatic = false
        if text.hasSuffix("$") {
            isStatic = true
            text.removeLast()
        } else if text.hasSuffix("*") {
            isAbstract = true
            text.removeLast()
        }

        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        let kind: ClassMemberKind = text.contains("(") && text.contains(")") ? .method : .attribute
        let displayCore = parseGenericTypes(text)
        let displayText = visibility.rawValue + displayCore
        return ClassMember(
            displayText: displayText,
            visibility: visibility,
            kind: kind,
            isAbstract: isAbstract,
            isStatic: isStatic
        )
    }

    /// Convert mermaid `~Type~` generics to `Type` angle brackets.
    /// Spec: `List~int~` → `List<int>`, `List~List~int~~` → `List<List<int>>`.
    private static func parseGenericTypes(_ input: String) -> String {
        var chars = Array(input)
        var first = chars.firstIndex(of: "~")
        var last = chars.lastIndex(of: "~")
        while let start = first, let end = last, start != end {
            chars[start] = "<"
            chars[end] = ">"
            first = chars.firstIndex(of: "~")
            last = chars.lastIndex(of: "~")
        }
        return String(chars)
    }

    // MARK: - Relations

    /// `[classA] "card1" [Arrow] "card2" [ClassB]:LabelText`
    private static func parseRelation(_ line: String) -> ClassRelation? {
        let (beforeLabel, labelPart) = splitLabel(line)
        var scanner = beforeLabel
        guard let first = consumeClassName(&scanner) else { return nil }
        skipTrivia(&scanner)
        guard !scanner.isEmpty else { return nil }

        // Lollipop interfaces (`()--` / `--()`) are out of v1; skip the line.
        if scanner.contains("()--") || scanner.contains("--()") {
            return nil
        }

        var fromCardinality: String?
        if scanner.hasPrefix("\"") {
            fromCardinality = consumeQuoted(&scanner)
            skipTrivia(&scanner)
        }

        guard let arrow = consumeArrow(&scanner) else { return nil }
        skipTrivia(&scanner)

        var toCardinality: String?
        if scanner.hasPrefix("\"") {
            toCardinality = consumeQuoted(&scanner)
            skipTrivia(&scanner)
        }

        guard let second = consumeClassName(&scanner), !second.id.isEmpty else { return nil }

        return ClassRelation(
            from: first.id,
            to: second.id,
            fromEnd: arrow.fromEnd,
            toEnd: arrow.toEnd,
            line: arrow.line,
            label: relationLabel(labelPart),
            fromCardinality: fromCardinality,
            toCardinality: toCardinality
        )
    }

    private struct ParsedArrow {
        let fromEnd: ClassRelationEnd
        let toEnd: ClassRelationEnd
        let line: ClassLineStyle
    }

    /// Spec grammar: `[Relation Type][Link][Relation Type]`.
    ///
    /// Types: `<|` inheritance, `*` composition, `o` aggregation, `<`/`>` association, `|>` realization/inheritance.
    /// Links: `--` solid, `..` dashed.
    private static func consumeArrow(_ scanner: inout String) -> ParsedArrow? {
        let fromEnd: ClassRelationEnd
        if scanner.hasPrefix("<|") {
            fromEnd = .inheritance
            scanner.removeFirst(2)
        } else if scanner.hasPrefix("*") {
            fromEnd = .composition
            scanner.removeFirst()
        } else if scanner.hasPrefix("o") {
            fromEnd = .aggregation
            scanner.removeFirst()
        } else if scanner.hasPrefix("<") {
            fromEnd = .association
            scanner.removeFirst()
        } else {
            fromEnd = .none
        }

        let line: ClassLineStyle
        if scanner.hasPrefix("--") {
            line = .solid
            scanner.removeFirst(2)
        } else if scanner.hasPrefix("..") {
            line = .dashed
            scanner.removeFirst(2)
        } else {
            return nil
        }

        let toEnd: ClassRelationEnd
        if scanner.hasPrefix("|>") {
            toEnd = .inheritance
            scanner.removeFirst(2)
        } else if scanner.hasPrefix("*") {
            toEnd = .composition
            scanner.removeFirst()
        } else if scanner.hasPrefix("o") {
            toEnd = .aggregation
            scanner.removeFirst()
        } else if scanner.hasPrefix(">") {
            toEnd = .association
            scanner.removeFirst()
        } else {
            toEnd = .none
        }

        return ParsedArrow(fromEnd: fromEnd, toEnd: toEnd, line: line)
    }

    private static func consumeQuoted(_ scanner: inout String) -> String? {
        guard scanner.hasPrefix("\"") else { return nil }
        scanner.removeFirst()
        guard let close = scanner.firstIndex(of: "\"") else { return nil }
        let inner = String(scanner[..<close])
        scanner = String(scanner[scanner.index(after: close)...])
        return inner
    }

    private static func relationLabel(_ labelPart: String?) -> String? {
        guard let part = labelPart?.trimmingCharacters(in: .whitespaces), !part.isEmpty else {
            return nil
        }
        let normalized = MermaidTextUtils.normalizeLabel(part)
        return normalized.isEmpty ? nil : normalized
    }

    /// Split at the first `:` that is not inside quotes or backticks.
    private static func splitLabel(_ line: String) -> (before: String, label: String?) {
        var inDoubleQuote = false
        var inBacktick = false
        for (offset, char) in line.enumerated() {
            if char == "`" { inBacktick.toggle() }
            if char == "\"", !inBacktick { inDoubleQuote.toggle() }
            if char == ":", !inDoubleQuote, !inBacktick {
                let index = line.index(line.startIndex, offsetBy: offset)
                return (String(line[..<index]), String(line[line.index(after: index)...]))
            }
        }
        return (line, nil)
    }

    // MARK: - Characters

    private static func isNameChar(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_" || char == "-"
    }

    private static func skipTrivia(_ scanner: inout String) {
        while let char = scanner.first, char.isWhitespace {
            scanner.removeFirst()
        }
    }
}
