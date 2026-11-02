import UIKit

/// The live traces behind the full-screen readers a timeline opened, by item id.
///
/// A reader outlives the row that opened it. Opening one pushes a page, so the
/// chat leaves the window, the timeline's own apply keeps running (the session
/// runtime stays bound while a page covers the chat), but UIKit configures no
/// cell for a row outside the viewport — and the thinking row or expanded tool
/// row a reader follows sits just above the streaming tail. So the text a
/// reader shows is fed from the apply's rows by item id, one trace per open
/// reader, never from whichever cell happens to be configured.
///
/// Work per apply is bounded by the readers that are actually open: a payload or
/// a mounted reader owns each trace, so an entry whose trace nobody holds is
/// dropped, and a trace that has reported done is never fed again.
@MainActor
final class ChatTimelineReaderTraces {
    /// One reader's traces. They are held weakly: the reader and the payload it
    /// was opened from own them (`ChatReaderPayloadStore` keeps a payload across
    /// a split or stack swap, so a rebuilt reader observes the same stream). A
    /// trace with no owner left is a reader nobody can see, and its entry goes.
    private final class Entry {
        weak var thinking: ReaderTrace<ThinkingSnapshot>?
        weak var terminal: ReaderTrace<TerminalSnapshot>?
        weak var source: ReaderTrace<SourceSnapshot>?
        /// The last row this entry was fed, so an unchanged row costs one compare.
        var lastPreview: String?
        var lastIsLive: Bool?

        var hasLiveTrace: Bool {
            thinking != nil || terminal != nil || source != nil
        }
    }

