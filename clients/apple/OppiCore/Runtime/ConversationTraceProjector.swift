import Foundation

/// Projects committed conversation entries into the `TraceEvent`s the server's mobile trace
/// route returns for the same entries (`view=full` with presentation segments), so the
/// timeline renders them through its existing committed-history path.
///
/// A port of the per-entry rules of `server/src/durable-history.ts` `projectEntries`,
/// `server/src/trace.ts` `buildSessionContext`, and `session-trace-service.ts`
/// `withMobileRenderSegments`. The server already decided what needs server state: tool
/// presentation, cards, and hidden entries. Entries go in id order, the full trace's order,
/// where a compaction sits after the entries it kept.
enum ConversationTraceProjector {
    static func traceEvents(from entries: [ConversationEntryView]) -> [TraceEvent] {
        let shown = entries.filter { $0.hidden != true }.sorted { $0.id < $1.id }
        // A call's output presentation and display name come from its result when there is one.
        var results: [String: ConversationToolResultView] = [:]
        for entry in shown {
            guard let message = entry.model?.first?.objectValue,
                  message["role"]?.stringValue == "toolResult",
                  let callId = message["toolCallId"]?.stringValue, !callId.isEmpty else { continue }
            results[callId] = entry.toolResult ?? ConversationToolResultView()
        }
        var events: [TraceEvent] = []
        for entry in shown {
            if let card = entry.card {
                events.append(cardEvent(entry, card: card))
                continue
            }
            // Like `projectEntries`, only the first model message counts.
            let message = entry.model?.first?.objectValue
            let timestamp = isoTimestamp(milliseconds: message?["timestamp"]?.numberValue ?? 0)
            if entry.kind == "pi.compaction" {
                let summary = message.map(compactionSummary) ?? ""
                events.append(TraceEvent(
                    id: String(entry.id),
                    type: .compaction,
                    timestamp: timestamp,
                    text: "Context compacted: \(summary.isEmpty ? "Previous context was compacted" : summary)"
                ))
                continue
            }
            // Entries without model messages and without a card show nothing.
            guard let message else { continue }
            switch message["role"]?.stringValue {
            case "user":
                let text = extractText(message["content"])
                if !text.isEmpty {
                    var event = TraceEvent(
                        id: String(entry.id),
                        type: .user,
                        timestamp: timestamp,
                        text: entry.origin == nil ? text : agentMessageText(text, offset: entry.textOffset)
                    )
                    event.origin = entry.origin
                    events.append(event)
                }
            case "assistant":
                appendAssistant(entry, message: message, timestamp: timestamp, results: results, to: &events)
            case "toolResult":
                events.append(toolResultEvent(entry, message: message, timestamp: timestamp))
            default:
                break
            }
        }
        return events
    }

    // MARK: - Entry kinds

    /// `agentMessageText` in `server/extensions/durable/sessions/agent-message.ts`: the text after
    /// the model-only header (`offset` in UTF-16 units), or the whole text when that is empty.
    private static func agentMessageText(_ text: String, offset: Int?) -> String {
        let units = text.utf16
        guard let offset, offset > 0, offset <= units.count else { return text }
        let tail = String(decoding: units[units.index(units.startIndex, offsetBy: offset)...], as: UTF16.self)
        let body = String(tail.drop { $0.isWhitespace })
        return body.isEmpty ? text : body
    }

    private static func cardEvent(_ entry: ConversationEntryView, card: ConversationEntryCard) -> TraceEvent {
        let inputCard = entry.inputCard == true
        let output = inputCard ? card.output.map {
            TraceEventPresentation.Output(
                kind: $0.kind,
                entryId: String(entry.id),
                command: $0.command,
                truncated: $0.truncated
            )
        } : nil
        let presentation = TraceEventPresentation(
            kind: card.kind,
            title: card.title,
            subtitle: card.subtitle,
            status: card.status,
            body: card.body,
            fields: card.fields,
            accent: card.accent,
            output: output
        )
        var lines = [card.title]
        if let subtitle = card.subtitle, !subtitle.isEmpty { lines.append(subtitle) }
        if let body = card.body, !body.isEmpty { lines.append(contentsOf: ["", body]) }
        for field in card.fields ?? [] { lines.append("\(field.label): \(field.value)") }
        return TraceEvent(
            id: String(entry.id),
            type: .system,
            timestamp: isoTimestamp(milliseconds: card.at),
            text: lines.joined(separator: "\n"),
            presentation: presentation
        )
    }

    private static func appendAssistant(
        _ entry: ConversationEntryView,
        message: [String: JSONValue],
        timestamp: String,
        results: [String: ConversationToolResultView],
        to events: inout [TraceEvent]
    ) {
        let id = String(entry.id)
        switch message["content"] {
        case .string(let text) where !text.isEmpty:
            events.append(TraceEvent(id: id, type: .assistant, timestamp: timestamp, text: text))
        case .array(let content):
            var runOrdinal = 0
            var pending: [String] = []
            var pendingIndex = 0
            func flushText() {
                let text = joinTextBlocks(pending)
                if !text.isEmpty {
                    events.append(TraceEvent(
                        id: "\(id)-text-\(pendingIndex)",
                        type: .assistant,
                        timestamp: timestamp,
                        text: text,
                        contentIndex: pendingIndex,
                        runOrdinal: runOrdinal
                    ))
                    runOrdinal += 1
                }
                pending = []
            }
            for (index, part) in content.enumerated() {
                let block = part.objectValue
                let type = block?["type"]?.stringValue
                if type == "text" || type == "output_text", let text = block?["text"]?.stringValue {
                    if pending.isEmpty { pendingIndex = index }
                    pending.append(text)
                    continue
                }
                flushText()
                guard let block else { continue }
                if type == "thinking", let thinking = block["thinking"]?.stringValue, !thinking.isEmpty {
                    events.append(TraceEvent(
                        id: "\(id)-think-\(index)",
                        type: .thinking,
                        timestamp: timestamp,
                        thinking: thinking
                    ))
                } else if type == "toolCall" {
                    events.append(toolCallEvent(entry, block: block, index: index, timestamp: timestamp, results: results))
                }
            }
            flushText()
        default:
            break
        }
    }

