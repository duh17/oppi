import Foundation

// MARK: - ER diagram types
//
// `MermaidNode.swift` is phase-locked to the Phase 1 owner, so the `erDiagram`
// AST lives here until the integrator hook adds `case er(ERDiagram)` to
// `MermaidDiagram` and dispatches `MermaidERParser.parse(lines:)` from
// `MermaidParser.parse(_:)` / `MermaidFlowchartRenderer.layout`.

/// Entity–relationship diagram AST (Mermaid `erDiagram`).
///
/// Spec source (pinned): https://github.com/mermaid-js/mermaid/blob/mermaid%4011.17.0/packages/mermaid/src/docs/syntax/entityRelationshipDiagram.md
struct ERDiagram: Equatable, Sendable {
    /// Layout direction. The ER spec supports TB, BT, LR, RL; default is TB.
    let direction: FlowDirection
    /// Entities in first-appearance order.
    let entities: [EREntity]
    /// Relationships in source order.
    let relationships: [ERRelationship]

    static let empty = Self(direction: .TB, entities: [], relationships: [])
}

/// An entity box. `name` is the identifier used by relationship statements;
/// `alias` (from `p[Person]`) is shown instead of the name when present.
struct EREntity: Equatable, Sendable {
    let name: String
    /// Filled in when a later declaration supplies `[alias]`.
    var alias: String?
    var attributes: [ERAttribute]

    var displayName: String { alias ?? name }
}

/// A `type name` attribute row, with optional key constraints and comment.
struct ERAttribute: Equatable, Sendable {
    let type: String
    let name: String
    /// `PK`, `FK`, `UK` — multiple constraints allowed (`PK, FK`).
    let keys: [ERAttributeKey]
    let comment: String?
}

enum ERAttributeKey: String, Equatable, Sendable, CaseIterable {
    case PK, FK, UK
}

enum ERCardinality: Equatable, Sendable {
    /// `||` — exactly one.
    case exactlyOne
    /// `|o` left / `o|` right — zero or one.
    case zeroOrOne
    /// `}|` left / `|{` right — one or more.
    case oneOrMore
    /// `}o` left / `o{` right — zero or more.
    case zeroOrMore

    /// Marker as written at the first entity's end of the line.
    var leftMarker: String {
        switch self {
        case .exactlyOne: return "||"
        case .zeroOrOne: return "|o"
        case .oneOrMore: return "}|"
        case .zeroOrMore: return "}o"
        }
    }

    /// Marker as written at the second entity's end of the line.
    var rightMarker: String {
        switch self {
        case .exactlyOne: return "||"
        case .zeroOrOne: return "o|"
        case .oneOrMore: return "|{"
        case .zeroOrMore: return "o{"
        }
    }

    /// Normalize any written marker (either side) to a cardinality.
    static func fromMarker(_ marker: String) -> ERCardinality? {
        switch marker {
        case "||": return .exactlyOne
        case "|o", "o|": return .zeroOrOne
        case "}|", "|{": return .oneOrMore
        case "}o", "o{": return .zeroOrMore
        default: return nil
        }
    }
}

/// A relationship between two entities.
///
/// `fromCardinality` is the marker at the first entity's end, `toCardinality`
/// the marker at the second entity's end. Identifying relationships (`--`)
/// draw solid lines; non-identifying (`..`) draw dashed lines.
struct ERRelationship: Equatable, Sendable {
    let from: String
    let to: String
    let fromCardinality: ERCardinality
    let toCardinality: ERCardinality
    let identifying: Bool
    let label: String?
}

// MARK: - Parser

/// Parser for Mermaid ER diagrams (`erDiagram`).
///
/// Spec source (pinned): https://github.com/mermaid-js/mermaid/blob/mermaid%4011.17.0/packages/mermaid/src/docs/syntax/entityRelationshipDiagram.md
///
/// v1 scope: entities (quoted names, `[alias]`, `:::class` suffixes),
/// crow's-foot relationships with symbol and word-alias cardinalities,
/// identifying vs non-identifying lines, attribute blocks with keys and
/// comments, `direction`, and `%%` comments. Subgraph, style, and class
/// statements are accepted and ignored so real-world sources do not crash.
enum MermaidERParser {

