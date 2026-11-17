import Foundation
import Testing
@testable import Oppi

/// Replays `protocol/session-lifecycle-wire.json` (the frames a server sends, with its own
/// status and program status beside each one) through a real `ServerConnection`, and compares
/// the client's session row after every frame with the server's answer.
///
/// This characterises today's client. It does not say the client is right. Where the client
/// and the server disagree, the difference must be a named `Disagreement` below: it carries
/// the reason and the change that removes it, and `expectedFires` pins how often it shows. A
/// difference no rule explains fails the run, and so does a rule that stops firing, so the
/// change that deletes client inference removes its rule in the same commit.
///
/// Three replays per scenario:
/// - `focused`: the focused-stream frames through `TestEventPipeline`, session focused.
/// - `background`: the same frames as the stream delivers them for a session another session
///   has focus over (`routeStreamMessage` → cross-session routing).
/// - `app`: the app-event frames through `handleAppEvent`.
@Suite("Session lifecycle wire replay")
@MainActor
struct SessionLifecycleWireReplayTests {
    // MARK: - Named disagreements

    /// Every difference between the client row and the server, by name. `matches` sees the scenario
    /// id, the path, the frame type and every differing field at that frame; the first rule that lists the field
    /// and matches claims it.
    static let disagreements: [LifecycleDisagreement] = [
        .init(
            name: "programFollowsSummaryOnly",
            closedBy: "none: by design",
            reason: "Dialog, settle and compaction events carry no program status. The client keeps "
                + "the previous value until the summary frame; the server's value at that frame is "
                + "already the new one. The mirror's own agent_settled relay lags the same way.",
            fields: [.program],
            expectedFires: 10
        ) { _, _, frame, diff in
            ["extension_ui_request", "extension_ui_settled", "compaction_start", "agent_settled"].contains(frame)
                && diff[.program] != nil
        },
        .init(
            name: "statusLagsAtStopRequested",
            closedBy: "none: the state frame that always follows it catches it up",
            reason: "stop_requested carries no status, and the client takes status only from the "
                + "server's state and summaries. The row keeps its prior value for that one frame, "
                + "until the state/session_summary that follows it on the wire. keepAlive, derived "
                + "from status, lags the same beat when the stop starts from an idle row.",
            fields: [.status, .keepAlive],
            expectedFires: 39
        ) { _, _, frame, diff in
            frame == "stop_requested" && diff[.status] != nil
        },
        .init(
            name: "statusLagsAtStopConfirmedOrCompactionStart",
            closedBy: "none: the next state/session_summary always catches it up",
            reason: "compaction_start carries no status, so the row keeps its prior value for that "
                + "one frame, briefly undercounting a wrapping-up session's keep-alive and awake "
                + "need too. A terminate's stop_confirmed does not lag: the stopped summary on "
                + "runtime_ended catches the row up first.",
            fields: [.status, .awake, .keepAlive],
            expectedFires: 6
        ) { _, _, frame, diff in
            ["stop_confirmed", "compaction_start"].contains(frame) && diff[.status] != nil
        },
        .init(
            name: "mirrorAgentStartLagsBridgeState",
            closedBy: "none: the state/summary that follows always catches it up",
            reason: "The mirror relays agent_start from the bridge's raw event feed, separate from "
                + "the state push that carries status. When no busy state preceded it — an abort "
                + "with no earlier bridge busy report — the row lags one frame at agent_start, until "
                + "the state or summary that follows. keepAlive lags the same beat.",
            fields: [.status, .program, .awake, .keepAlive],
            expectedFires: 8
        ) { scenario, path, frame, diff in
            !scenario.hasPrefix("durable.") && path != .app && frame == "agent_start"
                && diff[.status] == LifecycleDifference("ready", "busy")
        },
        .init(
            name: "durableRunStartPrecedesItsSummary",
            closedBy: "none: the summary that follows agent_start always catches it up",
            reason: "A durable session is busy from the view value that shows its run, before "
                + "agent_start goes out. A run whose start reaches the session only after an abort "
                + "in the gap has no state frame between: the row lags ready one frame at "
                + "agent_start, until the summary that follows. keepAlive and awake lag the same beat.",
            fields: [.status, .awake, .keepAlive],
            expectedFires: 6
        ) { scenario, path, frame, diff in
            scenario.hasPrefix("durable.") && path != .app && frame == "agent_start"
                && diff[.status] == LifecycleDifference("ready", "busy")
        },
        .init(
            name: "mirrorAgentSettledLagsBridgeState",
            closedBy: "none: the state/summary that follows always catches it up",
            reason: "The mirror's agent_settled relay carries no status either, and no stop_confirmed "
                + "precedes it outside a stop: the row lags busy or stopping one frame until the "
                + "state or summary that follows.",
            fields: [.status, .keepAlive, .awake],
            expectedFires: 12
        ) { _, _, frame, diff in
            frame == "agent_settled" && diff[.status] != nil
        },
    ]

