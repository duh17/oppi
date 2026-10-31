import Foundation
import Observation
import Synchronization

/// Every session on the host's Rex server, its windows, and each terminal's
/// title, folder, and OSC 7501 records, in the shape of Rex's own API objects
/// (`session.view` and the `com.superlogical.terminal.*` block methods), which
/// `RexMirror` assembles from the subscription. Rex owns the state; Oppi only
/// reads it.
struct RexSnapshot: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        let blockID: String
        let label: String?
        let title: String?
        /// The folder the terminal last reported (OSC 7), as Rex keeps it: a
        /// `file://host/path` URL.
        let pwd: String?
        let records: [SSHTerminalPaneRecord]

        var status: SessionStatusKind? { SSHTerminalPaneRecord.headline(of: records) }

        /// The program that reported, else the terminal's title, else Rex's label.
        var displayName: String {
            let app = records.first { $0.id.isEmpty }?.app ?? records.first?.app
            return [app, title, label].compactMap { $0 }.first { !$0.isEmpty } ?? "Terminal"
        }
    }

    struct Window: Equatable, Sendable {
        let windowID: String
        let label: String?
        let focusedBlockID: String?
        let panes: [Pane]
    }

    struct Session: Equatable, Sendable {
        let sessionID: String
        let label: String?
        let activeWindowID: String?
        let windows: [Window]

        /// The pane Rex sends typing to: the focused pane of the active window.
        func isFocused(_ pane: Pane, in window: Window) -> Bool {
            window.windowID == activeWindowID && window.focusedBlockID == pane.blockID
        }
    }

    let sessions: [Session]

    func pane(session sessionID: String, block blockID: String) -> Pane? {
        sessions.first { $0.sessionID == sessionID }?.windows.lazy.flatMap(\.panes).first { $0.blockID == blockID }
    }

    /// Panes waiting at an approval, question, or sign-in.
    var needsAttention: Int {
        sessions.reduce(0) { total, session in
            total + session.windows.reduce(0) { $0 + $1.panes.filter { $0.status?.isBlocked == true }.count }
        }
    }
}

/// A server event the overview follows, parsed on the SSH event loop from the
/// frame Rex sent (`{"type":"event","seq":…,"payload":{"type":…,"payload":…}}`).
/// Session events nest one level deeper (`session_event`), and a terminal's own
/// events (`title_changed`, …) one more (`block_event`). Everything else Rex
/// sends — clients joining, output sizes, bells, progress — is not parsed.
enum RexEvent: Sendable, Equatable {
    case sessionCreated(session: String)
    case sessionDestroyed(session: String)
    /// The session's view changed; Rex sends only the new revision.
    case viewChanged(session: String, revision: Int)
    case blockCreated(session: String, block: String)
    case blockClosed(session: String, block: String)
    case title(session: String, block: String, String)
    case pwd(session: String, block: String, String)
    case status(session: String, block: String, SSHTerminalPaneRecord)
    case statusRemoved(session: String, block: String, ids: [String])
    case childExited(session: String, block: String)

    static let terminalCreator = "com.superlogical.terminal"

    /// The session the event is about.
    var session: String {
        switch self {
        case .sessionCreated(let session), .sessionDestroyed(let session), .viewChanged(let session, _),
             .blockCreated(let session, _), .blockClosed(let session, _), .title(let session, _, _),
             .pwd(let session, _, _), .status(let session, _, _), .statusRemoved(let session, _, _),
             .childExited(let session, _):
            session
        }
    }

    init?(frame: [String: Any]) {
        guard let event = frame["payload"] as? [String: Any], let type = event["type"] as? String,
              let body = event["payload"] as? [String: Any] else { return nil }
        switch type {
        case "session_created":
            guard let id = (body["session"] as? [String: Any])?["session_id"] as? String else { return nil }
            self = .sessionCreated(session: id)
        case "session_destroyed":
            guard let id = body["session_id"] as? String else { return nil }
            self = .sessionDestroyed(session: id)
        case "session_event":
            guard let session = body["session_id"] as? String, let inner = body["event"] as? [String: Any],
                  let name = inner["type"] as? String, let payload = inner["payload"] as? [String: Any],
                  let event = Self(session: session, name: name, payload: payload) else { return nil }
            self = event
        default:
            return nil
        }
    }