    private static func toolCallEvent(
        _ entry: ConversationEntryView,
        block: [String: JSONValue],
        index: Int,
        timestamp: String,
        results: [String: ConversationToolResultView]
    ) -> TraceEvent {
        let callId = block["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let eventId = callId ?? "\(entry.id)-tool-\(index)"
        let name = block["name"]?.stringValue ?? ""
        let args: [String: JSONValue]? = switch block["arguments"] {
        case .object(let arguments): arguments
        // `arguments || tryParseJson(partialJson)`: only a falsy value falls back.
        case .none, .null, .bool(false), .number(0), .string(""): parsedObject(block["partialJson"])
        default: nil
        }
        let call = callId.flatMap { entry.toolCalls?[$0] }
        let result = results[eventId]
        return TraceEvent(
            id: eventId,
            type: .toolCall,
            timestamp: timestamp,
            tool: name.isEmpty ? "unknown" : name,
            args: args,
            callSegments: call?.callSegments,
            outputPresentation: result.map(\.outputPresentation) ?? call?.outputPresentation,
            inputPresentation: call?.inputPresentation,
            display: result.map(\.display) ?? call?.display
        )
    }

    private static func toolResultEvent(
        _ entry: ConversationEntryView,
        message: [String: JSONValue],
        timestamp: String
    ) -> TraceEvent {
        let details = message["details"].flatMap { $0 == .null ? nil : $0 }
        let view = entry.toolResult
        return TraceEvent(
            id: "result-\(entry.id)",
            type: .toolResult,
            timestamp: timestamp,
            output: extractText(message["content"]),
            toolCallId: message["toolCallId"]?.stringValue,
            toolName: message["toolName"]?.stringValue,
            isError: message["isError"]?.boolValue == true,
            resultSegments: view?.resultSegments,
            details: details,
            outputPresentation: view?.outputPresentation,
            outputAvailability: view?.outputAvailability
        )
    }

    // MARK: - Text

    /// `extractText` in `trace.ts`: text blocks, and media as data URIs, one per line.
    static func extractText(_ content: JSONValue?) -> String {
        switch content {
        case .string(let text):
            return text
        case .array(let blocks):
            return blocks.compactMap { part -> String? in
                guard let block = part.objectValue else { return nil }
                let type = block["type"]?.stringValue
                if type == "text" || type == "output_text" {
                    guard let text = block["text"]?.stringValue, !text.isEmpty else { return nil }
                    return text
                }
                guard let data = block["data"]?.stringValue, !data.isEmpty else { return nil }
                let mimeType = block["mimeType"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                switch type {
                case "image": return "data:\(mimeType ?? "image/png");base64,\(data)"
                case "audio", "output_audio": return "data:\(mimeType ?? "audio/wav");base64,\(data)"
                default: return nil
                }
            }.joined(separator: "\n")
        default:
            return ""
        }
    }

    /// `joinAssistantTextBlocks`: adjacent text blocks, with a paragraph break where joining
    /// them directly would run two words or Markdown tokens together.
    private static func joinTextBlocks(_ parts: [String]) -> String {
        var joined = ""
        for part in parts where !part.isEmpty {
            if let last = joined.unicodeScalars.last, !last.properties.isWhitespace,
               let first = part.unicodeScalars.first, !first.properties.isWhitespace {
                joined += "\n\n"
            }
            joined += part
        }
        return joined
    }

    /// `compactionSummary`: the text inside `<summary>`, or the whole text, trimmed.
    private static func compactionSummary(_ message: [String: JSONValue]) -> String {
        guard message["role"]?.stringValue == "user" else { return "" }
        let text: String = switch message["content"] {
        case .string(let text): text
        case .array(let blocks):
            blocks.compactMap { block in
                block.objectValue?["type"]?.stringValue == "text" ? block.objectValue?["text"]?.stringValue : nil
            }.joined()
        default: ""
        }
        let summary = text.firstMatch(of: /<summary>\n?([\s\S]*?)\n?<\/summary>/.matchingSemantics(.unicodeScalar))
            .map { String($0.output.1) } ?? text
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parsedObject(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let json = value?.stringValue, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
    }

    // MARK: - Time

    /// JavaScript `new Date(ms).toISOString()`: UTC with milliseconds.
    static func isoTimestamp(milliseconds: Double) -> String {
        let total = Int64(milliseconds.rounded(.towardZero))
        let msPerDay: Int64 = 86_400_000
        let days = total >= 0 ? total / msPerDay : (total - (msPerDay - 1)) / msPerDay
        let ofDay = total - days * msPerDay
        // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return String(
            format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%03lldZ",
            year, month, day,
            ofDay / 3_600_000, ofDay / 60000 % 60, ofDay / 1000 % 60, ofDay % 1000
        )
    }
}