    // MARK: - Tests

    @Test func fixtureHoldsEveryScenario() throws {
        let scenarios = try LifecycleFixture.load()
        #expect(scenarios.count == 22)
    }

    @Test func everyClientServerDifferenceIsNamedAndPinned() async throws {
        var unexplained: [String] = []
        var fires: [String: Int] = [:]
        for scenario in try LifecycleFixture.load() {
            for path in LifecycleReplayPath.allCases {
                for observation in try await LifecycleReplay.run(scenario, path: path) {
                    for (field, difference) in observation.differences.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                        if let rule = Self.disagreements.first(where: {
                            $0.fields.contains(field) && $0.matches(scenario.id, path, observation.frameType, observation.differences)
                        }) {
                            fires[rule.name, default: 0] += 1
                        } else {
                            unexplained.append(
                                "\(scenario.id)/\(path.rawValue)#\(observation.index) \(observation.frameType) "
                                    + "\(field.rawValue) client=\(difference.client) server=\(difference.server)"
                            )
                        }
                    }
                }
            }
        }
        #expect(unexplained.isEmpty, "Differences no named disagreement explains:\n\(unexplained.joined(separator: "\n"))")
        let expected = Dictionary(uniqueKeysWithValues: Self.disagreements.map { ($0.name, $0.expectedFires) })
        #expect(fires == expected)
    }

    /// A non-fatal error frame carries no status on any path: the row stays busy, matching the
    /// server, through error/session_error.
    @Test func nonFatalErrorFrameCarriesNoStatus() async throws {
        let background = try await observe("classic.run_error", .background)
        #expect(background[3].frameType == "error")
        #expect(background[3].client.status == "busy" && background[3].server.status == "busy")

        let app = try await observe("classic.run_error", .app)
        #expect(app[1].frameType == "session_error")
        #expect(app[1].client.status == "busy" && app[1].server.status == "busy")

        // The focused session ignores the error frame too.
        let focused = try await observe("classic.run_error", .focused)
        let errorFrame = try #require(focused.first { $0.frameType == "error" })
        #expect(errorFrame.client.status == "busy" && errorFrame.server.status == "busy")
    }

    /// stop_requested carries no status: the row lags one frame, busy until the state frame that
    /// follows. stop_confirmed and agent_settled carry none either,
    /// so the row stays stopping through both, matching the server until its ready summary.
    @Test func stopConfirmedNoLongerReleasesStoppingEarly() async throws {
        let focused = try await observe("classic.abort_mid_turn", .focused)
        #expect(focused[3].frameType == "stop_requested")
        #expect(focused[3].client.status == "busy" && focused[3].server.status == "stopping")
        #expect(focused[4].frameType == "state")
        #expect(focused[4].client.status == "stopping" && focused[4].server.status == "stopping")
        #expect(focused[7].frameType == "stop_confirmed")
        #expect(focused[7].client.status == "stopping" && focused[7].server.status == "stopping")
        #expect(focused[9].frameType == "agent_settled")
        #expect(focused[9].client.status == "stopping" && focused[9].server.status == "stopping")
        #expect(focused[10].frameType == "session_summary")
        #expect(focused[10].client.status == "ready" && focused[10].server.status == "ready")

        let app = try await observe("classic.abort_mid_turn", .app)
        #expect(app[3].frameType == "stop_confirmed")
        #expect(app[3].client.status == "stopping" && app[3].server.status == "stopping")
    }

    /// A terminate: the row lags busy→stopping by one frame at stop_requested, and the stopped
    /// summary on runtime_ended catches it up before stop_confirmed and session_ended.
    @Test func terminateStoppedSummaryCatchesUpBeforeConfirmation() async throws {
        let focused = try await observe("classic.terminate_busy", .focused)
        #expect(focused[3].frameType == "stop_requested")
        #expect(focused[3].client.status == "busy" && focused[3].server.status == "stopping")
        #expect(focused[4].frameType == "state")
        #expect(focused[4].client.status == "stopping" && focused[4].server.status == "stopping")
        // Neither stop_confirmed nor session_ended lags in status or program status.
        #expect(focused[7].frameType == "state")
        #expect(focused[7].client.status == "stopped" && focused[7].server.status == "stopped")
        #expect(focused[7].client.program == "idle" && focused[7].server.program == "idle")
        #expect(focused[8].frameType == "stop_confirmed")
        #expect(focused[8].client.status == "stopped" && focused[8].server.status == "stopped")
        #expect(focused[8].client.program == "idle" && focused[8].server.program == "idle")
        #expect(focused[9].frameType == "session_ended")
        #expect(focused[9].client.status == "stopped" && focused[9].server.status == "stopped")
    }

    /// Keep-alive holds through `stopping` once the row catches up to it: the session_summary
    /// right after stop_requested shows the server's winding-down verdict, and
    /// BackgroundKeepAlive.hasActiveAgent counts it alongside busy and starting.
    @Test func keepAliveHoldsThroughStoppingOnceTheRowCatchesUp() async throws {
        let abort = try await observe("classic.abort_mid_turn", .app)
        #expect(abort[2].frameType == "session_summary")
        #expect(abort[2].client.status == "stopping" && abort[2].server.status == "stopping")
        #expect(abort[2].client.keepAlive == true && abort[2].server.keepAlive == true)
    }

    /// Terminating an idle session never held a turn, so it does not keep the screen on at
    /// any point of the stop.
    @Test func terminateOfAnIdleSessionNeverHoldsScreenAwake() async throws {
        let terminate = try await observe("classic.terminate_idle", .focused)
        #expect(!terminate.isEmpty)
        #expect(terminate.allSatisfy { !$0.client.awake && !$0.server.awake })
    }

    /// A terminate of a busy durable session holds the screen awake through the turn's
    /// winding-down and through its final quiet stretch once settled (program status `done`):
    /// `currentTurnStartedAt` stays sticky through `stopping` until the row actually leaves it.
    @Test func terminateOfABusySessionHoldsScreenAwakeThroughItsFinalQuietStretch() async throws {
        let terminate = try await observe("durable.terminate_busy", .focused)
        let windingDown = try #require(terminate.first { $0.client.status == "stopping" && $0.client.program == "working" })
        #expect(windingDown.client.awake, "a terminate's stopping phase still holds awake while its turn winds down")
        let settled = try #require(terminate.first { $0.client.status == "stopping" && $0.client.program == "done" })
        #expect(settled.client.awake, "the turn's own timestamp outlives its settle, so a terminate still holds awake until it reaches stopped")
    }

    private func observe(_ id: String, _ path: LifecycleReplayPath) async throws -> [LifecycleObservation] {
        let scenario = try #require(try LifecycleFixture.load().first { $0.id == id })
        return try await LifecycleReplay.run(scenario, path: path)
    }
}