    private init?(session: String, name: String, payload: [String: Any]) {
        switch name {
        case "session_view_changed":
            guard let revision = payload["revision"] as? Int else { return nil }
            self = .viewChanged(session: session, revision: revision)
        case "block_created":
            guard let block = payload["block_id"] as? String else { return nil }
            self = .blockCreated(session: session, block: block)
        case "block_closed":
            guard let block = payload["block_id"] as? String else { return nil }
            self = .blockClosed(session: session, block: block)
        case "block_event":
            guard payload["creator_name"] as? String == Self.terminalCreator,
                  let block = payload["block_id"] as? String, let kind = payload["name"] as? String,
                  let body = payload["payload"] as? [String: Any] else { return nil }
            switch kind {
            case "title_changed":
                guard let title = body["title"] as? String else { return nil }
                self = .title(session: session, block: block, title)
            case "pwd_changed":
                guard let pwd = body["pwd"] as? String else { return nil }
                self = .pwd(session: session, block: block, pwd)
            case "program_status_changed":
                guard let record = body["record"], JSONSerialization.isValidJSONObject(record),
                      let data = try? JSONSerialization.data(withJSONObject: record),
                      let record = try? JSONDecoder().decode(SSHTerminalPaneRecord.self, from: data) else { return nil }
                self = .status(session: session, block: block, record)
            case "program_status_removed":
                guard let ids = body["ids"] as? [String] else { return nil }
                self = .statusRemoved(session: session, block: block, ids: ids)
            case "child_exited":
                self = .childExited(session: session, block: block)
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

/// What the overview knows of Rex between two reads: the sessions, their
/// views, and each terminal block's title, folder, and status. Pure state:
/// the monitor feeds it the bootstrap, view and block replies, and events, and
/// asks `needsWork` what is still to be read.
struct RexMirror {
    struct Block: Equatable {
        let id: String
        let label: String?
        let isTerminal: Bool
    }

    struct Window: Equatable {
        let id: String
        let label: String?
        let focusedBlockID: String?
        let blocks: [Block]
    }

    /// The three block calls' answers for one terminal block, kept apart from
    /// the view so a new view does not drop them.
    struct Details: Equatable {
        enum Field { case title, pwd, records }
        var title: String?
        var pwd: String?
        var records: [SSHTerminalPaneRecord] = []
        /// The three block calls have answered once, whatever they said.
        var loaded = false
        /// Fields an event set since the calls were sent; their answers are older.
        var touched: Set<Field> = []
    }

    struct SessionState {
        var label: String?
        /// The newest view applied; nil until one has been.
        var revision: Int?
        var activeWindowID: String?
        var windows: [Window] = []
        var viewed = false
        var details: [String: Details] = [:]
        /// The highest revision a `session_view_changed` announced.
        var wanted = -1
        var needsView = true
        /// A resync asked every terminal block to be read again.
        var reloadDetails = false
    }

    private(set) var order: [String] = []
    private(set) var sessions: [String: SessionState] = [:]

    /// The bootstrap's session list. Views already read stay on screen, but
    /// everything is read again: Rex has no event replay, and a restarted Rex
    /// numbers its revisions from zero.
    mutating func reset(listed: [(id: String, label: String?)]) {
        var next: [String: SessionState] = [:]
        for item in listed {
            var session = sessions[item.id] ?? SessionState(label: item.label)
            session.revision = nil
            session.wanted = -1
            session.needsView = true
            session.reloadDetails = true
            next[item.id] = session
        }
        order = listed.map(\.id)
        sessions = next
    }

    mutating func apply(_ event: RexEvent) {
        switch event {
        case .sessionCreated(let id):
            guard sessions[id] == nil else { return }
            order.append(id)
            sessions[id] = SessionState()
        case .sessionDestroyed(let id):
            remove(id)
        case .viewChanged(let id, let revision):
            if let wanted = sessions[id]?.wanted { sessions[id]?.wanted = max(wanted, revision) }
        case .blockCreated(let id, _):
            // The event does not say what the block is; the view does.
            sessions[id]?.needsView = true
        case .blockClosed(let id, let block):
            guard var session = sessions[id] else { return }
            session.details[block] = nil
            session.windows = session.windows.map { window in
                Window(id: window.id, label: window.label, focusedBlockID: window.focusedBlockID,
                       blocks: window.blocks.filter { $0.id != block })
            }
            sessions[id] = session
        case .title(let id, let block, let title):
            update(id, block, .title) { $0.title = title }
        case .pwd(let id, let block, let pwd):
            update(id, block, .pwd) { $0.pwd = pwd }
        case .status(let id, let block, let record):
            update(id, block, .records) { details in
                if let index = details.records.firstIndex(where: { $0.id == record.id }) {
                    details.records[index] = record
                } else {
                    details.records.append(record)
                }
            }
        case .statusRemoved(let id, let block, let ids):
            update(id, block, .records) { $0.records.removeAll { ids.contains($0.id) } }
        case .childExited(let id, let block):
            // The program is gone; so is whatever it reported.
            update(id, block, .records) { $0.records = [] }
        }
    }

    private mutating func update(_ id: String, _ block: String, _ field: Details.Field, _ change: (inout Details) -> Void) {
        guard sessions[id] != nil else { return }
        var details = sessions[id]?.details[block] ?? Details()
        change(&details)
        details.touched.insert(field)
        sessions[id]?.details[block] = details
    }

    mutating func remove(_ id: String) {
        sessions[id] = nil
        order.removeAll { $0 == id }
    }

    /// A view still to read: the first, one announced by an event, or one a
    /// block's arrival asked for.
    func needsView(_ id: String) -> Bool {
        guard let session = sessions[id] else { return false }
        return session.needsView || session.wanted > (session.revision ?? -1)
    }

    func needsWork(_ id: String) -> Bool {
        needsView(id) || !blocksNeedingDetails(id).isEmpty
    }

    mutating func beginView(_ id: String) { sessions[id]?.needsView = false }

    /// A view that could not be read; the next event or resync asks again.
    mutating func retryView(_ id: String) { sessions[id]?.needsView = true }

    /// Applies a view reply, unless a newer one already is: replies can
    /// overtake each other, and a revision only goes up.
    mutating func apply(view: RexView, to id: String) {
        guard var session = sessions[id] else { return }
        if let revision = view.revision, let applied = session.revision, revision < applied { return }
        // A view without a revision counts as at least the newest one announced,
        // so it is not asked for again until Rex announces a newer one.
        session.revision = view.revision ?? max(session.revision ?? -1, session.wanted)
        session.label = view.label ?? session.label
        session.activeWindowID = view.activeWindowID
        session.windows = (view.windows ?? []).map { window in
            Window(
                id: window.windowID, label: window.label, focusedBlockID: window.focusedBlockID,
                blocks: (window.layers ?? []).flatMap { $0.blocks ?? [] }.compactMap { block in
                    block.blockID.map { Block(id: $0, label: block.label, isTerminal: block.creatorName == RexEvent.terminalCreator) }
                }
            )
        }
        let present = Set(session.windows.flatMap { $0.blocks.map(\.id) })
        session.details = session.details.filter { present.contains($0.key) }
        session.viewed = true
        sessions[id] = session
    }

    /// Terminal blocks of the view whose three calls have not answered, or all
    /// of them after a resync.
    func blocksNeedingDetails(_ id: String) -> [String] {
        guard let session = sessions[id], session.viewed else { return [] }
        return session.windows.flatMap(\.blocks).filter { block in
            block.isTerminal && (session.reloadDetails || session.details[block.id]?.loaded != true)
        }.map(\.id)
    }

    /// The calls for these blocks are about to be sent: what an event sets
    /// from here on is newer than their answers.
    mutating func beginDetails(_ id: String, blocks: [String]) {
        sessions[id]?.reloadDetails = false
        for block in blocks { sessions[id]?.details[block, default: Details()].touched = [] }
    }

    mutating func apply(details reply: RexBlockDetails, block: String, in id: String) {
        guard var details = sessions[id]?.details[block] else { return }
        if !details.touched.contains(.title) { details.title = reply.title }
        if !details.touched.contains(.pwd) { details.pwd = reply.pwd }
        if !details.touched.contains(.records) { details.records = reply.records }
        details.loaded = true
        sessions[id]?.details[block] = details
    }

    func snapshot() -> RexSnapshot {
        RexSnapshot(sessions: order.compactMap { id in
            guard let session = sessions[id], session.viewed else { return nil }
            return RexSnapshot.Session(
                sessionID: id, label: session.label, activeWindowID: session.activeWindowID,
                windows: session.windows.map { window in
                    RexSnapshot.Window(
                        windowID: window.id, label: window.label, focusedBlockID: window.focusedBlockID,
                        panes: window.blocks.map { block in
                            let details = session.details[block.id]
                            return RexSnapshot.Pane(
                                blockID: block.id, label: block.label, title: details?.title,
                                pwd: details?.pwd, records: details?.records ?? []
                            )
                        }
                    )
                }
            )
        })
    }
}

/// `session.view`'s answer, reduced to what the overview reads.
struct RexView: Decodable, Sendable {
    struct Block: Decodable, Sendable {
        let blockID: String?
        let label: String?
        let creatorName: String?
        enum CodingKeys: String, CodingKey { case blockID = "block_id", label, creatorName = "creator_name" }
    }

    struct Layer: Decodable, Sendable {
        /// `tiled` for the layer that fills the window, else floating.
        let kind: String?
        let blocks: [Block]?
        /// Where each block sits. Nil for an empty layer, and for a tree this
        /// build cannot read: the blocks still list in layout order.
        let layout: RexLayout?

        enum CodingKeys: String, CodingKey { case kind, blocks, layout }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeIfPresent(String.self, forKey: .kind)
            blocks = try container.decodeIfPresent([Block].self, forKey: .blocks)
            layout = try? container.decodeIfPresent(RexLayout.self, forKey: .layout)
        }
    }

    struct Window: Decodable, Sendable {
        let windowID: String
        let label: String?
        let focusedBlockID: String?
        let layers: [Layer]?
        enum CodingKeys: String, CodingKey {
            case windowID = "window_id", label, focusedBlockID = "focused_block_id", layers
        }
    }

    let revision: Int?
    let label: String?
    let activeWindowID: String?
    let windows: [Window]?

    enum CodingKeys: String, CodingKey {
        case revision, label, activeWindowID = "active_window_id", windows
    }
}

/// A layer's layout tree from `session.view`: a block at a place, or a split
/// of two such nodes. A rect is `[x, y, width, height]` in fractions of the
/// window.
indirect enum RexLayout: Decodable, Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        /// Before on the left, after on the right.
        case horizontal
        /// Before above, after below.
        case vertical
    }

    case block(id: String, rect: [Double])
    case split(direction: Direction, ratio: Double, before: Self, after: Self, rect: [Double])

    private enum CodingKeys: String, CodingKey { case rect, blockID = "block_id", split }
    private enum SplitKeys: String, CodingKey { case direction, ratio, before, after }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rect = try container.decode([Double].self, forKey: .rect)
        guard rect.count == 4 else {
            throw DecodingError.dataCorruptedError(forKey: .rect, in: container, debugDescription: "a rect has four numbers")
        }
        if let split = try container.decodeIfPresent(SplitBody.self, forKey: .split) {
            self = .split(direction: split.direction, ratio: split.ratio, before: split.before, after: split.after, rect: rect)
        } else if let id = try container.decodeIfPresent(String.self, forKey: .blockID) {
            self = .block(id: id, rect: rect)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .blockID, in: container, debugDescription: "a node with neither a block nor a split")
        }
    }

    private struct SplitBody: Decodable {
        let direction: Direction
        let ratio: Double
        let before: RexLayout
        let after: RexLayout

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: SplitKeys.self)
            // A direction this build does not know draws as horizontal, as Rex's API page says.
            direction = try container.decode(String.self, forKey: .direction) == "vertical" ? .vertical : .horizontal
            ratio = try container.decode(Double.self, forKey: .ratio)
            before = try container.decode(RexLayout.self, forKey: .before)
            after = try container.decode(RexLayout.self, forKey: .after)
        }
    }

    /// The blocks in layout order: an in-order walk, before then after.
    var leaves: [(id: String, rect: [Double])] {
        switch self {
        case .block(let id, let rect): [(id, rect)]
        case .split(_, _, let before, let after, _): before.leaves + after.leaves
        }
    }
}

