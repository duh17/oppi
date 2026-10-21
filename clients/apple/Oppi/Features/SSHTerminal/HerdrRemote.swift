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
    /// The agent in Herdr's focused pane, if that pane runs one.
    var focusedAgent: Agent? { agents.first { $0.focused } }

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

/// Builds and interprets Herdr CLI calls. Every command runs in its own exec
/// channel; the CLI talks to the user's Herdr server socket on the host.
enum HerdrRemote {
    static let snapshotCommand = "herdr api snapshot"

    enum FocusTarget: Equatable {
        case workspace(String)
        case agent(String)
    }

    /// Herdr IDs are server-generated (`w1`, `w1:p2`). Anything else is refused
    /// rather than quoted, so a hostile snapshot cannot inject shell syntax.
    static func focusCommand(_ target: FocusTarget) -> String? {
        let (noun, id) = switch target {
        case .workspace(let id): ("workspace", id)
        case .agent(let id): ("agent", id)
        }
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ":_-".unicodeScalars.contains($0) }) else {
            return nil
        }
        return "herdr \(noun) focus \(id)"
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

/// Polls Herdr while a terminal is connected so the toolbar can offer the
/// agent overview and a needs-you count. A host without herdr is detected once
/// and never polled again for that connection.
@MainActor @Observable
final class HerdrMonitor {
    private(set) var snapshot: HerdrSnapshot?
    private(set) var failure: String?
    private(set) var unavailable = false
    /// The overview sheet is open, or the terminal shows a Herdr client whose
    /// focused pane picks the input mode: refresh faster.
    var watching = false
    var attached = false

    var available: Bool { snapshot != nil }

    func run(on channel: SSHTerminalChannel) async {
        while !Task.isCancelled, channel.connected, !unavailable {
            await refresh(on: channel)
            try? await Task.sleep(for: watching || attached ? .seconds(2) : .seconds(6))
        }
    }

    func refresh(on channel: SSHTerminalChannel) async {
        do {
            snapshot = try HerdrRemote.snapshot(from: try await channel.run(HerdrRemote.snapshotCommand))
            failure = nil
        } catch HerdrRemoteError.notInstalled {
            unavailable = true
            snapshot = nil
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }

    func focus(_ target: HerdrRemote.FocusTarget, on channel: SSHTerminalChannel) async {
        guard let command = HerdrRemote.focusCommand(target) else {
            failure = "Herdr returned an ID Oppi will not send back."
            return
        }
        do {
            try HerdrRemote.check(try await channel.run(command))
            failure = nil
            await refresh(on: channel)
        } catch {
            failure = error.localizedDescription
        }
    }
}
