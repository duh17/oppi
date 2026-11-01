import Foundation
import Observation

/// The subset of Herdr's `session.snapshot` (socket API protocol 22) that the
/// terminal's agent overview shows. Herdr owns the state; Oppi only reads it
/// through `herdr api snapshot` on the terminal's SSH connection.
struct HerdrSnapshot: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable, Hashable {
        case idle, working, blocked, done, unknown

        init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// Herdr's states are OSC 7501's, so they read through the same
        /// resolver as sessions and terminal records. Herdr reports no blocked
        /// kind, so `blocked` is a question; an unknown state stays nil.
        var sessionStatus: SessionStatusKind? {
            SSHTerminalPaneRecord.status(state: ProgramStatusState(rawValue: rawValue), kind: nil)
        }
    }

    struct Pane: Decodable, Equatable, Sendable {
        let paneID: String
        /// The OSC 7501 records Herdr passes on, unverified, for the pane's
        /// program (`program_status`, proposed in herdrdev/herdr#5172).
        let programStatus: [SSHTerminalPaneRecord]
        /// The workspace this pane belongs to, and the folder its shell is in.
        /// "Open Terminal here" matches a Herdr workspace by this folder, so an
        /// older Herdr that omits them leaves the folder to be created instead.
        let workspaceID: String?
        let cwd: String?
        /// The folder of the pane's foreground process, when Herdr reports it.
        let foregroundCwd: String?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id", programStatus = "program_status"
            case workspaceID = "workspace_id", cwd, foregroundCwd = "foreground_cwd"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = try container.decode(String.self, forKey: .paneID)
            programStatus = try container.decodeIfPresent([SSHTerminalPaneRecord].self, forKey: .programStatus) ?? []
            workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            foregroundCwd = try container.decodeIfPresent(String.self, forKey: .foregroundCwd)
        }
    }

    struct Workspace: Decodable, Equatable, Identifiable, Sendable {
        let workspaceID: String
        let label: String
        let focused: Bool
        var id: String { workspaceID }

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id", label, focused
        }
    }

    struct Tab: Decodable, Equatable, Identifiable, Sendable {
        let tabID: String
        let workspaceID: String
        let label: String
        var id: String { tabID }

        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id", workspaceID = "workspace_id", label
        }
    }

    struct Agent: Decodable, Equatable, Identifiable, Sendable {
        let paneID: String
        let workspaceID: String
        let tabID: String
        let status: Status
        let focused: Bool
        let name: String?
        let displayAgent: String?
        let agent: String?
        let title: String?
        let terminalTitle: String?
        let cwd: String?
        let foregroundCwd: String?
        var id: String { paneID }

        /// Herdr's own display order: a live name, then the detected agent.
        var displayName: String { name ?? displayAgent ?? agent ?? paneID }
        var subtitle: String? { [title, terminalTitle].compactMap { $0 }.first { !$0.isEmpty } }

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id", workspaceID = "workspace_id", tabID = "tab_id"
            case status = "agent_status", focused, name, displayAgent = "display_agent", agent, title
            case terminalTitle = "terminal_title_stripped"
            case cwd, foregroundCwd = "foreground_cwd"
        }

        // Herdr may omit the folders (an older Herdr), so they decode as optional.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = try container.decode(String.self, forKey: .paneID)
            workspaceID = try container.decode(String.self, forKey: .workspaceID)
            tabID = try container.decode(String.self, forKey: .tabID)
            status = try container.decode(Status.self, forKey: .status)
            focused = try container.decode(Bool.self, forKey: .focused)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            displayAgent = try container.decodeIfPresent(String.self, forKey: .displayAgent)
            agent = try container.decodeIfPresent(String.self, forKey: .agent)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            terminalTitle = try container.decodeIfPresent(String.self, forKey: .terminalTitle)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            foregroundCwd = try container.decodeIfPresent(String.self, forKey: .foregroundCwd)
        }
    }

    let workspaces: [Workspace]
    let tabs: [Tab]
    let agents: [Agent]
    /// Only panes whose program reported OSC 7501 matter here; Herdr
    /// versions without the records leave every list empty.
    let panes: [Pane]
    /// The pane that has focus, when Herdr says (`focused_pane_id`).
    let focusedPaneID: String?

    enum CodingKeys: String, CodingKey {
        case workspaces, tabs, agents, panes, focusedPaneID = "focused_pane_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        agents = try container.decode([Agent].self, forKey: .agents)
        panes = try container.decodeIfPresent([Pane].self, forKey: .panes) ?? []
        focusedPaneID = try container.decodeIfPresent(String.self, forKey: .focusedPaneID)
    }

    /// The focused pane's folder on this Herdr's machine: its foreground
    /// process's, else the pane's own, from the pane list or else the agent
    /// entry. Only an absolute path counts, normalized as an OSC 7 folder is.
    var focusedPaneFolder: HerdrLocalFolder {
        guard let focusedPaneID else { return .unknown }
        let pane = panes.first { $0.paneID == focusedPaneID }
        let agent = agents.first { $0.paneID == focusedPaneID }
        let folder = [pane?.foregroundCwd, pane?.cwd, agent?.foregroundCwd, agent?.cwd]
            .lazy.compactMap { $0.flatMap(SSHTerminalWorkingDirectory.normalize) }.first
        return folder.map(HerdrLocalFolder.folder) ?? .unknown
    }

    /// An agent's status. The pane's own OSC 7501 records lead, so a blocked
    /// kind survives Herdr; Herdr's detected state covers panes that do not
    /// report.
    func status(of agent: Agent) -> SessionStatusKind? {
        let records = panes.first { $0.paneID == agent.paneID }?.programStatus ?? []
        return SSHTerminalPaneRecord.headline(of: records) ?? agent.status.sessionStatus
    }

    /// Agents waiting at an approval, question, or sign-in.
    var needsAttention: Int { agents.filter { status(of: $0)?.isBlocked == true }.count }
    func agents(in workspace: Workspace) -> [Agent] { agents.filter { $0.workspaceID == workspace.workspaceID } }
    func tabLabel(_ id: String) -> String? { tabs.first { $0.tabID == id }?.label }

    /// The workspace that already has a pane in any spelling of the folder: its
    /// logical path and the path the host's filesystem reports, so a symlinked
    /// mount (`/tmp` on macOS, a home reached through a link) matches the folder
    /// Herdr names instead of opening a second workspace for it.
    ///
    /// Each comparison is exact — a Herdr workspace is a place someone works, not
    /// a subtree, and a subfolder is a different place — apart from a trailing
    /// slash. The focused workspace wins when several match, so opening a folder
    /// that is already in front changes nothing.
    func workspace(withPaneInAny folders: [String]) -> Workspace? {
        let wanted = Set(folders.map(Self.comparablePath).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return nil }
        let matches = workspaces.filter { workspace in
            panes.contains { pane in
                pane.workspaceID == workspace.workspaceID
                    && pane.cwd.map(Self.comparablePath).map(wanted.contains) == true
            }
        }
        return matches.first(where: \.focused) ?? matches.first
    }

    /// A folder as it is compared: no surrounding whitespace and no trailing
    /// slash, except the root folder itself.
    static func comparablePath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