/// A terminal block's title, folder, and status records, as the three block
/// calls answered; a call that failed leaves its field out.
struct RexBlockDetails: Sendable {
    var title: String?
    var pwd: String?
    var records: [SSHTerminalPaneRecord] = []
}

/// Where the SSH event loop leaves parsed events for the main actor: they pile
/// up here and one wake-up drains them all, so a burst costs one hop, not one
/// per event.
private final class RexEventInbox: Sendable {
    private struct State {
        var events: [RexEvent] = []
        var ended: (any Error)?
    }

    /// Signalled (coalesced) when events are waiting or the connection ended.
    let wake: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let state = Mutex(State())

    init() {
        (wake, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    func push(_ event: RexEvent) {
        state.withLock { $0.events.append(event) }
        continuation.yield()
    }

    func end(_ error: any Error) {
        state.withLock { if $0.ended == nil { $0.ended = error } }
        continuation.yield()
    }

    func nudge() { continuation.yield() }

    var ended: (any Error)? { state.withLock { $0.ended } }

    func drain() -> [RexEvent] {
        state.withLock { state in
            defer { state.events = [] }
            return state.events
        }
    }
}

/// A connection `RexMonitor` can follow Rex on: it opens the bridge to Rex's
/// socket as a stream, and says whether it is still up. A terminal's channel
/// and a Rex host's own sessions connection (`SSHConnection`) are both one.
@MainActor
protocol RexStreamHost {
    var isConnected: Bool { get }
    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream
}

extension SSHTerminalChannel: RexStreamHost {
    var isConnected: Bool { connected }
}

extension SSHConnection: RexStreamHost {
    var isConnected: Bool { channel.isActive }

    func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
        try await openStream(command: command, inboundFlow: nil, sink: sink)
    }
}

/// Why Rex cannot be read on a host, which a Rex host's sessions screen (it
/// exists only to show Rex) answers with different advice. The bridge's own
/// exit status says which (`RexBridge`), at no cost beyond the one exec.
enum RexAbsence: Equatable, Sendable {
    /// The host has no `nc`, or one without Unix sockets (`-U`) (exit 126).
    case noNc
    /// `rex` is not on the host (exit 5).
    case notInstalled
    /// `rex` is installed and no Rex server is listening (exit 4).
    case notRunning

