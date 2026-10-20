import Foundation

/// One chat runtime's durable conversation stream (`capabilities.conversationStream` v1).
///
/// `ChatSessionManager` creates it when the focused socket connects a durable session, sends
/// what it builds (`attach`, `older`), and hands it the stream's frames and command results.
/// It keeps the `ConversationReplica` across reconnects of the runtime and feeds the
/// timeline from it: committed entries through `ConversationCommittedProjection` and
/// `TimelineReducer.applyConversationCommitted`, `pi.live` through
/// `ConversationLiveProjector` and `TimelineReducer.applyLiveTail`. While it exists the
/// session's classic timeline events are ignored and trace catch-up is not used.
///
/// A `live` driver follows a subagent's conversation on its parent's socket instead
/// (`attach { mode: live }`): its replica holds only `pi.live` and `pi.inbox`, and `liveTail`
/// is what the parent shows under the tool row that names it.
/// Wire: `dev/architecture-server/durable-conversation-stream.md`.
@MainActor @Observable
final class ConversationStreamDriver {
    enum FrameOutcome: Equatable {
        /// Applied to the replica and the timeline.
        case applied
        /// Applied to the replica only; the timeline needs `resync` (presentation paused).
        case deferred
        /// Dropped while waiting for the snapshot of a fresh attach.
        case ignored
        /// The replica is no longer a faithful copy; attach again without a cursor.
        case applyFailed(String)
    }

    enum CommandOutcome: Equatable {
        case attached
        /// The attach failed for the first time: attach again without a cursor.
        case retryFreshAttach
        /// The fresh attach failed too.
        case attachFailed(String)
        case older
        /// The answer to an attach a later one replaced.
        case superseded
    }

    /// The conversation a `live` driver follows; nil for the session's own, in full.
    let liveConversationId: Int?
    /// `replica.hasOlder`, observed by the timeline's "load earlier" control.
    private(set) var hasOlder = false
    @ObservationIgnored private(set) var replica = ConversationReplica()
    /// Full mode: the child conversations its tool calls name.
    @ObservationIgnored private(set) var children = ConversationChildIndex()
    /// Live mode: what the replica's `pi.live` shows.
    @ObservationIgnored private(set) var liveTail = TimelineLiveTail()
    @ObservationIgnored private var committed = ConversationCommittedProjection()
    @ObservationIgnored private var live = ConversationLiveProjector()
    /// The reducer does not hold the replica's rows: it was reset, or frames applied while
    /// presentation was paused.
    @ObservationIgnored private var reducerNeedsResync = true
    /// A fresh attach replaces the subscription; frames before its snapshot are stale.
    @ObservationIgnored private var awaitingSnapshot = false
    @ObservationIgnored private var attachRequestId: String?
    @ObservationIgnored private var supersededAttachIds: Set<String> = []
    @ObservationIgnored private var freshAttachRetried = false
    @ObservationIgnored private var olderRequestIds: Set<String> = []
    @ObservationIgnored private var waiters: [String: CheckedContinuation<Bool, Never>] = [:]

    init() {
        liveConversationId = nil
    }

    init(liveConversationId: Int) {
        self.liveConversationId = liveConversationId
    }

    /// The committed rows as trace events, for the timeline cache.
    var committedEvents: [TraceEvent] { committed.events }

    /// `attach` resumes from the replica's cursor when it holds a conversation; otherwise
    /// (first open, `fresh`, or after a failed apply) the server answers with a snapshot.
    /// A live attach always gets a snapshot.
    func attachRequest(fresh: Bool) -> (message: ClientMessage, requestId: String) {
        let requestId = "attach-\(UUID().uuidString)"
        if let previous = attachRequestId { supersededAttachIds.insert(previous) }
        attachRequestId = requestId
        // A socket's first attach starts its own budget of one fresh retry; the retry
        // itself (`fresh`) keeps it spent.
        if !fresh { freshAttachRetried = false }
        var attach = ConversationStreamAttach(requestId: requestId)
        if let liveConversationId {
            attach.conversationId = liveConversationId
            attach.mode = .live
            awaitingSnapshot = true
        } else if !fresh, let conversationId = replica.conversationId, let cursor = replica.resumeCursor {
            attach.conversationId = conversationId
            attach.afterEntryId = cursor
        } else {
            awaitingSnapshot = true
        }
        return (.conversationAttach(attach), requestId)
    }

    /// Live mode: end this conversation's stream on the socket. Its frames that arrive after
    /// are no longer routed here.
    func detachRequest() -> ClientMessage? {
        liveConversationId.map { .conversationDetach(.init(conversationId: $0)) }
    }

    /// `older` before the oldest held entry, or nil when there is nothing older.
    func olderRequest(limit: Int? = nil) -> (message: ClientMessage, requestId: String)? {
        guard replica.hasOlder, let before = replica.oldestEntryId, !awaitingSnapshot else { return nil }
        let requestId = "older-\(UUID().uuidString)"
        olderRequestIds.insert(requestId)
        return (.conversationOlder(.init(beforeEntryId: before, limit: limit, requestId: requestId)), requestId)
    }

    /// Send `message` and wait for its `command_result`, which the server sends after the
    /// frame it answers with. False on failure, send error, or timeout.
    func perform(
        _ request: (message: ClientMessage, requestId: String),
        timeout: Duration,
        send: @escaping @MainActor (ClientMessage) async throws -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            waiters[request.requestId] = continuation
            Task { @MainActor [weak self] in
                do {
                    try await send(request.message)
                } catch {
                    self?.resolve(request.requestId, false)
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolve(request.requestId, false)
            }
        }
    }