/// What the host's own Herdr says about the terminal's folder.
enum HerdrLocalFolder: Equatable, Sendable {
    /// No snapshot yet, a read that failed for good, a stopped poll, or a Herdr
    /// that names no usable folder for its focused pane.
    case unknown
    case folder(String)
}

enum HerdrRemoteError: Error, Equatable, LocalizedError {
    case notInstalled
    case rejected(String)
    case unreadable
    /// An ID Herdr reported that Oppi will not send back to the host.
    case unusableID

    var errorDescription: String? {
        switch self {
        case .notInstalled: "herdr is not on this host’s PATH for SSH commands."
        case .rejected(let message): message
        case .unreadable: "Herdr returned a response Oppi cannot read."
        case .unusableID: "Herdr returned an ID Oppi will not send back."
        }
    }
}

/// A saved SSH machine from `herdr machine list --json` (Herdr 0.9.5). The
/// host's Herdr reaches it over its own saved connection; Oppi names it only
/// by its profile `id`, never by an SSH address.
struct HerdrMachine: Decodable, Equatable, Sendable {
    let id: String
    let label: String
    let enabled: Bool
}

/// Builds and interprets Herdr CLI calls. Every command runs in its own exec
/// channel; the CLI talks to the user's Herdr server socket on the host, and
/// with `--machine` to a saved machine's server through that host.
enum HerdrRemote {
    static let machinesCommand = "herdr machine list --json"
    /// Local's snapshot, which the folder open also reads.
    static let snapshotCommand = "herdr api snapshot"

    enum FocusTarget: Equatable {
        case workspace(String)
        case agent(String)
    }

    /// Local's snapshot, or a saved machine's (nil machine is Local).
    static func snapshotCommand(machine: String?) -> String? {
        machine == nil ? snapshotCommand : command("api snapshot", machine: machine, values: [])
    }

