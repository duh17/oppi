import Foundation

/// Line-oriented parser for `sequenceDiagram` bodies.
///
/// Emits an ordered `SequenceEvent` stream. Participant/box/link/autonumber
/// fields stay as derived roster views so existing tests keep working.
enum MermaidSequenceParser {

    // Keywords that should not become participants when seen as standalone lines.
    private static let sequenceKeywords: Set<String> = [
        "autonumber", "activate", "deactivate",
        "loop", "alt", "else", "opt", "par", "and",
        "critical", "option", "break", "end",
        "rect", "box",
    ]

    private struct SequenceParticipantDeclaration {
        let id: String
        let alias: String?
        let kind: SequenceParticipantKind?
    }

    private final class SequenceBoxBuilder {
        let label: String?
        let color: String?
        var participantIds: [String] = []

        init(label: String?, color: String?) {
            self.label = label
            self.color = color
        }

        func addParticipant(_ id: String) {
            guard !participantIds.contains(id) else { return }
            participantIds.append(id)
        }

        func build() -> SequenceBox {
            SequenceBox(label: label, color: color, participantIds: participantIds)
        }
    }

    static func parse(lines: [String]) -> SequenceDiagram {
        var events: [SequenceEvent] = []
        var participants: [SequenceParticipant] = []
        var boxes: [SequenceBox] = []
        var links: [SequenceLink] = []
        var knownIds: Set<String> = []
        var autonumber = false
        var autonumberStart = 1.0
        var autonumberIncrement = 1.0
        var blockDepth = 0
        var boxStack: [SequenceBoxBuilder] = []

        func addParticipant(_ participant: SequenceParticipant) {
            boxStack.last?.addParticipant(participant.id)
            guard !knownIds.contains(participant.id) else { return }
            participants.append(participant)
            knownIds.insert(participant.id)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let lower = trimmed.lowercased()

            if lower == "autonumber" || lower.hasPrefix("autonumber ") {
                autonumber = true
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if parts.count >= 2, let start = Double(parts[1]) {
                    autonumberStart = start
                }
                if parts.count >= 3, let increment = Double(parts[2]) {
                    autonumberIncrement = increment
                }
                continue
            }

            if lower.hasPrefix("activate ") {
                let actorId = String(trimmed.dropFirst("activate ".count))
                    .trimmingCharacters(in: .whitespaces)
                if !actorId.isEmpty, !Self.sequenceKeywords.contains(actorId.lowercased()) {
                    events.append(.activate(actorId: actorId))
                }
                continue
            }

            if lower.hasPrefix("deactivate ") {
                let actorId = String(trimmed.dropFirst("deactivate ".count))
                    .trimmingCharacters(in: .whitespaces)
                if !actorId.isEmpty, !Self.sequenceKeywords.contains(actorId.lowercased()) {
                    events.append(.deactivate(actorId: actorId))
                }
                continue
            }

            if lower.hasPrefix("create ") {
                let declaration = String(trimmed.dropFirst("create ".count))
                    .trimmingCharacters(in: .whitespaces)
                if let participant = parseParticipant(declaration) {
                    addParticipant(participant)
                    events.append(.create(participant))
                }
                continue
            }

            if lower.hasPrefix("destroy ") {
                let actorId = String(trimmed.dropFirst("destroy ".count))
                    .trimmingCharacters(in: .whitespaces)
                if !actorId.isEmpty {
                    events.append(.destroy(actorId: actorId))
                }
                continue
            }

            if let parsedLinks = parseSequenceLinks(trimmed) {
                for link in parsedLinks {
                    addParticipant(SequenceParticipant(id: link.actorId, label: link.actorId, isActor: false))
                }
                links.append(contentsOf: parsedLinks)
                continue
            }

            if lower == "box" || lower.hasPrefix("box ") {
                let header = lower == "box"
                    ? ""
                    : String(trimmed.dropFirst("box ".count)).trimmingCharacters(in: .whitespaces)
                let box = parseSequenceBoxHeader(header)
                boxStack.append(SequenceBoxBuilder(label: box.label, color: box.color))
                continue
            }

            if lower.hasPrefix("rect ") || lower == "rect" {
                let color = lower == "rect"
                    ? ""
                    : String(trimmed.dropFirst("rect ".count)).trimmingCharacters(in: .whitespaces)
                events.append(.blockOpen(kind: .rect, label: color))
                blockDepth += 1
                continue
            }

            if let blockInfo = parseBlockOpener(lower, raw: trimmed) {
                events.append(.blockOpen(kind: blockInfo.kind, label: blockInfo.label))
                blockDepth += 1
                continue
            }

            if lower.hasPrefix("else") || lower.hasPrefix("and ") || lower.hasPrefix("option ") {
                let kind: SequenceBlockDividerKind
                let label: String
                if lower.hasPrefix("else") {
                    kind = .else
                    label = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                } else if lower.hasPrefix("and ") {
                    kind = .and
                    label = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                } else {
                    kind = .option
                    label = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                }
                if blockDepth > 0 {
                    events.append(.blockDivider(kind: kind, label: label))
                }
                continue
            }

            if lower == "end" {
                if blockDepth > 0 {
                    events.append(.blockClose)
                    blockDepth -= 1
                } else if let box = boxStack.popLast() {
                    boxes.append(box.build())
                }
                continue
            }

            if let note = parseSequenceNote(trimmed) {
                for actor in note.actors {
                    addParticipant(SequenceParticipant(id: actor, label: actor, isActor: false))
                }
                events.append(.note(note))
                continue
            }

            if let participant = parseParticipant(trimmed) {
                addParticipant(participant)
                continue
            }

            if let message = parseSequenceMessage(trimmed) {
                for pid in [message.from, message.to] {
                    addParticipant(SequenceParticipant(id: pid, label: pid, isActor: false))
                }
                events.append(.message(message))
            }
        }

        while blockDepth > 0 {
            events.append(.blockClose)
            blockDepth -= 1
        }
        while let box = boxStack.popLast() {
            boxes.append(box.build())
        }

        return SequenceDiagram(
            events: events,
            participants: participants,
            boxes: boxes,
            links: links,
            autonumber: autonumber,
            autonumberStart: autonumberStart,
            autonumberIncrement: autonumberIncrement
        )
    }

