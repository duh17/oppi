#if DEBUG
import Foundation
import Synchronization

/// A stand-in for one host's whole Rex server that keeps its state: the
/// sessions, their windows, and each pane's title, folder, and status. Every
/// connection it makes (`host()`, one per stream the monitor opens, as a new
/// SSH exec channel is a new bridge) answers `session.attach_all`,
/// `session.view`, and the terminal block calls from that state, and the calls
/// that change it (`session.create`, `session.set_label`, `session.destroy`)
/// change it and tell every open connection with the events Rex sends, so the
/// client under test sees what a real host's changes look like on the wire:
/// the response first, then the event.
///
/// It records every request (`requests`), so a test can say what was asked of
/// Rex and with which parameters.
final class RexFakeWorld: Sendable {
    struct Pane: Sendable {
        var block: String
        var title = ""
        /// What the terminal reported with OSC 7: a `file://host/path` URL.
        var pwd: String?
        /// The OSC 7501 records `program_status` answers, as Rex's JSON.
        var records = "[]"
    }

    struct Window: Sendable {
        var id: String
        var label: String
        /// The focused pane; the first when nil.
        var focused: String?
        var panes: [Pane]
    }

    struct Session: Sendable {
        var id: String
        var label: String
        /// The name the server chose, which an empty label restores.
        var serverLabel: String
        var windows: [Window]
        var revision = 1
    }

    private struct State {
        var sessions: [Session]
        var hosts: [RexFakeHost] = []
        var created = 0
        /// Methods answered with a refusal, as `(code, message)`.
        var refusing: [String: (code: String, message: String)] = [:]
    }

    private let state: Mutex<State>
    /// How long after a response an event follows it.
    private let eventDelay: Duration

    init(sessions: [Session], eventDelay: Duration = .milliseconds(20)) {
        state = Mutex(State(sessions: sessions))
        self.eventDelay = eventDelay
    }

    /// The sessions as they are now.
    var sessions: [Session] { state.withLock { $0.sessions } }

    /// Every request any connection made, in the order each one made them.
    var requests: [RexFakeHost.Request] { state.withLock { $0.hosts }.flatMap(\.requests) }

    func requests(_ method: String) -> [RexFakeHost.Request] { requests.filter { $0.method == method } }

    /// Answers `method` with a refusal from now on (nil: answers it again).
    func refuse(_ method: String, code: String?, message: String = "refused") {
        state.withLock { state in
            state.refusing[method] = code.map { ($0, message) }
        }
    }

    /// A new connection to this server.
    func host() -> RexFakeHost {
        let host = RexFakeHost { [self] in answer($0) }
        state.withLock { $0.hosts.append(host) }
        return host
    }

    // MARK: Answers