    /// Focus moves on the server that owns the ID: workspace and pane IDs are
    /// scoped to one machine, so `w1` on Local and `w1` on a saved machine are
    /// different workspaces.
    static func focusCommand(_ target: FocusTarget, machine: String?) -> String? {
        switch target {
        case .workspace(let id): command("workspace focus \"$i\"", machine: machine, values: [("i", id)])
        case .agent(let id): command("agent focus \"$i\"", machine: machine, values: [("i", id)])
        }
    }

    /// Herdr IDs are generated by Herdr (`w1`, `w1:p2`, a hex machine profile).
    /// Anything else is refused rather than quoted, so a hostile snapshot or
    /// machine list cannot inject shell syntax. An ID that passes travels
    /// through the same octal-escape builder as every other value the host is
    /// given, and Herdr's CLI accepts no `--` before its argument (0.9.5 prints
    /// its usage), so the character check is what keeps it from being read as a
    /// flag: a leading `-` is refused too.
    private static func command(_ arguments: String, machine: String?, values: [(String, String)]) -> String? {
        let values = (machine.map { [("m", $0)] } ?? []) + values
        guard values.allSatisfy({ isHerdrID($0.1) }) else { return nil }
        guard !values.isEmpty else { return "herdr \(arguments)" }
        let script = values.map { SSHTerminalRemoteShell.assign($0.0, $0.1) }.joined(separator: " ")
            + " exec herdr \(machine == nil ? "" : "--machine \"$m\" ")\(arguments)"
        return SSHTerminalRemoteShell.word(script)
    }

    private static func isHerdrID(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix("-")
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ":_-".unicodeScalars.contains($0) }
    }

    /// The saved machines, each once: a profile ID repeated in the host's file
    /// could not name one machine, and one that is not a Herdr ID could never
    /// be sent back, so only the first entry with a usable ID is kept.
    static func machines(from result: SSHExecResult) throws -> [HerdrMachine] {
        try check(result)
        guard let machines = try? JSONDecoder().decode([HerdrMachine].self, from: result.output) else {
            throw HerdrRemoteError.unreadable
        }
        var seen = Set<String>()
        return machines.filter { isHerdrID($0.id) && seen.insert($0.id).inserted }
    }

    static func snapshot(from result: SSHExecResult) throws -> HerdrSnapshot {
        try check(result)
        struct Envelope: Decodable {
            struct Result: Decodable { let snapshot: HerdrSnapshot }
            let result: Result
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: result.output) else {
            throw HerdrRemoteError.unreadable
        }
        return envelope.result.snapshot
    }

    /// Exit 127 is the POSIX shell's (and fish's) command-not-found status.
    static func check(_ result: SSHExecResult) throws {
        if result.exitStatus == 127 { throw HerdrRemoteError.notInstalled }
        guard result.exitStatus != 0 else { return }
        struct Failure: Decodable {
            struct Body: Decodable { let message: String }
            let error: Body
        }
        for data in [result.output, result.errorOutput] {
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                throw HerdrRemoteError.rejected(failure.error.message)
            }
        }
        let text = String(decoding: result.errorOutput.isEmpty ? result.output : result.errorOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw HerdrRemoteError.rejected(text.isEmpty ? "herdr exited with status \(result.exitStatus.map(String.init) ?? "unknown")." : String(text.prefix(300)))
    }
}

/// One Herdr server the overview shows: Local, the server this terminal's
/// host runs, or a machine saved in that host's Herdr.
struct HerdrMachineState: Equatable, Identifiable {
    /// Nil is Local.
    let machineID: String?
    let label: String
    let enabled: Bool
    /// The last snapshot read. A failed read keeps it on screen, as what the
    /// machine last reported, and reports `failure`.
    var snapshot: HerdrSnapshot?
    var failure: String?
    var id: String { machineID ?? "" }
    /// Waiting agents that are still known to wait: a machine that stopped
    /// answering does not keep the badge lit with its last report.
    var needsAttention: Int { failure == nil ? snapshot?.needsAttention ?? 0 : 0 }

    static func local() -> Self { Self(machineID: nil, label: "Local", enabled: true) }
}