// MARK: - Disagreement catalogue

enum LifecycleField: String, Hashable {
    case status
    case program
    case keepAlive
    case awake
}

struct LifecycleDifference: Equatable {
    let client: String
    let server: String

    init(_ client: String, _ server: String) {
        self.client = client
        self.server = server
    }
}

struct LifecycleDisagreement {
    let name: String
    /// The change that removes it, or why none does.
    let closedBy: String
    let reason: String
    let fields: Set<LifecycleField>
    /// How many (scenario, path, frame, field) differences the rule claims over the pinned scenarios.
    let expectedFires: Int
    /// Scenario id, path, frame type, and every differing field at that frame.
    let matches: (String, LifecycleReplayPath, String, [LifecycleField: LifecycleDifference]) -> Bool

    init(
        name: String,
        closedBy: String,
        reason: String,
        fields: Set<LifecycleField>,
        expectedFires: Int,
        matches: @escaping (String, LifecycleReplayPath, String, [LifecycleField: LifecycleDifference]) -> Bool
    ) {
        self.name = name
        self.closedBy = closedBy
        self.reason = reason
        self.fields = fields
        self.expectedFires = expectedFires
        self.matches = matches
    }
}

// MARK: - Fixture

enum LifecycleReplayPath: String, CaseIterable, Sendable {
    case focused
    case background
    case app