    /// Our `command_result`s, nil for any other.
    func commandResult(requestId: String, success: Bool, error: String?) -> CommandOutcome? {
        if olderRequestIds.remove(requestId) != nil {
            resolve(requestId, success)
            return .older
        }
        if supersededAttachIds.remove(requestId) != nil {
            resolve(requestId, success)
            return .superseded
        }
        guard requestId == attachRequestId else { return nil }
        resolve(requestId, success)
        attachRequestId = nil
        if success {
            freshAttachRetried = false
            return .attached
        }
        if freshAttachRetried {
            return .attachFailed(error ?? "attach failed")
        }
        freshAttachRetried = true
        return .retryFreshAttach
    }

    func receive(
        _ frame: ConversationStreamServerMessage,
        into reducer: TimelineReducer,
        presentationPaused: Bool
    ) -> FrameOutcome {
        if awaitingSnapshot {
            guard case .snapshot = frame else { return .ignored }
        }
        let previousCount = replica.entries.count
        let previousCursor = replica.resumeCursor
        do {
            try replica.apply(frame)
        } catch {
            replica = ConversationReplica()
            reducerNeedsResync = true
            awaitingSnapshot = true
            return .applyFailed(String(describing: error))
        }
        awaitingSnapshot = false
        if hasOlder != replica.hasOlder { hasOlder = replica.hasOlder }
        indexChildren(frame, previousCount: previousCount, previousCursor: previousCursor)
        if presentationPaused || reducerNeedsResync {
            reducerNeedsResync = true
            if presentationPaused { return .deferred }
            resync(reducer)
            return .applied
        }

        var committedChanged = true
        var liveChanged = true
        /// Set when only events after this index are new.
        var appendStart: Int?
        switch frame {
        case .snapshot, .older:
            committed.reproject(replica.entries)
        case .update(let update):
            liveChanged = update.docs?.keys.contains("pi.live") == true
            if let entries = update.entries, !entries.isEmpty {
                // Every new entry is newer than all held ones in practice: project only those.
                let appended = previousCursor.map { cursor in entries.allSatisfy { $0.id > cursor } }
                    ?? (previousCount == 0)
                let start = committed.events.count
                if appended, committed.append(replica.entries[previousCount...]) {
                    appendStart = start
                } else {
                    committed.reproject(replica.entries)
                }
            } else {
                committedChanged = false
            }
        }
        if committedChanged {
            reducer.applyConversationCommitted(committed.events, appendStart: appendStart)
        }
        // The committed apply takes the live rows out, so they are always restored after it.
        if committedChanged || liveChanged {
            reducer.applyLiveTail(live.tail(from: replica.docs["pi.live"]))
        }
        return .applied
    }

    /// Live mode: apply a frame of the followed conversation and project its `pi.live`.
    func receiveLive(_ frame: ConversationStreamServerMessage) -> FrameOutcome {
        if awaitingSnapshot {
            guard case .snapshot = frame else { return .ignored }
        }
        do {
            try replica.apply(frame)
        } catch {
            replica = ConversationReplica()
            liveTail = TimelineLiveTail()
            awaitingSnapshot = true
            return .applyFailed(String(describing: error))
        }
        awaitingSnapshot = false
        liveTail = live.tail(from: replica.docs["pi.live"])
        return .applied
    }

    /// Keep `children` current with the frame just applied: committed tool results are indexed
    /// as they append, the running round's calls from `pi.live`.
    private func indexChildren(
        _ frame: ConversationStreamServerMessage,
        previousCount: Int,
        previousCursor: Int?
    ) {
        switch frame {
        case .snapshot, .older:
            children.reindex(replica.entries)
            children.updateLive(replica.docs["pi.live"])
        case .update(let update):
            if let entries = update.entries, !entries.isEmpty {
                let appended = previousCursor.map { cursor in entries.allSatisfy { $0.id > cursor } }
                    ?? (previousCount == 0)
                if appended, previousCount <= replica.entries.count {
                    children.append(replica.entries[previousCount...])
                } else {
                    children.reindex(replica.entries)
                }
            }
            if update.docs?.keys.contains("pi.live") == true {
                children.updateLive(replica.docs["pi.live"])
            }
        }
    }

    /// Rebuild the timeline from the replica.
    func resync(_ reducer: TimelineReducer) {
        committed.reproject(replica.entries)
        reducer.applyConversationCommitted(committed.events)
        reducer.applyLiveTail(live.tail(from: replica.docs["pi.live"]))
        reducerNeedsResync = false
    }

    /// The reducer was reset (a new connect): the next frame rebuilds the timeline.
    func reducerWasReset() {
        reducerNeedsResync = true
    }

    /// The socket ended; nothing in flight will be answered.
    func cancelPendingRequests() {
        attachRequestId = nil
        freshAttachRetried = false
        supersededAttachIds.removeAll()
        olderRequestIds.removeAll()
        for requestId in Array(waiters.keys) { resolve(requestId, false) }
    }

    private func resolve(_ requestId: String, _ success: Bool) {
        waiters.removeValue(forKey: requestId)?.resume(returning: success)
    }
}