    private func answer(_ request: RexFakeHost.Request) -> RexFakeHost.Answer {
        if let refusal = state.withLock({ $0.refusing[request.method] }) {
            return .refuse(code: refusal.code, message: refusal.message)
        }
        let id = request.string("session_id")
        func session(_ id: String?) -> Session? { state.withLock { state in state.sessions.first { $0.id == id } } }
        func pane(_ request: RexFakeHost.Request) -> Pane? {
            let block = request.string("block_id")
            return session(id)?.windows.lazy.flatMap(\.panes).first { $0.block == block }
        }
        switch request.method {
        case "session.attach_all":
            let listed = state.withLock { $0.sessions }.map { #"{"session_id":\#(Self.quoted($0.id)),"label":\#(Self.quoted($0.label))}"# }
            return .result(#"{"sessions":[\#(listed.joined(separator: ","))]}"#)
        case "session.view":
            guard let found = session(id) else { return Self.notFound }
            return .result(Self.view(found))
        case "com.superlogical.terminal.title":
            return .result(#"{"title":\#(Self.quoted(pane(request)?.title ?? ""))}"#)
        case "com.superlogical.terminal.pwd":
            return .result(pane(request)?.pwd.map { #"{"pwd":\#(Self.quoted($0))}"# } ?? "{}")
        case "com.superlogical.terminal.program_status":
            return .result(#"{"records":\#(pane(request)?.records ?? "[]")}"#)
        case "session.create":
            return create(request)
        case "session.new_split":
            // The block the caller then opens. The session's view is not read again here:
            // the monitor's caller (a terminal) is the one that shows it.
            return .result(#"{"block_ids":["block:new-pane-1"]}"#)
        case "session.set_label":
            return setLabel(request)
        case "session.destroy":
            return destroy(request)
        case "session.disown_block", "session.own_block":
            return .result(#"{"blocks":[]}"#)
        default:
            return .result("{}")
        }
    }

    private static let notFound = RexFakeHost.Answer.refuse(code: "session_not_found", message: "no such session")

    /// A session with the windows it was asked for, or one shell window.
    private func create(_ request: RexFakeHost.Request) -> RexFakeHost.Answer {
        let label = request.string("label")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let windows = ((try? JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any])?["initial_windows"] as? [[String: Any]]) ?? []
        let created = state.withLock { state -> Session in
            state.created += 1
            let n = state.created
            let serverLabel = "new-session-\(n)"
            let count = max(windows.count, 0)
            let made = (0..<count).map { index -> Window in
                var pane = Pane(block: "block:new-\(n)-\(index + 1)")
                // A shell started in a folder reports it as its first prompt does.
                if let cwd = ((windows[index]["layout"] as? [String: Any])?["block"] as? [String: Any])
                    .flatMap({ $0["options"] as? [String: Any] })?["cwd"] as? String {
                    pane.pwd = "file://fake-host" + cwd
                }
                return Window(
                    id: "window:new-\(n)-\(index + 1)", label: (windows[index]["window_label"] as? String) ?? "Window \(index + 1)",
                    focused: nil, panes: [pane]
                )
            }
            let session = Session(
                id: "session:new-\(n)", label: (label?.isEmpty == false ? label : nil) ?? serverLabel,
                serverLabel: serverLabel, windows: made
            )
            state.sessions.append(session)
            return session
        }
        let blocks = created.windows.map { window in
            #"{"window_id":\#(Self.quoted(window.id)),"block_ids":[\#(window.panes.map { Self.quoted($0.block) }.joined(separator: ","))],"revision":1}"#
        }
        emit(after: "session_created", #"{"session":{"session_id":\#(Self.quoted(created.id))}}"#)
        return .result(#"{"session_id":\#(Self.quoted(created.id)),"initial_windows":[\#(blocks.joined(separator: ","))]}"#)
    }

    private func setLabel(_ request: RexFakeHost.Request) -> RexFakeHost.Answer {
        guard let id = request.string("session_id") else { return .refuse(code: "bad_request", message: "no session_id") }
        let label = (request.string("label") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if label.utf8.count > 128 || label.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            return .refuse(code: "bad_request", message: "the label is too long or has a control character")
        }
        let revision = state.withLock { state -> Int? in
            guard let index = state.sessions.firstIndex(where: { $0.id == id }) else { return nil }
            let next = label.isEmpty ? state.sessions[index].serverLabel : label
            guard next != state.sessions[index].label else { return state.sessions[index].revision }
            state.sessions[index].label = next
            state.sessions[index].revision += 1
            return state.sessions[index].revision
        }
        guard let revision else { return Self.notFound }
        emit(after: "session_event", #"{"session_id":\#(Self.quoted(id)),"event":{"type":"session_view_changed","payload":{"revision":\#(revision)}}}"#)
        return .result(#"{"revision":\#(revision)}"#)
    }

    private func destroy(_ request: RexFakeHost.Request) -> RexFakeHost.Answer {
        guard let id = request.string("session_id") else { return .refuse(code: "bad_request", message: "no session_id") }
        let found = state.withLock { state -> Bool in
            guard state.sessions.contains(where: { $0.id == id }) else { return false }
            state.sessions.removeAll { $0.id == id }
            return true
        }
        guard found else { return Self.notFound }
        emit(after: "session_destroyed", #"{"session_id":\#(Self.quoted(id))}"#)
        return .result("{}")
    }

    /// Sends the event on every open connection once the response is out.
    private func emit(after type: String, _ payload: String) {
        let hosts = state.withLock { $0.hosts }.filter { $0.isOpen && !$0.isClosed }
        let delay = eventDelay
        Task {
            try? await Task.sleep(for: delay)
            for host in hosts { host.emit(type, payload) }
        }
    }

    // MARK: Views

    private static func view(_ session: Session) -> String {
        func block(_ pane: Pane) -> String {
            #"{"block_id":\#(quoted(pane.block)),"label":"shell","creator_name":"com.superlogical.terminal"}"#
        }
        let windows = session.windows.map { window in
            let focused = window.focused ?? window.panes.first?.block ?? ""
            return #"{"window_id":\#(quoted(window.id)),"label":\#(quoted(window.label)),"focused_block_id":\#(quoted(focused)),"layers":[{"blocks":[\#(window.panes.map(block).joined(separator: ","))]}]}"#
        }
        let active = session.windows.first.map { quoted($0.id) } ?? "null"
        return #"{"revision":\#(session.revision),"session_id":\#(quoted(session.id)),"label":\#(quoted(session.label)),"active_window_id":\#(active),"windows":[\#(windows.joined(separator: ","))]}"#
    }

    private static func quoted(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: The preview's host

    static let oppiSession = "session:01a18a26-6620-76be-b529-4d9ad2b36c63"
    static let dotfilesSession = "session:01a18a26-6620-76be-b529-4d9ad2b36c64"
    static let claudeBlock = "block:01a18a26-6620-78ba-80d4-4e8caa018b37"
    static let piBlock = "block:01a18a7e-911a-721b-a50b-14dfc0cc62ca"
    static let logsBlock = "block:01a18a7e-911a-721b-a50b-14dfc0cc62cb"
    static let codexBlock = "block:01a18a7e-911a-721b-a50b-14dfc0cc62cc"

    /// Two sessions: Claude waiting on a permission and a working pi in one
    /// window of the first, a log tail in its second; a codex pane at idle in
    /// the other. Folders are what each shell last reported.
    static func preview(eventDelay: Duration = .milliseconds(20)) -> RexFakeWorld {
        // Each record carries the time its program last moved, as Rex sends it, so a
        // pane row's "2m ago" is read from the wire rather than made up on screen.
        func ago(_ seconds: TimeInterval) -> String {
            Date(timeIntervalSinceNow: -seconds).ISO8601Format()
        }
        let agents = Window(
            id: "window:01a18a26-6645-713c-97f1-2f1058c8c82f", label: "agents", focused: claudeBlock,
            panes: [
                Pane(
                    block: claudeBlock, title: "Fixing the build", pwd: "file://mac-studio/home/dev/workspace/oppi",
                    records: #"[{"effective_app":"claude","state":"working","updated_at":"\#(ago(125))"},{"id":"bash","effective_app":"claude","state":"blocked","kind":"permission","msg":"Run rm -rf build?","updated_at":"\#(ago(95))"}]"#
                ),
                Pane(
                    block: piBlock, title: "Adding skill frontmatter", pwd: "file://mac-studio/home/dev/workspace/oppi/server",
                    records: #"[{"effective_app":"pi","state":"working","updated_at":"\#(ago(185))"}]"#
                ),
            ]
        )
        let logs = Window(
            id: "window:01a18a26-6645-713c-97f1-2f1058c8c830", label: "logs", focused: logsBlock,
            panes: [Pane(block: logsBlock, title: "tail -f server.log", pwd: "file://mac-studio/home/dev/workspace/oppi/server/logs")]
        )
        let main = Window(
            id: "window:01a18a26-6645-713c-97f1-2f1058c8c831", label: "main", focused: codexBlock,
            panes: [Pane(
                block: codexBlock, title: "Ready", pwd: "file://mac-studio/home/dev/dotfiles",
                records: #"[{"effective_app":"codex","state":"idle","updated_at":"\#(ago(740))"}]"#
            )]
        )
        return RexFakeWorld(sessions: [
            Session(id: oppiSession, label: "oppi", serverLabel: "oppi", windows: [agents, logs], revision: 4),
            Session(id: dotfilesSession, label: "dotfiles", serverLabel: "dotfiles", windows: [main], revision: 2),
        ], eventDelay: eventDelay)
    }
}
#endif