    nonisolated static func parse(lines: [String]) -> ERDiagram {
        var direction: FlowDirection = .TB
        var entitiesById: [String: EREntity] = [:]
        var entityOrder: [String] = []
        var relationships: [ERRelationship] = []
        var blockEntityName: String?

        func register(_ endpoint: Endpoint) -> String {
            if var existing = entitiesById[endpoint.name] {
                if existing.alias == nil {
                    existing.alias = endpoint.alias
                    entitiesById[endpoint.name] = existing
                }
            } else {
                entitiesById[endpoint.name] = EREntity(
                    name: endpoint.name,
                    alias: endpoint.alias,
                    attributes: []
                )
                entityOrder.append(endpoint.name)
            }
            return endpoint.name
        }

        for rawLine in lines {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Inside an attribute block: `}` closes, anything else is an attribute.
            if let currentName = blockEntityName {
                if line == "}" {
                    blockEntityName = nil
                } else if let attribute = parseAttribute(line),
                          var entity = entitiesById[currentName] {
                    entity.attributes.append(attribute)
                    entitiesById[currentName] = entity
                }
                continue
            }

            if line.hasSuffix("{"), !line.lowercased().hasPrefix("subgraph") {
                let head = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                if let match = parseEndpoint(head), !match.endpoint.name.isEmpty {
                    blockEntityName = register(match.endpoint)
                } else {
                    // Unparsable block head — consume the block without crashing.
                    blockEntityName = ""
                }
                continue
            }

            if isDirectionStatement(line) {
                if let parsedDirection = parseDirectionValue(line) {
                    direction = parsedDirection
                }
                continue
            }

            if isIgnoredStatement(line) { continue }

            if let relationship = parseRelationship(line) {
                register(Endpoint(name: relationship.from, alias: nil))
                register(Endpoint(name: relationship.to, alias: nil))
                relationships.append(relationship)
                continue
            }

            // A lone endpoint declares an entity with no relationships.
            if let match = parseEndpoint(line), !match.endpoint.name.isEmpty {
                _ = register(match.endpoint)
            }
        }

        return ERDiagram(
            direction: direction,
            entities: entityOrder.compactMap { entitiesById[$0] },
            relationships: relationships
        )
    }

    // MARK: - Comments

