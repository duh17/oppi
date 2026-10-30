import Foundation
import Observation

/// Every session on the host's Rex server, its windows, and each terminal's
/// title, folder, and OSC 7501 records: one read, shaped like Rex's own API
/// objects (`session.list`, `session.view`, and the
/// `com.superlogical.terminal.*` block methods), so a client that speaks that
/// API directly can produce the same value. Rex owns the state; Oppi only
/// reads it.
struct RexSnapshot: Decodable, Equatable, Sendable {
    struct Pane: Decodable, Equatable, Sendable {
        let blockID: String
        let label: String?
        let title: String?
        /// The folder the terminal last reported (OSC 7), as Rex keeps it: a
        /// `file://host/path` URL.
        let pwd: String?
        let records: [SSHTerminalPaneRecord]

        enum CodingKeys: String, CodingKey {
            case blockID = "block_id", label, title, pwd, records = "program_status"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            blockID = try container.decode(String.self, forKey: .blockID)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            pwd = try container.decodeIfPresent(String.self, forKey: .pwd)
            records = try container.decodeIfPresent(LuaList<SSHTerminalPaneRecord>.self, forKey: .records)?.items ?? []
        }

        var status: SessionStatusKind? { SSHTerminalPaneRecord.headline(of: records) }

        /// The program that reported, else the terminal's title, else Rex's label.
        var displayName: String {
            let app = records.first { $0.id.isEmpty }?.app ?? records.first?.app
            return [app, title, label].compactMap { $0 }.first { !$0.isEmpty } ?? "Terminal"
        }
    }

    struct Window: Decodable, Equatable, Sendable {
        let windowID: String
        let label: String?
        let focusedBlockID: String?
        let panes: [Pane]

        enum CodingKeys: String, CodingKey {
            case windowID = "window_id", label, focusedBlockID = "focused_block_id", panes = "blocks"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            windowID = try container.decode(String.self, forKey: .windowID)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            focusedBlockID = try container.decodeIfPresent(String.self, forKey: .focusedBlockID)
            panes = try container.decode(LuaList<Pane>.self, forKey: .panes).items
        }
    }

    struct Session: Decodable, Equatable, Sendable {
        let sessionID: String
        let label: String?
        let activeWindowID: String?
        let windows: [Window]

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id", label, activeWindowID = "active_window_id", windows
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decode(String.self, forKey: .sessionID)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            activeWindowID = try container.decodeIfPresent(String.self, forKey: .activeWindowID)
            windows = try container.decode(LuaList<Window>.self, forKey: .windows).items
        }

        /// The pane Rex sends typing to: the focused pane of the active window.
        func isFocused(_ pane: Pane, in window: Window) -> Bool {
            window.windowID == activeWindowID && window.focusedBlockID == pane.blockID
        }
    }

    let sessions: [Session]

    enum CodingKeys: String, CodingKey { case sessions }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Required, as `windows` and `blocks` are: the script always returns
        // them, so an answer without them is not this script's.
        sessions = try container.decode(LuaList<Session>.self, forKey: .sessions).items
    }

    /// Panes waiting at an approval, question, or sign-in.
    var needsAttention: Int {
        sessions.reduce(0) { total, session in
            total + session.windows.reduce(0) { $0 + $1.panes.filter { $0.status?.isBlocked == true }.count }
        }
    }
}

/// A list from Rex's Lua `return` value. Lua has one table type, so Rex
/// encodes an empty list as `{}`: an empty object reads as no items, and
/// anything else that is not an array is an error.
private struct LuaList<Element: Decodable>: Decodable {
    let items: [Element]

    private struct NoKeys: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var items: [Element] = []
            while !array.isAtEnd { items.append(try array.decode(Element.self)) }
            self.items = items
            return
        }
        let object = try decoder.container(keyedBy: NoKeys.self)
        guard object.allKeys.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expected a list"))
        }
        items = []
    }
}

enum RexRemoteError: Error, Equatable, LocalizedError {
    case notInstalled
    case notRunning
    case rejected(String)
    case unreadable
    /// An ID Rex reported that Oppi will not send back to the host.
    case unusableID