    private var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }

    /// Item ids with an open reader; a test and diagnostic surface.
    var openItemIDs: [String] { entries.keys.sorted() }

    // MARK: - Opening

    /// The row's thinking trace, seeded from what the row shows right now.
    func thinkingTrace(itemID: String, text: String, isDone: Bool) -> ReaderTrace<ThinkingSnapshot> {
        let entry = entry(for: itemID)
        let snapshot = ThinkingSnapshot(text: text, isDone: isDone)
        if let trace = entry.thinking {
            trace.update(snapshot)
            return trace
        }
        entry.lastPreview = text
        entry.lastIsLive = !isDone
        let trace = ReaderTrace(snapshot)
        entry.thinking = trace
        return trace
    }

    func terminalTrace(itemID: String, _ snapshot: TerminalSnapshot) -> ReaderTrace<TerminalSnapshot> {
        let entry = entry(for: itemID)
        if let trace = entry.terminal {
            trace.update(snapshot)
            return trace
        }
        let trace = ReaderTrace(snapshot, isNews: TerminalSnapshot.isNews)
        entry.terminal = trace
        return trace
    }

    func sourceTrace(itemID: String, _ snapshot: SourceSnapshot) -> ReaderTrace<SourceSnapshot> {
        let entry = entry(for: itemID)
        if let trace = entry.source {
            trace.update(snapshot)
            return trace
        }
        let trace = ReaderTrace(snapshot, isNews: SourceSnapshot.isNews)
        entry.source = trace
        return trace
    }

    private func entry(for itemID: String) -> Entry {
        if let entry = entries[itemID] { return entry }
        let entry = Entry()
        entries[itemID] = entry
        return entry
    }

    // MARK: - Feeding

    /// Called by every apply. A reader with no entry costs nothing; otherwise
    /// each open reader looks its own row up by id.
    ///
    /// `itemExists` answers for the whole timeline, not the rendered rows: a row
    /// folds into its work line whenever that strip is collapsed, a running turn
    /// included, and folding must not end its reader.
    func update(
        items: [ChatItem],
        liveRowIDs: Set<String>,
        itemExists: (String) -> Bool,
        toolConfiguration: (String, ChatItem) -> ToolTimelineRowConfiguration?
    ) {
        for itemID in Array(entries.keys) where entries[itemID]?.hasLiveTrace == false {
            entries[itemID] = nil
        }
        guard !entries.isEmpty else { return }

        var unresolved = Set(entries.keys)
        var resolved: [String: ChatItem] = [:]
        for item in items {
            guard unresolved.remove(item.id) != nil else { continue }
            resolved[item.id] = item
            if unresolved.isEmpty { break }
        }

        for (itemID, entry) in entries {
            guard let item = resolved[itemID] else {
                // Out of the rendered rows but still in the timeline: nothing to
                // feed yet. Gone from the timeline: no row can grow again.
                if !itemExists(itemID) {
                    settle(entry)
                    entries[itemID] = nil
                }
                continue
            }
            updateThinking(entry, itemID: itemID, item: item, liveRowIDs: liveRowIDs)
            updateToolTraces(entry, itemID: itemID, item: item, toolConfiguration: toolConfiguration)
        }
    }

    private func updateThinking(
        _ entry: Entry,
        itemID: String,
        item: ChatItem,
        liveRowIDs: Set<String>
    ) {
        guard let trace = entry.thinking,
              case .thinking(_, let preview, _, let isDone) = item else {
            return
        }
        let isLive = liveRowIDs.contains(itemID)
        // The row's own text and liveness first: a trimmed copy and a delivered
        // snapshot are only worth it when the row actually changed.
        guard entry.lastPreview != preview || entry.lastIsLive != isLive else { return }
        entry.lastPreview = preview
        entry.lastIsLive = isLive
        trace.update(ThinkingSnapshot(
            text: preview.trimmingCharacters(in: .whitespacesAndNewlines),
            isDone: ThinkingTimelineRowConfiguration.traceIsComplete(isDone: isDone, isLive: isLive)
        ))
    }

    /// A running call's output and source follow its row until the row reports
    /// done: that apply carries the last text and the finished content, so it
    /// goes through exactly once and the trace is then left alone.
    private func updateToolTraces(
        _ entry: Entry,
        itemID: String,
        item: ChatItem,
        toolConfiguration: (String, ChatItem) -> ToolTimelineRowConfiguration?
    ) {
        let needsFeed = (entry.terminal.map { !$0.snapshot.isDone } ?? false)
            || (entry.source.map { !$0.snapshot.isDone } ?? false)
        guard needsFeed, let configuration = toolConfiguration(itemID, item) else { return }
        if entry.terminal?.snapshot.isDone != true, let trace = entry.terminal {
            trace.update(ToolTimelineRowFullScreenSupport.terminalTraceUpdate(configuration: configuration))
        }
        if entry.source?.snapshot.isDone != true, let trace = entry.source {
            trace.update(ToolTimelineRowFullScreenSupport.sourceTraceUpdate(
                configuration: configuration,
                outputCopyText: configuration.copyOutputText
            ) ?? SourceSnapshot(text: "", filePath: nil, isDone: true, finalContent: nil))
        }
    }

    private func settle(_ entry: Entry) {
        if let trace = entry.thinking, !trace.snapshot.isDone {
            trace.update(ThinkingSnapshot(text: trace.snapshot.text, isDone: true))
        }
        if let trace = entry.terminal, !trace.snapshot.isDone {
            let current = trace.snapshot
            trace.update(TerminalSnapshot(
                output: current.output,
                command: current.command,
                isDone: true,
                sidecarSource: current.sidecarSource
            ))
        }
        if let trace = entry.source, !trace.snapshot.isDone {
            let current = trace.snapshot
            trace.update(SourceSnapshot(
                text: current.text,
                filePath: current.filePath,
                isDone: true,
                finalContent: current.finalContent
            ))
        }
    }

    // MARK: - Teardown

    /// A new session's reader must not inherit the last one's text.
    func reset() {
        for entry in entries.values { settle(entry) }
        entries.removeAll()
    }

    /// The timeline is going away: no reader may be left waiting on a trace.
    func settleAll() {
        for entry in entries.values { settle(entry) }
        entries.removeAll()
    }
}