/// Polls Herdr while a terminal is connected so the toolbar can offer the
/// agent overview and a needs-you count across Local and every saved machine.
/// A host without herdr is detected once and never polled again for that
/// connection. Each machine is read in its own side command, so a saved
/// machine that is down reports its own failure and Local still updates.
@MainActor @Observable
final class HerdrMonitor: SSHTerminalOverviewSource {
    let title = "Herdr"
    let identifierPrefix = "sshTerminal.herdr"
    /// Local first, then the host's saved machines in Herdr's order.
    private(set) var machines: [HerdrMachineState] = [.local()]
    private(set) var unavailable = false
    private(set) var focusFailure: String?
    var watching = false {
        didSet { if !watching { focusFailure = nil } }
    }
    /// The last machine list read.
    private var saved: [HerdrMachine] = []
    /// `machine list` reads a file on the host and needs no network, so a
    /// refusal means this Herdr predates saved machines: stop asking.
    private var listsMachines = true
    /// The snapshot read running for each machine (nil key is Local). A
    /// machine is asked again only once its last read has answered or timed
    /// out, so overlapping refreshes never race two answers for one machine,
    /// and a machine that hangs is not asked again until it gives up.
    private var readers: [String?: Task<Void, Never>] = [:]

    var available: Bool { machines.contains { $0.snapshot != nil } }
    /// Agents waiting at an approval, question, or sign-in on any machine.
    var needsAttention: Int { machines.reduce(0) { $0 + $1.needsAttention } }

    /// The poll is not running (switched away, reconnecting, disconnected): a
    /// read still in flight must not set the terminal's folder after that.
    private var stopped = false
    /// Which `run` is the current poll. A run that ends after a newer one
    /// started (leave the screen and return within one read) is not the poll
    /// any more and changes nothing.
    private var runToken = 0

    /// A stopped poll takes its folder with it: nothing keeps it current.
    func run(on channel: SSHTerminalChannel) async {
        runToken &+= 1
        let token = runToken
        stopped = false
        defer {
            if runToken == token {
                stopped = true
                channel.setHerdrFolder(.unknown)
            }
        }
        while !Task.isCancelled, AppPreferenceStore.Experiments.herdrEnabled, channel.connected, !unavailable {
            await refresh(on: channel)
            try? await Task.sleep(for: watching ? .seconds(2) : .seconds(6))
        }
    }

    /// Rereads the machine list, then asks every enabled machine at once and
    /// returns when Local has answered. Each saved machine's answer shows when
    /// it arrives, so one that is slow (a side command gives up after 10
    /// seconds) delays only its own rows, not Local's or the poll.
    func refresh(on channel: SSHTerminalChannel) async {
        if listsMachines {
            do {
                saved = try HerdrRemote.machines(from: try await channel.run(HerdrRemote.machinesCommand))
            } catch HerdrRemoteError.rejected, HerdrRemoteError.unreadable {
                listsMachines = false
                saved = []
            } catch {
                // The connection, not Herdr: keep the last list.
            }
        }
        guard !Task.isCancelled else { return }
        // The list's order and membership, each machine keeping what it last
        // showed until its new answer arrives. A disabled machine is not read:
        // Herdr would refuse it.
        let previous = Dictionary(machines.map { ($0.machineID, $0) }, uniquingKeysWith: { first, _ in first })
        machines = [HerdrMachineState.local()] + saved.map {
            HerdrMachineState(machineID: $0.id, label: $0.label, enabled: $0.enabled)
        }
        for index in machines.indices where machines[index].enabled {
            machines[index].snapshot = previous[machines[index].machineID]?.snapshot
            machines[index].failure = previous[machines[index].machineID]?.failure
        }
        for machine in machines.filter(\.enabled).map(\.machineID) {
            _ = reading(machine, on: channel)
        }
        await readers[nil]?.value
    }

    /// The machine's running read, or a new one.
    private func reading(_ machine: String?, on channel: SSHTerminalChannel) -> Task<Void, Never> {
        if let reader = readers[machine] { return reader }
        let reader = Task { [weak self] in
            let result = await Self.read(machine, on: channel)
            self?.readers[machine] = nil
            self?.apply(result, to: machine, on: channel)
        }
        readers[machine] = reader
        return reader
    }

    private static func read(_ machine: String?, on channel: SSHTerminalChannel) async -> Result<HerdrSnapshot, any Error> {
        do {
            guard let command = HerdrRemote.snapshotCommand(machine: machine) else { throw HerdrRemoteError.unusableID }
            return .success(try HerdrRemote.snapshot(from: try await channel.run(command)))
        } catch {
            return .failure(error)
        }
    }

