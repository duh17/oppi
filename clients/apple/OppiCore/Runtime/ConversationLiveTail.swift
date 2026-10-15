import Foundation

/// What a durable conversation's `pi.live` document shows in the timeline: the answer being
/// generated, the running tool round, and compaction and retry status. Built from the
/// replica each frame by `ConversationLiveProjector` and applied by
/// `TimelineReducer.applyLiveTail`, which owns how these become rows.
struct TimelineLiveTail: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        /// Consecutive text blocks starting at content index `index`, joined like committed rows.
        case text(index: Int, text: String)
        case thinking(index: Int, text: String)
        case toolCall(id: String, name: String, args: [String: JSONValue], view: ConversationToolCallView?)
    }

    /// A call of the current tool round that has not finished.
    struct Tool: Equatable, Sendable {
        var id: String
        /// Started; a pending call of a sequential round has not.
        var running: Bool
        var output: String
        /// The output is a bounded window; `totalBytes` counts what was dropped too.
        var truncated: Bool
        var totalBytes: Int?
        var details: JSONValue?
    }

    struct Retry: Equatable, Sendable {
        var attempt: Int?
        var error: String
    }

    /// `pi.live.run` is present exactly while the conversation is busy.
    var isRunning = false
    /// The answer's timestamp, stable while it streams.
    var timestamp: Date?
    var blocks: [Block] = []
    var tools: [Tool] = []
    var isCompacting = false
    var retry: Retry?
}

/// Projects `pi.live` into a `TimelineLiveTail`. Only the live document is read, so a frame
/// costs the size of the answer in flight, not of the conversation. Tool presentation is
/// decoded once per call and reused while its JSON is unchanged.
struct ConversationLiveProjector {
    private var views: [String: (raw: JSONValue, view: ConversationToolCallView?)] = [:]

    mutating func tail(from live: JSONValue?) -> TimelineLiveTail {
        var tail = TimelineLiveTail()
        guard let live = live?.objectValue else {
            views.removeAll()
            return tail
        }
        tail.isRunning = live["run"].map { $0 != .null } ?? false
        let rawViews = live["toolCalls"]?.objectValue ?? [:]
        views = views.filter { rawViews[$0.key] != nil }

        if let generation = live["generation"]?.objectValue {
            if let message = generation["message"]?.objectValue {
                tail.timestamp = message["timestamp"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) }
                tail.blocks = blocks(message["content"], rawViews: rawViews)
            }
            if let error = generation["retry"]?.objectValue?["error"]?.stringValue {
                tail.retry = .init(attempt: generation["attempt"]?.numberValue.map { Int($0) }, error: error)
            }
        }
        for slot in live["tools"]?.arrayValue ?? [] {
            guard let slot = slot.objectValue, let id = slot["callId"]?.stringValue,
                  slot["status"]?.stringValue != "done" else { continue }
            let output = slot["output"]?.stringValue ?? ""
            let dropped = Int(slot["droppedBytes"]?.numberValue ?? 0)
            let truncated = dropped > 0 || (slot["droppedLines"]?.numberValue ?? 0) > 0
            tail.tools.append(.init(
                id: id,
                running: slot["status"]?.stringValue == "running",
                output: output,
                truncated: truncated,
                totalBytes: truncated ? output.utf8.count + dropped : nil,
                details: slot["details"].flatMap { $0 == .null ? nil : $0 }
            ))
        }
        tail.isCompacting = !(live["compactions"]?.arrayValue ?? []).isEmpty
        return tail
    }

    /// The committed projector's assistant rules: a run of text blocks is one row.
    private mutating func blocks(_ content: JSONValue?, rawViews: [String: JSONValue]) -> [TimelineLiveTail.Block] {
        switch content {
        case .string(let text):
            return text.isEmpty ? [] : [.text(index: 0, text: text)]
        case .array(let parts):
            var blocks: [TimelineLiveTail.Block] = []
            var pending: [String] = []
            var pendingIndex = 0
            func flushText() {
                if !pending.isEmpty {
                    blocks.append(.text(index: pendingIndex, text: ConversationTraceProjector.joinTextBlocks(pending)))
                }
                pending = []
            }
            for (index, part) in parts.enumerated() {
                guard let block = part.objectValue else { continue }
                let type = block["type"]?.stringValue
                if type == "text" || type == "output_text", let text = block["text"]?.stringValue {
                    if pending.isEmpty { pendingIndex = index }
                    pending.append(text)
                    continue
                }
                flushText()
                if type == "thinking", let thinking = block["thinking"]?.stringValue, !thinking.isEmpty {
                    blocks.append(.thinking(index: index, text: thinking))
                } else if type == "toolCall", let id = block["id"]?.stringValue, !id.isEmpty {
                    let args = block["arguments"]?.objectValue
                        ?? ConversationTraceProjector.parsedObject(block["partialJson"])
                        ?? [:]
                    blocks.append(.toolCall(
                        id: id,
                        name: block["name"]?.stringValue ?? "",
                        args: args,
                        view: view(id, raw: rawViews[id])
                    ))
                }
            }
            flushText()
            return blocks
        default:
            return []
        }
    }

    private mutating func view(_ id: String, raw: JSONValue?) -> ConversationToolCallView? {
        guard let raw else { return nil }
        if let cached = views[id], cached.raw == raw { return cached.view }
        let view = (try? JSONEncoder().encode(raw)).flatMap { try? JSONDecoder().decode(ConversationToolCallView.self, from: $0) }
        views[id] = (raw, view)
        return view
    }
}