    /// Asking again cannot help until someone changes the host, so the monitor
    /// stops until a pull to refresh. A Rex that is not running may be
    /// started, so it is asked again with backoff.
    var givesUp: Bool { self != .notRunning }

    var advice: String {
        switch self {
        case .noNc:
            "This host has no nc that supports Unix sockets (nc -U), which Oppi uses to reach Rex. Install one, such as netcat-openbsd, then pull down to try again."
        case .notInstalled:
            "Rex is not installed on this host. Install it, then pull down to try again."
        case .notRunning:
            "Rex is not running on this host. Start it (rex server start) and this list fills in."
        }
    }
}

/// Follows a host's Rex server while a terminal is connected, or while a Rex
/// host's sessions screen shows, so the bar can offer the session list and a
/// needs-you count, and a tapped pane opens on this device.
///
/// It subscribes instead of polling: one `nc -U` stream (`RexBridge.command`)
/// on the SSH connection speaks Rex's control protocol, reads the
/// whole server once (`session.attach_all`, then `session.view` and the three
/// block calls per terminal), and from then on patches that picture from Rex's
/// events. `session.attach` is not used: the overview needs events and
/// views, and attaching would put this client in every session's client list.
///
/// Rex replays no events, so whatever the stream missed is caught up by
/// reading everything again: after a dropped stream, and when the sheet opens.
/// Backgrounding needs nothing of its own: the connection closes (the terminal
/// registry after its grace period, the sessions screen at once), the stream
/// ends with it, and the screen restarts `run` when it is back.
///
/// A host without `nc` or without Rex is detected once and not asked again
/// until a pull to refresh (`retry()`); a Rex that is not running, or a stream
/// that drops, is retried with backoff, since Rex may start or the network
/// return.
@MainActor @Observable
final class RexMonitor: SSHTerminalOverviewSource {
    /// Why a subscription ended, for the delay before the next one.
    enum Retry: Equatable {
        /// Rex is not running (bridge exit 4); it may be started, so ask
        /// again, but not as often as for a dropped stream.
        case notRunning
        case dropped

