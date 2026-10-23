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
/// Work per apply is bounded by the readers that are actually open: entries are
/// released once their reader lets go of the stream, and a trace that has
/// reported done is never fed again.
@MainActor
final class ChatTimelineReaderTraces {
    private final class Entry {
        var thinking: ThinkingTraceStream?
        var terminal: TerminalTraceStream?
        var source: SourceTraceStream?
        /// The last row this entry was fed, so an unchanged row costs one compare.
        var lastPreview: String?
        var lastIsLive: Bool?
        /// Opened, but no reader has attached yet. One apply may pass between
        /// handing a stream to a reader and that reader observing it, so the
        /// first pass without observers only clears this.
        var isPendingMount = true
    }

    private var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }

    /// Item ids with an open reader; a test and diagnostic surface.
    var openItemIDs: [String] { entries.keys.sorted() }

    var hasObservers: Bool {
        entries.values.contains { entry in
            entry.thinking?.hasObservers == true
                || entry.terminal?.hasObservers == true
                || entry.source?.hasObservers == true
        }
    }

    // MARK: - Opening

    /// The row's thinking trace, seeded from what the row shows right now.
    func thinkingTrace(itemID: String, text: String, isDone: Bool) -> ThinkingTraceStream {
        let entry = entry(for: itemID)
        if let stream = entry.thinking {
            stream.update(text: text, isDone: isDone)
            return stream
        }
        entry.lastPreview = text
        entry.lastIsLive = !isDone
        let stream = ThinkingTraceStream(text: text, isDone: isDone)
        entry.thinking = stream
        return stream
    }

    func terminalTrace(
        itemID: String,
        output: String,
        command: String?,
        isDone: Bool
    ) -> TerminalTraceStream {
        let entry = entry(for: itemID)
        if let stream = entry.terminal {
            stream.update(output: output, command: command, isDone: isDone)
            return stream
        }
        let stream = TerminalTraceStream(output: output, command: command, isDone: isDone)
        entry.terminal = stream
        return stream
    }

    func sourceTrace(
        itemID: String,
        text: String,
        filePath: String?,
        isDone: Bool,
        finalContent: FullScreenCodeContent?
    ) -> SourceTraceStream {
        let entry = entry(for: itemID)
        if let stream = entry.source {
            stream.update(text: text, filePath: filePath, isDone: isDone, finalContent: finalContent)
            return stream
        }
        let stream = SourceTraceStream(
            text: text,
            filePath: filePath,
            isDone: isDone,
            finalContent: finalContent
        )
        entry.source = stream
        return stream
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
    /// `itemExists` answers for the whole timeline, not the rendered rows, so a
    /// row folded into a collapsed work line keeps its reader instead of being
    /// treated as gone.
    func update(
        items: [ChatItem],
        liveRowIDs: Set<String>,
        itemExists: (String) -> Bool,
        toolConfiguration: (String, ChatItem) -> ToolTimelineRowConfiguration?
    ) {
        releaseClosedReaders()
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
        guard let stream = entry.thinking,
              case .thinking(_, let preview, _, let isDone) = item else {
            return
        }
        let isLive = liveRowIDs.contains(itemID)
        // The row's own text and liveness first: a trimmed copy and a delivered
        // snapshot are only worth it when the row actually changed.
        guard entry.lastPreview != preview || entry.lastIsLive != isLive else { return }
        entry.lastPreview = preview
        entry.lastIsLive = isLive
        stream.update(
            text: preview.trimmingCharacters(in: .whitespacesAndNewlines),
            isDone: ThinkingTimelineRowConfiguration.traceIsComplete(isDone: isDone, isLive: isLive)
        )
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
        if entry.terminal?.snapshot.isDone != true, let stream = entry.terminal {
            let trace = ToolTimelineRowFullScreenSupport.terminalTraceUpdate(configuration: configuration)
            stream.completionSidecarSource = configuration.toolOutputSidecarSource
            stream.update(output: trace.output, command: trace.command, isDone: trace.isDone)
        }
        if entry.source?.snapshot.isDone != true, let stream = entry.source {
            let trace = ToolTimelineRowFullScreenSupport.sourceTraceUpdate(
                configuration: configuration,
                outputCopyText: configuration.copyOutputText
            )
            stream.update(
                text: trace?.text ?? "",
                filePath: trace?.filePath,
                isDone: trace?.isDone ?? true,
                finalContent: trace?.finalContent
            )
        }
    }

    /// Released readers cost nothing: a stream nobody observes cannot be a
    /// reader's, and every apply would otherwise feed it forever.
    private func releaseClosedReaders() {
        for (itemID, entry) in entries {
            let observed = entry.thinking?.hasObservers == true
                || entry.terminal?.hasObservers == true
                || entry.source?.hasObservers == true
            if observed || entry.isPendingMount {
                entry.isPendingMount = false
            } else {
                entries[itemID] = nil
            }
        }
    }

    private func settle(_ entry: Entry) {
        if let stream = entry.thinking, !stream.snapshot.isDone {
            stream.update(text: stream.snapshot.text, isDone: true)
        }
        if let stream = entry.terminal, !stream.snapshot.isDone {
            stream.update(
                output: stream.snapshot.output,
                command: stream.snapshot.command,
                isDone: true
            )
        }
        if let stream = entry.source, !stream.snapshot.isDone {
            stream.update(
                text: stream.snapshot.text,
                filePath: stream.snapshot.filePath,
                isDone: true,
                finalContent: stream.snapshot.finalContent
            )
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