    private static func parseBlockOpener(_ lower: String, raw: String) -> (kind: SequenceBlockKind, label: String)? {
        let patterns: [(prefix: String, kind: SequenceBlockKind)] = [
            ("loop ", .loop),
            ("alt ", .alt),
            ("opt ", .opt),
            ("par ", .par),
            ("critical ", .critical),
            ("break ", .break),
        ]
        if let match = patterns.first(where: { lower.hasPrefix($0.prefix) }) {
            let label = String(raw.dropFirst(match.prefix.count)).trimmingCharacters(in: .whitespaces)
            return (match.kind, label)
        }

        let keywordOnly: [(keyword: String, kind: SequenceBlockKind)] = [
            ("loop", .loop), ("alt", .alt), ("opt", .opt),
            ("par", .par), ("critical", .critical),
        ]
        if let match = keywordOnly.first(where: { lower == $0.keyword }) {
            return (match.kind, "")
        }
        return nil
    }

    private static func parseSequenceBoxHeader(_ header: String) -> (label: String?, color: String?) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, nil) }
        let lower = trimmed.lowercased()

        for prefix in ["rgb(", "rgba(", "hsl(", "hsla("] where lower.hasPrefix(prefix) {
            guard let close = trimmed.firstIndex(of: ")") else { return (trimmed, nil) }
            let color = String(trimmed[...close])
            let afterColor = trimmed.index(after: close)
            let label = String(trimmed[afterColor...]).trimmingCharacters(in: .whitespaces)
            return (label.isEmpty ? nil : normalize(label), color)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return (nil, nil) }
        if sequenceBoxColorNames.contains(first.lowercased()) {
            let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return (label.isEmpty ? nil : normalize(label), first)
        }

        return (normalize(trimmed), nil)
    }

    private static let sequenceBoxColorNames: Set<String> = [
        "aqua", "black", "blue", "brown", "cyan", "gray", "green", "grey",
        "lime", "magenta", "orange", "pink", "purple", "red", "transparent",
        "violet", "white", "yellow",
    ]

    private static func parseSequenceLinks(_ line: String) -> [SequenceLink]? {
        let lower = line.lowercased()
        if lower.hasPrefix("link ") {
            return parseSingleSequenceLink(String(line.dropFirst("link ".count)))
        }
        if lower.hasPrefix("links ") {
            return parseJSONSequenceLinks(String(line.dropFirst("links ".count)))
        }
        return nil
    }

    private static func parseSingleSequenceLink(_ rest: String) -> [SequenceLink]? {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let actorId = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
        let payloadStart = rest.index(after: colon)
        let payload = String(rest[payloadStart...]).trimmingCharacters(in: .whitespaces)
        guard let separator = payload.range(of: " @ ") ?? payload.range(of: "@") else { return nil }
        let label = String(payload[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        let url = String(payload[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !actorId.isEmpty, !label.isEmpty, !url.isEmpty else { return nil }
        return [SequenceLink(actorId: actorId, label: normalize(label), url: url)]
    }

    private static func parseJSONSequenceLinks(_ rest: String) -> [SequenceLink]? {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let actorId = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
        let payloadStart = rest.index(after: colon)
        let jsonText = String(rest[payloadStart...]).trimmingCharacters(in: .whitespaces)
        guard !actorId.isEmpty,
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let linksByLabel = object as? [String: String]
        else { return nil }

        return linksByLabel.keys.sorted().compactMap { label in
            guard let url = linksByLabel[label], !label.isEmpty, !url.isEmpty else { return nil }
            return SequenceLink(actorId: actorId, label: normalize(label), url: url)
        }
    }

    /// Parse `Note [right of | left of | over] Actor[,Actor]: text`
    private static func parseSequenceNote(_ line: String) -> SequenceNote? {
        let lower = line.lowercased()
        guard lower.hasPrefix("note ") else { return nil }
        let rest = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        let restLower = rest.lowercased()

        let position: NotePosition
        let afterPosition: String

        if restLower.hasPrefix("right of ") {
            position = .rightOf
            afterPosition = String(rest.dropFirst(9)).trimmingCharacters(in: .whitespaces)
        } else if restLower.hasPrefix("left of ") {
            position = .leftOf
            afterPosition = String(rest.dropFirst(8)).trimmingCharacters(in: .whitespaces)
        } else if restLower.hasPrefix("over ") {
            position = .over
            afterPosition = String(rest.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        let parts = afterPosition.split(separator: ":", maxSplits: 1).map(String.init)
        guard let actorPart = parts.first else { return nil }
        let text = parts.count > 1 ? normalize(parts[1].trimmingCharacters(in: .whitespaces)) : ""
        let actors = actorPart.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        return SequenceNote(text: text, position: position, actors: actors)
    }

    private static func parseParticipant(_ line: String) -> SequenceParticipant? {
        let isActor: Bool
        let rest: String
        let baseKind: SequenceParticipantKind

        if line.hasPrefix("participant ") {
            isActor = false
            baseKind = .participant
            rest = String(line.dropFirst("participant ".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("actor ") {
            isActor = true
            baseKind = .actor
            rest = String(line.dropFirst("actor ".count)).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        let (declaration, externalAlias) = splitParticipantAlias(rest)
        let parsed = parseParticipantDeclaration(declaration)
        guard !parsed.id.isEmpty else { return nil }

        let label = externalAlias.map(normalize)
            ?? parsed.alias.map(normalize)
            ?? normalize(parsed.id)
        return SequenceParticipant(
            id: parsed.id,
            label: label,
            isActor: isActor,
            kind: parsed.kind ?? baseKind
        )
    }

    private static func splitParticipantAlias(_ rest: String) -> (declaration: String, alias: String?) {
        var inDoubleQuote = false
        var braceDepth = 0
        var index = rest.startIndex

        while index < rest.endIndex {
            let char = rest[index]
            if char == "\"" {
                inDoubleQuote.toggle()
            } else if !inDoubleQuote {
                if char == "{" {
                    braceDepth += 1
                } else if char == "}" {
                    braceDepth = max(0, braceDepth - 1)
                } else if braceDepth == 0,
                          rest[index...].hasPrefix(" as ") {
                    let declaration = String(rest[..<index]).trimmingCharacters(in: .whitespaces)
                    let aliasStart = rest.index(index, offsetBy: 4)
                    let alias = String(rest[aliasStart...]).trimmingCharacters(in: .whitespaces)
                    return (declaration, alias.isEmpty ? nil : alias)
                }
            }
            index = rest.index(after: index)
        }

        return (rest.trimmingCharacters(in: .whitespaces), nil)
    }

    private static func parseParticipantDeclaration(_ declaration: String) -> SequenceParticipantDeclaration {
        guard let marker = declaration.range(of: "@{") else {
            return SequenceParticipantDeclaration(
                id: declaration.trimmingCharacters(in: .whitespaces),
                alias: nil,
                kind: nil
            )
        }

        let id = String(declaration[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
        let bodyStart = marker.upperBound
        guard let end = declaration[bodyStart...].lastIndex(of: "}") else {
            return SequenceParticipantDeclaration(id: id, alias: nil, kind: nil)
        }

        let body = String(declaration[bodyStart..<end])
        let properties = parseMetadataProperties(body)
        let alias = properties["alias"].map(normalizeMetadataValue)
        let kind = properties["type"]
            .map(normalizeMetadataValue)
            .flatMap { SequenceParticipantKind(rawValue: $0.lowercased()) }
        return SequenceParticipantDeclaration(id: id, alias: alias, kind: kind)
    }

    /// Parse sequence message: `A->>B: text`, `A-->>B: text`, etc.
    private static func parseSequenceMessage(_ line: String) -> SequenceMessage? {
        let arrowPatterns: [(String, SequenceArrowStyle)] = [
            ("<<-->>", .dashedBidirectional),
            ("<<->>", .solidBidirectional),
            ("--\\|\\", .dashedTopHalfArrow),
            ("-\\|\\", .solidTopHalfArrow),
            ("--\\|/", .dashedBottomHalfArrow),
            ("-\\|/", .solidBottomHalfArrow),
            ("/\\|--", .dashedReverseTopHalfArrow),
            ("/\\|-", .solidReverseTopHalfArrow),
            ("\\\\--", .dashedReverseBottomHalfArrow),
            ("\\\\-", .solidReverseBottomHalfArrow),
            ("--\\\\", .dashedTopStickHalfArrow),
            ("-\\\\", .solidTopStickHalfArrow),
            ("--//", .dashedBottomStickHalfArrow),
            ("-//", .solidBottomStickHalfArrow),
            ("//--", .dashedReverseTopStickHalfArrow),
            ("//-", .solidReverseTopStickHalfArrow),
            ("-->>", .dashed),
            ("->>", .solid),
            ("--)", .dashedAsync),
            ("-)", .solidAsync),
            ("--x", .dashedCross),
            ("-x", .solidCross),
            ("-->", .dashedOpen),
            ("->", .solidOpen),
        ]

        for (pattern, style) in arrowPatterns {
            if let range = line.range(of: pattern) {
                var from = String(line[line.startIndex ..< range.lowerBound]).trimmingCharacters(in: .whitespaces)
                var remaining = String(line[range.upperBound...])

                let fromCentral = from.hasSuffix("()")
                if fromCentral {
                    from = String(from.dropLast(2)).trimmingCharacters(in: .whitespaces)
                }

                var activationModifier: ActivationModifier?
                if remaining.hasPrefix("+") {
                    activationModifier = .activate
                    remaining = String(remaining.dropFirst())
                } else if remaining.hasPrefix("-") {
                    activationModifier = .deactivate
                    remaining = String(remaining.dropFirst())
                }

                let parts = remaining.split(separator: ":", maxSplits: 1).map(String.init)
                guard let firstPart = parts.first else { continue }
                var to = firstPart.trimmingCharacters(in: .whitespaces)
                let toCentral = to.hasPrefix("()")
                if toCentral {
                    to = String(to.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                let text = parts.count > 1 ? normalize(parts[1].trimmingCharacters(in: .whitespaces)) : ""

                if !from.isEmpty, !to.isEmpty {
                    return SequenceMessage(
                        from: from, to: to, text: text,
                        arrowStyle: style,
                        activationModifier: activationModifier,
                        fromCentral: fromCentral,
                        toCentral: toCentral
                    )
                }
            }
        }

        return nil
    }

    private static func normalize(_ text: String) -> String {
        MermaidTextUtils.normalizeLabel(text)
    }

    private static func parseMetadataProperties(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in splitMetadataPairs(body) {
            guard let colonIndex = firstUnquotedColon(in: pair) else { continue }
            let rawKey = String(pair[..<colonIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeMetadataValue(rawKey).lowercased()
            let valueStart = pair.index(after: colonIndex)
            let value = String(pair[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private static func splitMetadataPairs(_ body: String) -> [String] {
        var pairs: [String] = []
        var current = ""
        var inDoubleQuote = false

        for char in body {
            if char == "\"" {
                inDoubleQuote.toggle()
                current.append(char)
            } else if char == ",", !inDoubleQuote {
                pairs.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }

        pairs.append(current)
        return pairs
    }

    private static func firstUnquotedColon(in text: String) -> String.Index? {
        var inDoubleQuote = false
        for index in text.indices {
            let char = text[index]
            if char == "\"" {
                inDoubleQuote.toggle()
            } else if char == ":", !inDoubleQuote {
                return index
            }
        }
        return nil
    }

    private static func normalizeMetadataValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.first == "\"",
              trimmed.last == "\""
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }
}
