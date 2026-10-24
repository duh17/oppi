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
            HerdrSnapshot.resolve(state: ProgramStatusState(rawValue: rawValue), kind: nil)
        }
    }

    /// One OSC 7501 record Herdr passes on, unverified, for a pane's program
    /// (`program_status`, proposed in herdrdev/herdr#5172): the same record
    /// tree the terminal keeps from libghostty. The empty id is the program
    /// itself; `/` separates a child record from its parent.
    struct ProgramRecord: Decodable, Equatable, Hashable, Sendable {
        let id: String
        let state: ProgramStatusState
        let kind: ProgramStatusKind?
        let message: String?
    }

    struct Pane: Decodable, Equatable, Sendable {
        let paneID: String
        let programStatus: [ProgramRecord]
        /// The workspace this pane belongs to, and the folder its shell is in.
        /// "Open Terminal here" matches a Herdr workspace by this folder, so an
        /// older Herdr that omits them leaves the folder to be created instead.
        let workspaceID: String?
        let cwd: String?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id", programStatus = "program_status"
            case workspaceID = "workspace_id", cwd
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = try container.decode(String.self, forKey: .paneID)
            programStatus = try container.decodeIfPresent([ProgramRecord].self, forKey: .programStatus) ?? []
            workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
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
        var id: String { paneID }

        /// Herdr's own display order: a live name, then the detected agent.
        var displayName: String { name ?? displayAgent ?? agent ?? paneID }
        var subtitle: String? { [title, terminalTitle].compactMap { $0 }.first { !$0.isEmpty } }

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id", workspaceID = "workspace_id", tabID = "tab_id"
            case status = "agent_status", focused, name, displayAgent = "display_agent", agent, title
            case terminalTitle = "terminal_title_stripped"
        }
    }

    let workspaces: [Workspace]
    let tabs: [Tab]
    let agents: [Agent]
    /// Only panes whose program reported OSC 7501 matter here; Herdr
    /// versions without the records leave every list empty.
    let panes: [Pane]

    enum CodingKeys: String, CodingKey {
        case workspaces, tabs, agents, panes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        agents = try container.decode([Agent].self, forKey: .agents)
        panes = try container.decodeIfPresent([Pane].self, forKey: .panes) ?? []
    }

    /// Herdr keeps its own seen ledger: a done or error it still reports is
    /// one nobody has looked at, so every outcome counts as unseen.
    private static func resolve(state: ProgramStatusState, kind: ProgramStatusKind?) -> SessionStatusKind? {
        SessionStatusKind.resolve(state: state, kind: kind, since: .distantFuture, seenAt: nil)
    }

    /// An agent's status. The pane's own OSC 7501 records lead, rolled up the
    /// way the terminal rolls up its records, so a blocked kind survives
    /// Herdr; Herdr's detected state covers panes that do not report.
    func status(of agent: Agent) -> SessionStatusKind? {
        let records = panes.first { $0.paneID == agent.paneID }?.programStatus ?? []
        let root = records.first { $0.id.isEmpty }.flatMap { Self.resolve(state: $0.state, kind: $0.kind) }
        let others = records.filter { !$0.id.isEmpty }.compactMap { Self.resolve(state: $0.state, kind: $0.kind) }
        return SessionStatusRollup(root: root, others: others).headline ?? agent.status.sessionStatus
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
final class HerdrMonitor {
    /// Local first, then the host's saved machines in Herdr's order.
    private(set) var machines: [HerdrMachineState] = [.local()]
    private(set) var unavailable = false
    /// Why the last tap could not focus its row; the next tap, or closing the
    /// sheet, clears it.
    private(set) var focusFailure: String?
    /// The overview sheet is open: refresh faster.
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

    func run(on channel: SSHTerminalChannel) async {
        while !Task.isCancelled, channel.connected, !unavailable {
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
            self?.apply(result, to: machine)
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

    private func apply(_ result: Result<HerdrSnapshot, any Error>, to machine: String?) {
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

    func focus(_ target: HerdrRemote.FocusTarget, machine: String?, on channel: SSHTerminalChannel) async -> Bool {
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
}