        /// 15 s, doubling to 60 s, for a Rex that is not running; 1 s,
        /// doubling to 30 s, otherwise. `failures` counts the consecutive
        /// subscriptions that ended without reading Rex.
        static func delay(_ retry: Retry, failures: Int) -> Duration {
            let (first, cap) = retry == .notRunning ? (15, 60) : (1, 30)
            return .seconds(min(cap, first << min(max(failures - 1, 0), 6)))
        }
    }

    let title = "Rex"
    let identifierPrefix = "sshTerminal.rex"
    /// The last snapshot read. A stream that fails keeps it on screen, as what
    /// Rex last reported, and reports `failure`.
    private(set) var snapshot: RexSnapshot?
    private(set) var failure: String?
    /// Why Rex could not be read, until it is read again.
    private(set) var absence: RexAbsence?
    private(set) var focusFailure: String?
    /// The sheet is open. Opening it reads Rex once more, as a safety net for
    /// anything the stream missed; the stream itself stays as quick as it is.
    var watching = false {
        didSet {
            if !watching {
                focusFailure = nil
            } else if !oldValue {
                requestResync()
            }
        }
    }
    /// Opens a tapped pane on this device: the terminal screen shows it in a
    /// terminal of its own (`SSHTerminalConnectSession.openRexPane`).
    @ObservationIgnored var openPane: ((RexPaneTarget) -> Void)?
    /// What the host answered, for whoever remembers which hosts have Rex
    /// (`SSHTerminalRexHostStore`): called on each subscription that reached
    /// Rex, and each one that found out why it could not.
    @ObservationIgnored var onFinding: (@MainActor (Finding) -> Void)?

    enum Finding: Equatable {
        /// The first full read of a subscription succeeded: Rex is there.
        case reached
        case absent(RexAbsence)
    }

    /// How long a burst of changes waits before it reaches `snapshot`, so a
    /// busy pane is one UI update, not one per event.
    @ObservationIgnored private let publishDelay: Duration
    @ObservationIgnored private let retryDelay: @MainActor (Retry, Int) -> Duration
    @ObservationIgnored private var mirror = RexMirror()
    /// One read in flight per session that needs one (`fetch`).
    @ObservationIgnored private var fetchers: [String: Task<Void, Never>] = [:]
    /// Which subscription the fetchers belong to: a cancelled one finishes
    /// late and must not touch the next one's state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inbox: RexEventInbox?
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    /// False until the subscription's first full read: a half-read picture is
    /// never published over the last complete one.
    @ObservationIgnored private var publishing = false
    @ObservationIgnored private var resyncRequested = false
    @ObservationIgnored private var resyncWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var backoff: Task<Void, Never>?
    /// The open stream's control connection once it has read the server,
    /// which the calls the person makes (`createSession`, `setLabel`,
    /// `destroy`) go over: it is attached to every session (`session.attach_all`),
    /// which Rex needs of a caller that destroys one.
    @ObservationIgnored private var control: RexControl?