    var errorDescription: String? {
        switch self {
        case .notInstalled: "rex is not on this host."
        case .notRunning: "Rex is not running on this host."
        case .rejected(let message): message
        case .unreadable: "Rex returned a response Oppi cannot read."
        case .unusableID: "Rex returned an ID Oppi will not send back."
        }
    }
}

/// Builds and interprets Rex CLI calls. Each call is one side command on the
/// terminal's SSH connection that pipes a Lua script into `rex do -`; the CLI
/// talks to the user's Rex server through its local socket, so the phone needs
/// no route to Rex itself.
enum RexRemote {
    /// macOS keeps the CLI inside the Rex app's server bundle, off the `PATH`
    /// an SSH command sees; Linux and FreeBSD packages put `rex` on it. The
    /// bundle comes first so another program named `rex` on the `PATH` is not
    /// asked. `--autostart=false`: reading the list must never start a Rex
    /// server on a host that is not running one. Exit 127 is the shell's
    /// command-not-found status, as for a missing `herdr`.
    static let command = SSHTerminalRemoteShell.word(
        "r=\"$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex\"; "
            + "[ -x \"$r\" ] || r=$(command -v rex) || exit 127; "
            + "exec \"$r\" --autostart=false do -"
    )

    /// Rex's exit status for a server that is not running when autostart is off.
    static let notRunningStatus = 4

    /// The Lua script `command` reads on stdin for one snapshot. A session
    /// destroyed between the list and its view is skipped, and a block method
    /// that fails leaves its field out.
    static let snapshotScript = """
    assert(rex.call("session.attach_all", { event_scope = "session" }))
    local sessions = {}
    for _, s in ipairs(rex.call("session.list", {}).sessions or {}) do
      local view = rex.call("session.view", { session_id = s.session_id })
      if view then
        local windows = {}
        for _, w in ipairs(view.windows or {}) do
          local blocks = {}
          for _, layer in ipairs(w.layers or {}) do
            for _, b in ipairs(layer.blocks or {}) do
              local entry = { block_id = b.block_id, label = b.label }
              if b.creator_name == "com.superlogical.terminal" then
                local function call(name)
                  return rex.call("com.superlogical.terminal." .. name, { session_id = s.session_id, block_id = b.block_id })
                end
                local title, pwd, status = call("title"), call("pwd"), call("program_status")
                entry.title = title and title.title
                entry.pwd = pwd and pwd.pwd
                entry.program_status = status and status.records
              end
              table.insert(blocks, entry)
            end
          end
          table.insert(windows, { window_id = w.window_id, label = w.label, focused_block_id = w.focused_block_id, blocks = blocks })
        end
        table.insert(sessions, { session_id = s.session_id, label = s.label, active_window_id = view.active_window_id, windows = windows })
      end
    end
    return { sessions = sessions }
    """

    /// Focuses a pane, which also makes its window the session's active one.
    /// The IDs go into the script as Lua string literals, so only Rex's own ID
    /// form (`session:` or `block:` and a UUID) is accepted; anything else
    /// from a hostile snapshot is refused rather than quoted.
    static func focusScript(session: String, block: String) -> String? {
        guard isRexID(session, kind: "session"), isRexID(block, kind: "block") else { return nil }
        return """
        assert(rex.call("session.attach", { session_id = "\(session)" }))
        assert(rex.call("session.focus_block", { session_id = "\(session)", block_id = "\(block)" }))
        return {}
        """
    }

    static func isRexID(_ id: String, kind: String) -> Bool {
        let prefix = kind + ":"
        guard id.hasPrefix(prefix), let uuid = UUID(uuidString: String(id.dropFirst(prefix.count))) else { return false }
        return id == prefix + uuid.uuidString.lowercased()
    }

    static func snapshot(from result: SSHExecResult) throws -> RexSnapshot {
        try check(result)
        guard let snapshot = try? JSONDecoder().decode(RexSnapshot.self, from: result.output) else {
            throw RexRemoteError.unreadable
        }
        return snapshot
    }

