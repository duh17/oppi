import Foundation
import Observation

/// The subset of Herdr's `session.snapshot` (socket API protocol 22) that the
/// terminal's agent overview shows. Herdr owns the state; Oppi only reads it
/// through `herdr api snapshot` on the terminal's SSH connection.
struct HerdrSnapshot: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case idle, working, blocked, done, unknown

        init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// Shared session-status reading. Herdr reports no blocked kind, so
        /// `blocked` is a question. An unknown Herdr state stays nil rather
        /// than claiming Done or a blocked kind.
        var sessionStatus: SessionStatusKind? {
            switch self {
            case .working: .working
            case .blocked: .question
            case .done: .done
            case .idle: .idle
            case .unknown: nil
            }
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

    /// Agents Herdr sees at an approval or question UI.
    var needsAttention: Int { agents.filter { $0.status == .blocked }.count }
    /// The agent in Herdr's focused pane, if that pane runs one.
    var focusedAgent: Agent? { agents.first { $0.focused } }

    func agents(in workspace: Workspace) -> [Agent] { agents.filter { $0.workspaceID == workspace.workspaceID } }
    func tabLabel(_ id: String) -> String? { tabs.first { $0.tabID == id }?.label }
}

enum HerdrRemoteError: Error, Equatable, LocalizedError {
    case notInstalled
    case rejected(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notInstalled: "herdr is not on this host’s PATH for SSH commands."
        case .rejected(let message): message
        case .unreadable: "Herdr returned a response Oppi cannot read."
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
