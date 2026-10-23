import UIKit

/// The live traces behind the full-screen readers a timeline opened, by item id.
///
/// A reader outlives the row that opened it. Opening one pushes a page, so the
/// chat leaves the window, the timeline's own apply keeps running (the session
/// runtime stays bound while a page covers the chat), but UIKit configures no
/// cell for a row outside the viewport — and the thinking row a reader follows
/// is usually just above the streaming tail. So the text a reader shows is fed
/// from the apply's rows by item id, one stream per open reader, never from
/// whichever cell happens to be configured.
@MainActor
final class ChatTimelineReaderTraces {
    private final class Entry {
        var thinking: ThinkingTraceStream?
        var terminal: TerminalTraceStream?
        var source: SourceTraceStream?
    }

    private var entries: [String: Entry] = [:]
    /// The rows a reader follows, from the last apply. Only these ids are kept.
    private var watchedItemByID: [String: ChatItem] = [:]
    private var liveRowIDs: Set<String> = []

    var isEmpty: Bool { entries.isEmpty }

    // MARK: - Opening

    /// The row's thinking trace, seeded from what the row shows right now.
    func thinkingTrace(itemID: String, text: String, isDone: Bool) -> ThinkingTraceStream {
        let entry = entry(for: itemID)
        if let stream = entry.thinking {
            stream.update(text: text, isDone: isDone)
            return stream
        }
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

    /// Called by every apply, before rows are built. A thinking trace follows
    /// its item: the block's text, and `ThinkingTimelineRowConfiguration`'s
    /// rule for when the trace can no longer grow.
    func update(items: [ChatItem], liveRowIDs: Set<String>) {
        guard !entries.isEmpty else { return }
        watchedItemByID = [:]
        for item in items where entries[item.id] != nil {
            watchedItemByID[item.id] = item
        }
        self.liveRowIDs = liveRowIDs

        for (itemID, entry) in entries {
            guard let stream = entry.thinking,
                  case .thinking(_, let preview, _, let isDone) = watchedItemByID[itemID] else {
                continue
            }
            stream.update(
                text: preview.trimmingCharacters(in: .whitespacesAndNewlines),
                isDone: isDone && !liveRowIDs.contains(itemID)
            )
        }
    }

    /// Running calls whose reader follows the call's output or source. Only
    /// these cost a row build; a finished call's reader is already static.
    var runningToolItemIDs: [String] {
        entries.compactMap { itemID, entry in
            guard entry.terminal != nil || entry.source != nil,
                  case .toolCall(_, _, _, _, _, _, false) = watchedItemByID[itemID] else {
                return nil
            }
            return itemID
        }
    }

    func updateToolTraces(toolConfiguration: (String) -> ToolTimelineRowConfiguration?) {
        for itemID in runningToolItemIDs {
            guard let entry = entries[itemID], let configuration = toolConfiguration(itemID) else {
                continue
            }
            if let stream = entry.terminal {
                let trace = ToolTimelineRowFullScreenSupport.terminalTraceUpdate(
                    configuration: configuration
                )
                stream.completionSidecarSource = configuration.toolOutputSidecarSource
                stream.update(output: trace.output, command: trace.command, isDone: trace.isDone)
            }
            if let stream = entry.source {
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
    }

    /// A new session's reader must not inherit the last one's text.
    func reset() {
        entries.removeAll()
        watchedItemByID.removeAll()
        liveRowIDs.removeAll()
    }

    /// Rows the timeline no longer has can never grow again: settle their
    /// readers before dropping them, or one would stay live forever.
    func retainRows(in itemIDs: Set<String>) {
        guard !entries.isEmpty, !itemIDs.isEmpty else { return }
        for (itemID, entry) in entries where !itemIDs.contains(itemID) {
            if let stream = entry.thinking {
                stream.update(text: stream.snapshot.text, isDone: true)
            }
            if let stream = entry.terminal {
                stream.update(
                    output: stream.snapshot.output,
                    command: stream.snapshot.command,
                    isDone: true
                )
            }
            if let stream = entry.source {
                stream.update(
                    text: stream.snapshot.text,
                    filePath: stream.snapshot.filePath,
                    isDone: true,
                    finalContent: stream.snapshot.finalContent
                )
            }
            entries[itemID] = nil
        }
    }
}