    static func check(_ result: SSHExecResult) throws {
        switch result.exitStatus {
        case .some(0): return
        case .some(127): throw RexRemoteError.notInstalled
        case .some(notRunningStatus): throw RexRemoteError.notRunning
        default: break
        }
        let text = String(decoding: result.errorOutput.isEmpty ? result.output : result.errorOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = text.hasPrefix("Error: ") ? String(text.dropFirst("Error: ".count)) : text
        throw RexRemoteError.rejected(message.isEmpty
            ? "rex exited with status \(result.exitStatus.map(String.init) ?? "unknown")."
            : String(message.prefix(300)))
    }
}

/// Polls the host's Rex server while a terminal is connected, so the bar can
/// offer the session list and a needs-you count. A host without `rex` is
/// detected once and not polled again for that connection; a Rex that is not
/// running is asked again, since it may start.
@MainActor @Observable
final class RexMonitor: SSHTerminalOverviewSource {
    let title = "Rex"
    let identifierPrefix = "sshTerminal.rex"
    /// The last snapshot read. A failed read keeps it on screen, as what Rex
    /// last reported, and reports `failure`.
    private(set) var snapshot: RexSnapshot?
    private(set) var failure: String?
    private(set) var unavailable = false
    private(set) var focusFailure: String?
    var watching = false {
        didSet { if !watching { focusFailure = nil } }
    }
    /// The read in flight. A refresh while one runs waits for it instead of
    /// racing a second answer.
    private var reader: Task<Void, Never>?

    var available: Bool { snapshot != nil }
    /// Waiting panes that are still known to wait: a Rex that stopped answering
    /// does not keep the badge lit with its last report.
    var needsAttention: Int { failure == nil ? snapshot?.needsAttention ?? 0 : 0 }

    func run(on channel: SSHTerminalChannel) async {
        while !Task.isCancelled, channel.connected {
            await refresh(on: channel)
            if unavailable { return }
            try? await Task.sleep(for: watching ? .seconds(2) : .seconds(6))
        }
    }

    func refresh(on channel: SSHTerminalChannel) async {
        if let reader { return await reader.value }
        let reader = Task { [weak self] in
            let result: Result<RexSnapshot, any Error>
            do {
                result = .success(try RexRemote.snapshot(
                    from: try await channel.run(RexRemote.command, input: Data(RexRemote.snapshotScript.utf8))
                ))
            } catch {
                result = .failure(error)
            }
            self?.reader = nil
            self?.apply(result)
        }
        self.reader = reader
        await reader.value
    }

    private func apply(_ result: Result<RexSnapshot, any Error>) {
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            failure = nil
        case .failure(is CancellationError):
            break
        case .failure(RexRemoteError.notInstalled):
            unavailable = true
            snapshot = nil
            failure = nil
        case .failure(let error):
            failure = error.localizedDescription
        }
    }

    /// A pane row focuses its pane in its session. Session rows offer nothing
    /// to focus.
    func focus(_ focus: SSHTerminalOverviewFocus, on channel: SSHTerminalChannel) async -> Bool {
        focusFailure = nil
        if let session = focus.scope, !focus.isGroup, let script = RexRemote.focusScript(session: session, block: focus.id) {
            do {
                try RexRemote.check(try await channel.run(RexRemote.command, input: Data(script.utf8)))
            } catch {
                focusFailure = error.localizedDescription
            }
        } else {
            focusFailure = RexRemoteError.unusableID.localizedDescription
        }
        guard focusFailure == nil else { return false }
        // A read already running started before the focus.
        await reader?.value
        await refresh(on: channel)
        return true
    }

    /// One section per session: the session, then its panes in window order,
    /// each with its program's status. The pane Rex types into is bold. A
    /// session with several windows names each pane's window.
    var sections: [SSHTerminalOverviewSection] {
        var sections: [SSHTerminalOverviewSection] = []
        if let failure {
            sections.append(.init(id: "failure", rows: [.init(id: "failure", title: failure, kind: .failure, focus: nil)]))
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