    /// Remove `%%` comment from a line, preserving `%%` inside double quotes.
    private static func stripComment(_ line: String) -> String {
        var inDoubleQuote = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\"" { inDoubleQuote.toggle() }
            if char == "%", !inDoubleQuote {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "%" {
                    return String(line[..<index])
                }
            }
            index = line.index(after: index)
        }
        return line
    }

    // MARK: - Statements

    /// Mermaid treats `direction` as a keyword, case-insensitive. Consume the
    /// whole statement so `direction lr` cannot become an entity named `direction`.
    private static func isDirectionStatement(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower == "direction" || lower.hasPrefix("direction ")
    }

    private static func parseDirectionValue(_ line: String) -> FlowDirection? {
        let value = String(line.dropFirst("direction".count))
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        let token = value.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return FlowDirection(rawValue: token)
    }

    /// Statements accepted but not rendered in v1: styling, classes, subgraphs.
    private static func isIgnoredStatement(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower == "end"
            || lower == "erdiagram"
            || lower.hasPrefix("erdiagram ")
            || lower.hasPrefix("subgraph")
            || lower.hasPrefix("style ")
            || lower.hasPrefix("classdef ")
            || lower.hasPrefix("class ")
            || lower == "title"
            || lower.hasPrefix("title ")
            || lower.hasPrefix("title:")
    }

    // MARK: - Relationships

    private struct Endpoint {
        let name: String
        let alias: String?
    }

    private struct ParsedRelationship {
        let from: String
        let to: String
        let fromCardinality: ERCardinality
        let toCardinality: ERCardinality
        let identifying: Bool
        let label: String?
    }

    /// Parse `first-entity relationship second-entity : label`.
    ///
    /// The relationship is either the 6-character crow's-foot symbol
    /// (`||--o{`, `}|..|{`, …) or word aliases
    /// (`CAR 1 to zero or more NAMED-DRIVER`).
    private static func parseRelationship(_ line: String) -> ERRelationship? {
        let (beforeLabel, labelPart) = splitLabel(line)
        guard let first = parseEndpoint(beforeLabel) else { return nil }
        var remainder = first.remainder.trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }

        // Symbol form: MARKER (--|..) MARKER, immediately followed by entity 2.
        let chars = Array(remainder)
        if chars.count >= 6,
           let fromCardinality = ERCardinality.fromMarker(String(chars[0...1])),
           let identity = identity(fromSymbol: String(chars[2...3])),
           let toCardinality = ERCardinality.fromMarker(String(chars[4...5])) {
            let rest = String(chars[6...]).trimmingCharacters(in: .whitespaces)
            guard let second = parseEndpoint(rest), !second.endpoint.name.isEmpty else { return nil }
            return ERRelationship(
                from: first.endpoint.name,
                to: second.endpoint.name,
                fromCardinality: fromCardinality,
                toCardinality: toCardinality,
                identifying: identity,
                label: label(from: labelPart)
            )
        }

        // Word-alias form: phrase [optionally] to phrase ENTITY.
        guard let (fromCardinality, afterFirst) = matchCardinalityPhrase(remainder) else { return nil }
        let afterTo = afterFirst.trimmingCharacters(in: .whitespaces)
        let identifying: Bool
        var tail = afterTo
        if tail.lowercased().hasPrefix("optionally to") {
            identifying = false
            tail = String(tail.dropFirst("optionally to".count))
        } else if tail.lowercased().hasPrefix("to") {
            identifying = true
            tail = String(tail.dropFirst("to".count))
        } else {
            return nil
        }
        tail = tail.trimmingCharacters(in: .whitespaces)
        guard let (toCardinality, afterSecond) = matchCardinalityPhrase(tail) else { return nil }
        guard let second = parseEndpoint(afterSecond), !second.endpoint.name.isEmpty else { return nil }

        return ERRelationship(
            from: first.endpoint.name,
            to: second.endpoint.name,
            fromCardinality: fromCardinality,
            toCardinality: toCardinality,
            identifying: identifying,
            label: label(from: labelPart)
        )
    }

    private static func identity(fromSymbol symbol: String) -> Bool? {
        switch symbol {
        case "--": return true   // identifying (solid)
        case "..": return false  // non-identifying (dashed)
        default: return nil
        }
    }

    private static func label(from labelPart: String?) -> String? {
        guard let part = labelPart?.trimmingCharacters(in: .whitespaces), !part.isEmpty else { return nil }
        let normalized = MermaidTextUtils.normalizeLabel(part)
        return normalized.isEmpty ? nil : normalized
    }

    /// Split at the first lone `:` that is not inside double quotes.
    /// `:::` class suffixes are skipped; relationship labels use a single colon.
    private static func splitLabel(_ line: String) -> (before: String, label: String?) {
        var inDoubleQuote = false
        let chars = Array(line)
        for (offset, char) in chars.enumerated() {
            if char == "\"" { inDoubleQuote.toggle() }
            guard char == ":", !inDoubleQuote else { continue }
            let adjacentToColon =
                (offset > 0 && chars[offset - 1] == ":")
                || (offset + 1 < chars.count && chars[offset + 1] == ":")
            if adjacentToColon { continue }
            let index = line.index(line.startIndex, offsetBy: offset)
            return (String(line[..<index]), String(line[line.index(after: index)...]))
        }
        return (line, nil)
    }

    /// Word cardinality aliases from the spec, longest first.
    private static let cardinalityPhrases: [(phrase: String, cardinality: ERCardinality)] = [
        ("zero or one", .zeroOrOne),
        ("one or zero", .zeroOrOne),
        ("zero or more", .zeroOrMore),
        ("zero or many", .zeroOrMore),
        ("one or more", .oneOrMore),
        ("one or many", .oneOrMore),
        ("only one", .exactlyOne),
        ("many(1)", .oneOrMore),
        ("many(0)", .zeroOrMore),
        ("1+", .oneOrMore),
        ("0+", .zeroOrMore),
        ("1", .exactlyOne),
    ]

    private static func matchCardinalityPhrase(_ text: String) -> (ERCardinality, remainder: String)? {
        let lower = text.lowercased()
        for entry in cardinalityPhrases {
            if lower.hasPrefix(entry.phrase) {
                let consumed = String(text.prefix(entry.phrase.count))
                let remainder = String(text.dropFirst(consumed.count))
                    .trimmingCharacters(in: .whitespaces)
                return (entry.cardinality, remainder)
            }
        }
        return nil
    }

    // MARK: - Endpoints

    private struct EndpointMatch {
        let endpoint: Endpoint
        let remainder: String
    }

    /// Parse an entity reference: `NAME`, `"quoted name"`, `p[alias]`,
    /// optionally with `:::class` suffixes. Returns the remainder of the line.
    private static func parseEndpoint(_ text: String) -> EndpointMatch? {
        let chars = Array(text)
        var pos = 0
        while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
        guard pos < chars.count else { return nil }

        let name: String
        if chars[pos] == "\"" {
            guard let closing = findClosingQuote(chars, from: pos + 1) else { return nil }
            name = MermaidTextUtils.normalizeLabel(String(chars[(pos + 1)..<closing]))
            pos = closing + 1
        } else {
            let start = pos
            while pos < chars.count, !isEndpointStopChar(chars[pos]) {
                pos += 1
            }
            guard pos > start else { return nil }
            name = String(chars[start..<pos])
        }
        guard !name.isEmpty else { return nil }

        // Optional `[alias]` — `p[Person]` or `a["Customer Account"]`.
        var alias: String?
        if pos < chars.count, chars[pos] == "[" {
            guard let closing = findClosingBracket(chars, from: pos + 1) else { return nil }
            let inner = String(chars[(pos + 1)..<closing])
            alias = MermaidTextUtils.normalizeLabel(inner)
            pos = closing + 1
        }

        // Optional `:::class` suffixes — accepted, not rendered in v1.
        while pos + 2 < chars.count, chars[pos] == ":", chars[pos + 1] == ":", chars[pos + 2] == ":" {
            pos += 3
            while pos < chars.count, isWordChar(chars[pos]) || chars[pos] == "," { pos += 1 }
        }

        // `}` opens an attribute block; do not swallow it as part of the name.
        return EndpointMatch(
            endpoint: Endpoint(name: name, alias: alias),
            remainder: String(chars[pos...])
        )
    }

    /// Characters that terminate an unquoted entity name.
    private static func isEndpointStopChar(_ char: Character) -> Bool {
        char == " " || char == "\t" || char == "|" || char == "}" || char == "[" || char == ":"
    }

    private static func isWordChar(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_" || char == "-"
    }

    private static func findClosingQuote(_ chars: [Character], from start: Int) -> Int? {
        var index = start
        while index < chars.count {
            if chars[index] == "\"" { return index }
            index += 1
        }
        return nil
    }

    private static func findClosingBracket(_ chars: [Character], from start: Int) -> Int? {
        var index = start
        while index < chars.count {
            if chars[index] == "]" { return index }
            index += 1
        }
        return nil
    }

    // MARK: - Attributes

    /// Parse an attribute line inside a block: `type name [PK|FK|UK[, …]] ["comment"]`.
    /// A leading `*` on the name marks a primary key.
    private static func parseAttribute(_ line: String) -> ERAttribute? {
        let tokens = tokenizeAttribute(line)
        guard tokens.count >= 2 else { return nil }

        let type = tokens[0]
        var name = tokens[1]
        guard isValidType(type), isValidName(name) else { return nil }

        var keys: [ERAttributeKey] = []
        if name.hasPrefix("*") {
            name = String(name.dropFirst())
            if !keys.contains(.PK) { keys.append(.PK) }
        }

        // `PK`, `FK`, `UK` tokens may be followed by a trailing quoted comment.
        var comment: String?
        let rest = Array(tokens.dropFirst(2))
        if let commentStart = rest.firstIndex(where: { $0.hasPrefix("\"") }) {
            keys.append(contentsOf: parseKeys(rest[..<commentStart].joined(separator: " ")))
            comment = MermaidTextUtils.normalizeLabel(rest[commentStart...].joined(separator: " "))
        } else {
            keys.append(contentsOf: parseKeys(rest.joined(separator: " ")))
        }

        return ERAttribute(
            type: type,
            name: name,
            keys: keys,
            comment: comment?.isEmpty == true ? nil : comment
        )
    }

    /// Parse key constraints like `PK`, `FK`, or `PK, FK` into deduplicated keys.
    private static func parseKeys(_ text: String) -> [ERAttributeKey] {
        guard !text.isEmpty else { return [] }
        var keys: [ERAttributeKey] = []
        for rawKey in text.split(separator: ",") {
            let key = rawKey.trimmingCharacters(in: .whitespaces).uppercased()
            if let parsed = ERAttributeKey(rawValue: key), !keys.contains(parsed) {
                keys.append(parsed)
            }
        }
        return keys
    }

    /// Split an attribute line into whitespace-separated tokens, keeping
    /// double-quoted spans (including their spaces) as single tokens.
    private static func tokenizeAttribute(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inDoubleQuote = false

        for char in line {
            if char == "\"" {
                inDoubleQuote.toggle()
                current.append(char)
                continue
            }
            if char == " " || char == "\t", !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(char)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Attribute types start with a letter and may contain digits, hyphens,
    /// underscores, parentheses, square brackets, and a trailing `?`.
    private static func isValidType(_ type: String) -> Bool {
        guard let first = type.first, first.isLetter else { return false }
        return true
    }

    /// Attribute names follow the same rules as types but may start with `*`.
    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let stripped = name.hasPrefix("*") ? String(name.dropFirst()) : name
        guard let first = stripped.first else { return false }
        return first.isLetter || first.isNumber || first == "_"
    }
}