    private func apply(_ result: Result<HerdrSnapshot, any Error>, to machine: String?, on channel: SSHTerminalChannel) {
        // Only Local's panes are on this terminal's host; a saved machine's are
        // other hosts' and never name the shell's folder.
        if machine == nil, !stopped {
            switch result {
            case .success(let snapshot): channel.setHerdrFolder(snapshot.focusedPaneFolder)
            case .failure(is CancellationError): break
            case .failure: channel.herdrReadFailed()
            }
        }
        if machine == nil, case .failure(HerdrRemoteError.notInstalled) = result {
            unavailable = true
            machines = [.local()]
            return
        }
        // A machine removed or disabled while its read was out shows nothing.
        guard let index = machines.firstIndex(where: { $0.machineID == machine }), machines[index].enabled else { return }
        switch result {
        case .success(let snapshot):
            machines[index].snapshot = snapshot
            machines[index].failure = nil
        case .failure(is CancellationError):
            break
        case .failure(let error):
            machines[index].failure = error.localizedDescription
        }
    }

    /// A workspace row focuses the workspace, an agent row its pane, on the
    /// machine that owns the ID.
    func activate(_ focus: SSHTerminalOverviewFocus, on channel: SSHTerminalChannel) async -> Bool {
        let machine = focus.scope
        let target: HerdrRemote.FocusTarget = focus.isGroup ? .workspace(focus.id) : .agent(focus.id)
        focusFailure = nil
        if let command = HerdrRemote.focusCommand(target, machine: machine) {
            do {
                try HerdrRemote.check(try await channel.run(command))
            } catch {
                focusFailure = error.localizedDescription
            }
        } else {
            focusFailure = HerdrRemoteError.unusableID.localizedDescription
        }
        guard focusFailure == nil else { return false }
        // Only the machine that moved, so another one being slow does not hold
        // the sheet open; a read already running started before the focus.
        await readers[machine]?.value
        await reading(machine, on: channel).value
        return true
    }

    /// Each machine's workspaces and their agents. With no saved machines the
    /// sheet is Local's alone and needs no machine headers; otherwise every
    /// machine leads its own workspaces with its state, so a machine that is
    /// down or disabled still shows. Workspace and pane IDs are only unique
    /// within one machine, so every row and focus carries its machine.
    var sections: [SSHTerminalOverviewSection] {
        let headed = machines.count > 1
        var sections: [SSHTerminalOverviewSection] = []
        for machine in machines {
            let key = "machine|\(machine.id)|"
            if headed {
                sections.append(.init(id: key, rows: [.init(
                    id: key, title: machine.label,
                    kind: .header(note: Self.note(machine), failed: machine.failure != nil), focus: nil
                )]))
            } else if let failure = machine.failure {
                sections.append(.init(id: "failure", rows: [.init(id: "failure", title: failure, kind: .failure, focus: nil)]))
            }
            guard let snapshot = machine.snapshot else {
                if !headed, machine.failure == nil {
                    sections.append(.init(id: "loading", rows: [.init(id: "loading", title: "Loading…", kind: .placeholder, focus: nil)]))
                }
                continue
            }
            if !headed, snapshot.workspaces.isEmpty {
                sections.append(.init(id: "empty", rows: [
                    .init(id: "empty", title: "No Herdr workspaces.", kind: .placeholder, focus: nil),
                ]))
            }
            for workspace in snapshot.workspaces {
                let section = key + workspace.id
                var rows: [SSHTerminalOverviewRow] = [.init(
                    id: section, title: workspace.label, kind: .group(focused: workspace.focused),
                    focus: .init(scope: machine.machineID, id: workspace.workspaceID, isGroup: true)
                )]
                for agent in snapshot.agents(in: workspace) {
                    let tab = snapshot.tabLabel(agent.tabID)
                    rows.append(.init(
                        id: section + "|" + agent.paneID,
                        title: agent.displayName,
                        kind: .item(
                            subtitle: [agent.subtitle, tab.map { "tab \($0)" }].compactMap { $0 }.joined(separator: " · "),
                            focused: agent.focused,
                            status: snapshot.status(of: agent).map { .known($0) } ?? .unknown
                        ),
                        focus: .init(scope: machine.machineID, id: agent.paneID, isGroup: false)
                    ))
                }
                sections.append(.init(id: section, rows: rows))
            }
        }
        return sections
    }

    /// A machine header's second line: why it cannot be read (its rows, if
    /// any, are what it last reported), else its count of agents that need you.
    private static func note(_ machine: HerdrMachineState) -> String? {
        if let failure = machine.failure { return failure }
        if !machine.enabled { return "Disabled in Herdr" }
        guard let snapshot = machine.snapshot else { return "Loading…" }
        if snapshot.workspaces.isEmpty { return "No workspaces" }
        let waiting = snapshot.needsAttention
        return waiting > 0 ? "\(waiting) waiting" : nil
    }
}