    var channel: String { self == .app ? "app" : "focused" }
}

/// What the client shows, or what the server's status implies, at one frame.
struct LifecycleReading: Equatable {
    var status: String
    var program: String
    /// `BackgroundKeepAlive.hasActiveAgent` for the client. For the server, starting, busy or
    /// stopping: an agent that is launching, running or winding down needs the app alive.
    var keepAlive: Bool
    /// A screen-awake session reason for the client. For the server, running outright, or
    /// stopping a turn that started (`Session.holdsScreenAwake`): a terminate of an idle
    /// session holds nothing.
    var awake: Bool
}

struct LifecycleObservation {
    let index: Int
    let step: String
    let frameType: String
    let client: LifecycleReading
    let server: LifecycleReading

    var differences: [LifecycleField: LifecycleDifference] {
        var out: [LifecycleField: LifecycleDifference] = [:]
        if client.status != server.status { out[.status] = .init(client.status, server.status) }
        if client.program != server.program { out[.program] = .init(client.program, server.program) }
        if client.keepAlive != server.keepAlive { out[.keepAlive] = .init("\(client.keepAlive)", "\(server.keepAlive)") }
        if client.awake != server.awake { out[.awake] = .init("\(client.awake)", "\(server.awake)") }
        return out
    }
}

struct LifecycleScenario {
    struct Frame {
        let channel: String
        let step: String
        let type: String
        let json: Data
        let serverStatus: SessionStatus
        let serverProgram: String
    }

    let id: String
    /// The row the client held before the first frame: the first checkpoint's saved row.
    let seedStatus: SessionStatus
    let seedProgram: String
    let frames: [Frame]
}

enum LifecycleFixture {
    static let sessionId = "lifecycle-session"
    static let workspaceId = "workspace-1"