    var available: Bool { snapshot != nil }
    /// `run` has stopped for good (no `nc`, no Rex), until `retry()`.
    var gaveUp: Bool { absence?.givesUp == true }
    /// Rex can be asked to change things: it has been read, and the stream
    /// has not failed since.
    var canManage: Bool { snapshot != nil && failure == nil }
    /// Waiting panes that are still known to wait: a Rex that stopped answering
    /// does not keep the badge lit with its last report.
    var needsAttention: Int { failure == nil ? snapshot?.needsAttention ?? 0 : 0 }

    init(
        publishDelay: Duration = .milliseconds(150),
        retryDelay: @escaping @MainActor (Retry, Int) -> Duration = { Retry.delay($0, failures: $1) }
    ) {
        self.publishDelay = publishDelay
        self.retryDelay = retryDelay
    }

    /// The terminal's overview source: `run(over:)` on its channel.
    func run(on channel: SSHTerminalChannel) async {
        await run(over: channel)
    }

    /// Subscribes until the task is cancelled, the connection goes, or the
    /// host turns out to have no `nc` or no Rex.
    func run(over host: any RexStreamHost) async {
        var failures = 0
        while !Task.isCancelled, host.isConnected {
            var synced = false
            let retry: Retry
            do {
                try await subscribe(on: host, synced: &synced)
                return
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                switch error as? RexClientError {
                case .bridgeMissing?: absence = .noNc
                case .notInstalled?: absence = .notInstalled
                case .notRunning?: absence = .notRunning
                default: absence = nil
                }
                if let absence { onFinding?(.absent(absence)) }
                if let absence, absence.givesUp {
                    snapshot = nil
                    failure = nil
                    return
                }
                retry = absence == .notRunning ? .notRunning : .dropped
                failure = error.localizedDescription
            }
            failures = synced ? 1 : failures + 1
            await pause(retryDelay(retry, failures))
        }
    }

    /// Reads Rex once more; a pull-to-refresh waits for it. With no stream
    /// open, it does not wait out the retry delay.
    func refresh(on channel: SSHTerminalChannel) async {
        await resync()
    }

    func resync() async {
        guard inbox != nil else {
            backoff?.cancel()
            return
        }
        requestResync()
        await withCheckedContinuation { resyncWaiters.append($0) }
    }

    /// Forgets that the host had no `nc` or no Rex, so `run` may be started
    /// again (a pull to refresh, after the user fixed the host).
    func retry() {
        guard gaveUp else { return }
        absence = nil
    }

    private func requestResync() {
        guard let inbox else {
            backoff?.cancel()
            return
        }
        resyncRequested = true
        inbox.nudge()
    }