    static func load() throws -> [LifecycleScenario] {
        let root = try #require(try JSONSerialization.jsonObject(with: ProtocolFixtures.data("session-lifecycle-wire.json")) as? [String: Any])
        let raw = try #require(root["scenarios"] as? [[String: Any]])
        return try raw.map { item in
            let id = try #require(item["id"] as? String)
            let checkpoints = try #require(item["checkpoints"] as? [[String: Any]])
            let row = try #require(checkpoints.first?["row"] as? [String: Any])
            let frames = try #require(item["frames"] as? [[String: Any]]).map { f -> LifecycleScenario.Frame in
                let frame = f["frame"] as? [String: Any] ?? [:]
                let server = f["server"] as? [String: Any] ?? [:]
                return LifecycleScenario.Frame(
                    channel: f["channel"] as? String ?? "",
                    step: f["step"] as? String ?? "",
                    type: frame["type"] as? String ?? "",
                    json: try JSONSerialization.data(withJSONObject: frame),
                    serverStatus: SessionStatus(rawValue: server["status"] as? String ?? "") ?? .error,
                    serverProgram: (server["programStatus"] as? [String: Any])?["state"] as? String ?? "none"
                )
            }
            return LifecycleScenario(
                id: id,
                seedStatus: SessionStatus(rawValue: row["status"] as? String ?? "") ?? .error,
                seedProgram: (row["programStatus"] as? [String: Any])?["state"] as? String ?? "none",
                frames: frames
            )
        }
    }
}

// MARK: - Replay

@MainActor
enum LifecycleReplay {
    static func run(_ scenario: LifecycleScenario, path: LifecycleReplayPath) async throws -> [LifecycleObservation] {
        // The background path needs the session to be anything but focused.
        let focusedId = path == .background ? "another-session" : LifecycleFixture.sessionId
        let (conn, pipe) = await makeTestConnection(sessionId: focusedId)
        let awake = ScreenAwakeController(timeoutProvider: { nil }, idleTimerSetter: { _ in })
        conn.screenAwakeController = awake
        conn.sessionStore.upsert(makeTestSession(
            id: LifecycleFixture.sessionId,
            workspaceId: LifecycleFixture.workspaceId,
            status: scenario.seedStatus,
            programStatus: ProgramStatus(
                state: ProgramStatusState(rawValue: scenario.seedProgram),
                since: Date(timeIntervalSince1970: 1_800_000_000)
            )
        ))

        var observations: [LifecycleObservation] = []
        let frames = scenario.frames.filter { $0.channel == path.channel }
        // Mirrors `Session.holdsScreenAwake`'s signal: the server sets `currentTurnStartedAt`
        // on a turn's first busy frame, and the client's own store keeps it sticky through
        // `stopping` (a "working" status there) until the row actually leaves busy/starting/
        // stopping — so a stop that never saw `busy` (an idle terminate) never has one.
        var hadTurnInFlight = scenario.seedStatus == .busy
        for (index, frame) in frames.enumerated() {
            switch frame.serverStatus {
            case .busy: hadTurnInFlight = true
            case .starting, .stopping: break
            case .ready, .stopped, .error: hadTurnInFlight = false
            }
            switch path {
            case .focused:
                let message = try JSONDecoder().decode(ServerMessage.self, from: frame.json)
                pipe.handle(message, sessionId: LifecycleFixture.sessionId)
                pipe.flushNow()
            case .background:
                let message = try JSONDecoder().decode(ServerMessage.self, from: frame.json)
                conn.routeStreamMessage(StreamMessage(
                    sessionId: LifecycleFixture.sessionId, seq: nil, currentSeq: nil, message: message
                ))
            case .app:
                conn.handleAppEvent(try JSONDecoder().decode(AppEventMessage.self, from: frame.json))
            }
            let row = conn.sessionStore.session(id: LifecycleFixture.sessionId)
            observations.append(LifecycleObservation(
                index: index,
                step: frame.step,
                frameType: frame.type,
                client: LifecycleReading(
                    status: row?.status.rawValue ?? "absent",
                    program: row?.programStatus?.state.rawValue ?? "none",
                    keepAlive: BackgroundKeepAlive.hasActiveAgent(in: [conn]),
                    awake: awake.hasRunningSession
                ),
                server: LifecycleReading(
                    status: frame.serverStatus.rawValue,
                    program: frame.serverProgram,
                    keepAlive: [.starting, .busy, .stopping].contains(frame.serverStatus),
                    awake: hadTurnInFlight && [.busy, .stopping].contains(frame.serverStatus)
                )
            ))
        }
        return observations
    }
}