    /// Sleeps out a retry delay; `refresh` and the sheet opening cut it short.
    private func pause(_ delay: Duration) async {
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: delay) }
        backoff = sleeper
        await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
        backoff = nil
    }

    /// One stream: open, read everything, then apply events until it ends.
    /// Throws the reason it ended; returns only when the task is cancelled.
    private func subscribe(on host: any RexStreamHost, synced: inout Bool) async throws {
        let control = RexControl()
        let inbox = RexEventInbox()
        control.onEvent { frame in
            if let event = RexEvent(frame: frame) { inbox.push(event) }
        }
        control.onEnd { inbox.end($0) }
        let stream = try await host.openStream(command: RexBridge.command) { control.receive($0) }
        control.attach { try await stream.send($0) }
        generation += 1
        let mine = generation
        // A cancelled subscription's reads can outlive it (its calls end when
        // the host's close comes back), and they no longer clean up after
        // themselves: whatever it left is this subscription's to drop.
        fetchers.values.forEach { $0.cancel() }
        fetchers = [:]
        publishTask?.cancel()
        publishTask = nil
        self.inbox = inbox
        publishing = false
        defer {
            stream.close()
            if generation == mine {
                self.inbox = nil
                self.control = nil
                publishing = false
                publishTask?.cancel()
                publishTask = nil
                fetchers.values.forEach { $0.cancel() }
                fetchers = [:]
                finishResync()
            }
        }
        try await withTaskCancellationHandler {
            try await control.open()
            try await bootstrap(control, inbox, generation: mine)
            synced = true
            self.control = control
            onFinding?(.reached)
            for await _ in inbox.wake {
                let events = inbox.drain()
                for event in events { mirror.apply(event) }
                startFetchers(control)
                if !events.isEmpty { schedulePublish() }
                if let ended = inbox.ended { throw ended }
                if resyncRequested {
                    try await bootstrap(control, inbox, generation: mine)
                }
            }
        } onCancel: {
            stream.close()
        }
    }

    /// Reads the whole server: the session list (which also starts the events),
    /// then every session's view and terminal blocks. Publishes the result at
    /// once, since it is the first complete picture.
    private func bootstrap(_ control: RexControl, _ inbox: RexEventInbox, generation mine: Int) async throws {
        resyncRequested = false
        // Only a refresh that asked before this read started is answered by it.
        let serving = resyncWaiters
        resyncWaiters = []
        defer { for waiter in serving { waiter.resume() } }
        let answer = try await control.call("session.attach_all", ["event_scope": "all"])
        // A newer subscription owns the mirror now; this one only winds down.
        guard generation == mine else { throw CancellationError() }
        struct Listed: Decodable {
            struct Item: Decodable {
                let sessionID: String
                let label: String?
                enum CodingKeys: String, CodingKey { case sessionID = "session_id", label }
            }
            let sessions: [Item]?
        }
        guard let listed = try? JSONDecoder().decode(Listed.self, from: answer) else {
            throw RexClientError.unreadable("the session list")
        }
        mirror.reset(listed: (listed.sessions ?? []).map { ($0.sessionID, $0.label) })
        startFetchers(control)
        while generation == mine, let fetcher = fetchers.values.first { await fetcher.value }
        guard generation == mine else { throw CancellationError() }
        // A stream that ended while it was read leaves a picture with holes.
        if let ended = inbox.ended { throw ended }
        publishing = true
        publish()
    }

    private func finishResync() {
        let waiters = resyncWaiters
        resyncWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func startFetchers(_ control: RexControl) {
        let mine = generation
        for id in mirror.order where fetchers[id] == nil && mirror.needsWork(id) {
            fetchers[id] = Task { [weak self] in await self?.fetch(id, control, generation: mine) }
        }
    }

    /// Reads one session until nothing is missing: at most one `session.view`
    /// in flight, run again if an event announced a newer revision meanwhile,
    /// and the three block calls for each terminal block the view shows that
    /// has not been read.
    private func fetch(_ id: String, _ control: RexControl, generation mine: Int) async {
        defer {
            if generation == mine {
                fetchers[id] = nil
                schedulePublish()
            }
        }
        while generation == mine, !Task.isCancelled, mirror.needsWork(id) {
            if mirror.needsView(id) {
                mirror.beginView(id)
                do {
                    let answer = try await control.call("session.view", ["session_id": id])
                    guard generation == mine else { return }
                    guard let view = try? JSONDecoder().decode(RexView.self, from: answer) else {
                        mirror.retryView(id)
                        return
                    }
                    mirror.apply(view: view, to: id)
                    schedulePublish()
                } catch RexClientError.refused(let code, _) where code == "session_not_found" {
                    guard generation == mine else { return }
                    mirror.remove(id)
                    return
                } catch {
                    guard generation == mine else { return }
                    mirror.retryView(id)
                    return
                }
            }
            let blocks = mirror.blocksNeedingDetails(id)
            guard !blocks.isEmpty else { continue }
            mirror.beginDetails(id, blocks: blocks)
            await withTaskGroup(of: (String, RexBlockDetails).self) { group in
                for block in blocks {
                    group.addTask { (block, await Self.details(of: block, in: id, control)) }
                }
                for await (block, details) in group where generation == mine {
                    mirror.apply(details: details, block: block, in: id)
                    schedulePublish()
                }
            }
        }
    }

    /// A terminal block's title, folder, and status records. A call that
    /// fails (the block closed, an older Rex) leaves its field out.
    private nonisolated static func details(of block: String, in session: String, _ control: RexControl) async -> RexBlockDetails {
        func call(_ method: String) async -> Data? {
            try? await control.call("com.superlogical.terminal." + method, [
                "session_id": session, "block_id": block, "args": [String: Any](),
            ])
        }
        async let title = call("title"), pwd = call("pwd"), status = call("program_status")
        struct Title: Decodable { let title: String? }
        struct Pwd: Decodable { let pwd: String? }
        struct Status: Decodable {
            let records: [SSHTerminalPaneRecord]?
        }
        let decoder = JSONDecoder()
        return RexBlockDetails(
            title: await title.flatMap { try? decoder.decode(Title.self, from: $0).title },
            pwd: await pwd.flatMap { try? decoder.decode(Pwd.self, from: $0).pwd },
            records: await status.flatMap { try? decoder.decode(Status.self, from: $0).records } ?? []
        )
    }

    private func publish() {
        failure = nil
        absence = nil
        let next = mirror.snapshot()
        if next != snapshot { snapshot = next }
    }

    /// Publishes after `publishDelay`, however many changes land meanwhile.
    private func schedulePublish() {
        guard publishing, publishTask == nil else { return }
        publishTask = Task { [weak self, publishDelay] in
            try? await Task.sleep(for: publishDelay)
            guard !Task.isCancelled, let self else { return }
            publishTask = nil
            publish()
        }
    }

    // MARK: Changing Rex

    /// The calls below change Rex, and the monitor's own events show the
    /// result (`session_created`, `session_view_changed`, `session_destroyed`):
    /// nothing here edits the snapshot. A refusal (`RexClientError.refused`)
    /// reaches the caller as it came.
    private func openControl() throws -> RexControl {
        guard let control else { throw RexClientError.connectionClosed }
        return control
    }

    /// A new session with one window holding a shell. The server picks its
    /// name. Returns the shell's pane, to open it.
    func createSession() async throws -> RexPaneTarget {
        let control = try openControl()
        let answer = try await control.call("session.create", [
            "initial_windows": [["layout": ["block": ["flavor": RexSessionConnection.shellFlavor]]]],
        ])
        struct Created: Decodable {
            struct Window: Decodable {
                let blockIDs: [String]?
                enum CodingKeys: String, CodingKey { case blockIDs = "block_ids" }
            }
            let sessionID: String
            let initialWindows: [Window]?
            enum CodingKeys: String, CodingKey { case sessionID = "session_id", initialWindows = "initial_windows" }
        }
        guard let created = try? JSONDecoder().decode(Created.self, from: answer),
              let block = created.initialWindows?.first?.blockIDs?.first else {
            throw RexClientError.unreadable("the new session")
        }
        // The caller owns the blocks it creates; the terminal that opens the
        // pane takes it for itself, so this one gives its claim back.
        _ = try? await control.call("session.disown_block", ["session_id": created.sessionID, "block_ids": [block]])
        return RexPaneTarget(sessionID: created.sessionID, blockID: block, label: "Shell")
    }

    /// Names a session. An empty label (or only white space) restores the name
    /// Rex chose when it made the session.
    func setLabel(_ label: String, ofSession id: String) async throws {
        _ = try await openControl().call("session.set_label", ["session_id": id, "label": label])
    }

    /// Destroys a session and closes every pane in it.
    func destroy(session id: String) async throws {
        _ = try await openControl().call("session.destroy", ["session_id": id])
    }

    func activate(_ focus: SSHTerminalOverviewFocus, on channel: SSHTerminalChannel) async -> Bool {
        open(focus)
    }

    /// A pane row opens that pane on this device (`openPane`). Session rows
    /// offer nothing.
    func open(_ focus: SSHTerminalOverviewFocus) -> Bool {
        focusFailure = nil
        guard let sessionID = focus.scope, !focus.isGroup,
              let pane = snapshot?.pane(session: sessionID, block: focus.id), let openPane else {
            focusFailure = "This pane is no longer in Rex."
            return false
        }
        openPane(RexPaneTarget(sessionID: sessionID, blockID: pane.blockID, label: pane.displayName))
        return true
    }

    /// One section per session: the session, then its panes in window order,
    /// each with its program's status. The pane Rex types into is bold. A
    /// session with several windows names each pane's window.
    var sections: [SSHTerminalOverviewSection] {
        var sections: [SSHTerminalOverviewSection] = []
        // Why Rex cannot be read, with what to do about it; any other failure
        // shows as it came.
        if let reason = absence?.advice ?? failure {
            sections.append(.init(id: "failure", rows: [.init(id: "failure", title: reason, kind: .failure, focus: nil)]))
            if gaveUp { return sections }
        }
        guard let snapshot else {
            if failure == nil {
                sections.append(.init(id: "loading", rows: [.init(id: "loading", title: "Loading\u{2026}", kind: .placeholder, focus: nil)]))
            }
            return sections
        }
        if snapshot.sessions.isEmpty {
            sections.append(.init(id: "empty", rows: [.init(id: "empty", title: "No Rex sessions.", kind: .placeholder, focus: nil)]))
        }
        for session in snapshot.sessions {
            let key = "session|\(session.sessionID)"
            let namesWindows = session.windows.count > 1
            var rows: [SSHTerminalOverviewRow] = [.init(
                id: key, title: session.label ?? "Session", kind: .group(focused: false), focus: nil
            )]
            for window in session.windows {
                for pane in window.panes {
                    let name = pane.displayName
                    let title = pane.title.flatMap { $0.isEmpty || $0 == name ? nil : $0 }
                    rows.append(.init(
                        id: key + "|" + pane.blockID,
                        title: name,
                        kind: .item(
                            subtitle: [title, namesWindows ? window.label : nil].compactMap { $0 }.joined(separator: " \u{00B7} "),
                            focused: session.isFocused(pane, in: window),
                            status: pane.status.map { .known($0) } ?? .none
                        ),
                        focus: .init(scope: session.sessionID, id: pane.blockID, isGroup: false)
                    ))
                }
            }
            sections.append(.init(id: key, rows: rows))
        }
        return sections
    }
}
