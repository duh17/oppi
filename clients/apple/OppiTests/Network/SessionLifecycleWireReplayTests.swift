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
///
/// Scenarios tagged `plannedChange` in the fixture are not replayed: a later server change
/// alters their frames on purpose.
@Suite("Session lifecycle wire replay")
@MainActor
struct SessionLifecycleWireReplayTests {
    /// Scenario ids whose server behaviour a later slice changes on purpose.
    static let plannedScenarios: Set<String> = [
        "classic.stop_during_start",
        "classic.wake_hold",
        "mirror.busy_idle_stop",
        "mirror.abort_mid_turn",
    ]

    // MARK: - Named disagreements

    /// The client applies the server's status from summaries and state frames instead of
    /// rewriting it from events.
    static let statusFromServer = "client status follows the server"
    /// One activity rule (status, replica and local stop intent) feeds keep-alive and screen-awake.
    static let oneActivityRule = "one session activity rule"

    /// Every difference between the client row and the server, by name. `matches` sees the path,
    /// the frame type and every differing field at that frame; the first rule that lists the field
    /// and matches claims it.
    static let disagreements: [LifecycleDisagreement] = [
        .init(
            name: "agentStartLeadsSummary",
            closedBy: Self.statusFromServer,
            reason: "The client marks the row busy on the agent_start event. The server sends the busy "
                + "summary after the event, so its status at that frame is still ready. That includes "
                + "the durable run released after an abort that landed before its agent_start.",
            fields: [.status, .keepAlive, .awake],
            expectedFires: 78
        ) { path, frame, diff in
            path != .app && frame == "agent_start" && diff[.status] == LifecycleDifference("busy", "ready")
        },
        .init(
            name: "agentSettledLeadsSummary",
            closedBy: Self.statusFromServer,
            reason: "The client marks the row ready on agent_settled. The server's ready summary "
                + "follows, so its status at that frame is still busy. That includes the durable run "
                + "released after an abort that landed before its agent_start.",
            fields: [.status, .keepAlive, .awake],
            expectedFires: 48
        ) { path, frame, diff in
            path != .app && frame == "agent_settled" && diff[.status] == LifecycleDifference("ready", "busy")
        },
        .init(
            name: "stopConfirmedReleasesStopping",
            closedBy: Self.statusFromServer,
            reason: "An abort's stop_confirmed arrives at agent_end, while the server row is still "
                + "stopping until agent_settled. The client rewrites stopping to ready on stop_confirmed "
                + "and releases the screen-awake reason. The next stopping summary puts the row back, "
                + "and agent_settled releases it again before the server's ready summary. A durable "
                + "abort that lands before agent_start really stops too: the server holds stopping "
                + "through stop_confirmed until its ready summary.",
            fields: [.status, .keepAlive, .awake],
            expectedFires: 60
        ) { _, frame, diff in
            ["stop_confirmed", "agent_settled"].contains(frame) && diff[.status] == LifecycleDifference("ready", "stopping")
        },
        .init(
            name: "stopConfirmedReleasesTerminate",
            closedBy: Self.statusFromServer,
            reason: "A terminate sends stop_confirmed while the server row is already stopped. The client "
                + "shows ready for the frame, then stopped on session_ended.",
            fields: [.status],
            expectedFires: 9
        ) { _, frame, diff in
            frame == "stop_confirmed" && diff[.status] == LifecycleDifference("ready", "stopped")
        },
        .init(
            name: "nonFatalErrorMarksSessionError",
            closedBy: Self.statusFromServer,
            reason: "Any non-fatal error or session_error frame marks the row .error, unless the "
                + "message starts \"Retrying (\". The server sets error only for launch failures; the "
                + "turn continues busy and its next summary restores the row. Only the background "
                + "and app paths show it: the focused path ignores the error frame.",
            fields: [.status, .keepAlive, .awake],
            expectedFires: 10
        ) { path, frame, diff in
            path != .focused && ["error", "session_error"].contains(frame) && diff[.status] == LifecycleDifference("error", "busy")
        },
        .init(
            name: "sessionEndedKeepsProgress",
            closedBy: "unowned: needs a server summary when the session reaches stopped",
            reason: "After a terminate the server's programStatus is idle. The client keeps the last "
                + "working programStatus on stop_confirmed and session_ended, which carry none; "
                + "only a summary or state frame replaces it, and the server sends none once the "
                + "row is stopped. Rows and the Live Activity do not show it: a stopped session "
                + "with a working program status reads Stopped.",
            fields: [.program],
            expectedFires: 6
        ) { _, frame, diff in
            ["stop_confirmed", "session_ended"].contains(frame) && diff[.program] == LifecycleDifference("working", "idle")
        },
        .init(
            name: "programFollowsSummaryOnly",
            closedBy: "none: by design",
            reason: "Dialog, settle and compaction events carry no program status. The client keeps "
                + "the previous value until the summary frame; the server's value at that frame is "
                + "already the new one.",
            fields: [.program],
            expectedFires: 6
        ) { _, frame, diff in
            ["extension_ui_request", "extension_ui_settled", "compaction_start", "agent_settled"].contains(frame)
                && diff[.program] != nil
        },
        .init(
            name: "keepAliveIgnoresStopping",
            closedBy: Self.oneActivityRule,
            reason: "BackgroundKeepAlive.hasActiveAgent counts busy and starting rows. A stopping "
                + "session has an agent still winding down, so the server-implied answer is true. "
                + "That includes a durable abort that lands before agent_start.",
            fields: [.keepAlive],
            expectedFires: 101
        ) { _, _, diff in
            diff[.keepAlive] == LifecycleDifference("false", "true")
        },
        .init(
            name: "appEventsDoNotDriveAwake",
            closedBy: Self.oneActivityRule,
            reason: "The screen-awake reason is set by focused-stream agent events and by stop "
                + "events, never by a session summary. The app-event channel alone carries "
                + "summaries, so a running session holds no screen-awake reason. That includes the "
                + "durable run released after an abort that landed before its agent_start.",
            fields: [.awake],
            expectedFires: 36
        ) { path, _, diff in
            path == .app && diff[.awake] == LifecycleDifference("false", "true")
        },
        .init(
            name: "appStopFailedLeavesAwakeOn",
            closedBy: Self.oneActivityRule,
            reason: "stop_failed sets the screen-awake reason, and only an agent_settled event clears "
                + "it. On the app-event channel the ready summary does not, so the reason outlives "
                + "the run.",
            fields: [.awake],
            expectedFires: 1
        ) { path, _, diff in
            path == .app && diff[.awake] == LifecycleDifference("true", "false")
        },
        .init(
            name: "stopFromIdleDoesNotSetAwake",
            closedBy: Self.oneActivityRule,
            reason: "A terminate of an idle session, or a durable abort that lands before agent_start "
                + "while the row is still ready, moves the server to stopping. On the stream paths only "
                + "agent_start or a running state or summary sets the screen-awake reason, so the "
                + "client holds none at stop_requested. If the activity rule decides an idle stop "
                + "holds nothing, the server-implied answer changes instead.",
            fields: [.awake],
            expectedFires: 4
        ) { path, frame, diff in
            path != .app && frame == "stop_requested" && diff[.awake] == LifecycleDifference("false", "true")
        },
    ]

    // MARK: - Tests

    @Test func fixtureHoldsEveryScenarioAndTheExpectedPlannedTags() throws {
        let scenarios = try LifecycleFixture.load()
        #expect(scenarios.count == 22)
        #expect(Set(scenarios.filter { $0.plannedChange != nil }.map(\.id)) == Self.plannedScenarios)
    }

    @Test func everyClientServerDifferenceIsNamedAndPinned() async throws {
        var unexplained: [String] = []
        var fires: [String: Int] = [:]
        for scenario in try LifecycleFixture.load() where scenario.plannedChange == nil {
            for path in LifecycleReplayPath.allCases {
                for observation in try await LifecycleReplay.run(scenario, path: path) {
                    for (field, difference) in observation.differences.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                        if let rule = Self.disagreements.first(where: {
                            $0.fields.contains(field) && $0.matches(path, observation.frameType, observation.differences)
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

    /// A non-fatal error frame marks the session errored on a background session and on
    /// the app-event channel, while the server stays busy; the next summary puts it right.
    @Test func nonFatalErrorFrameMarksTheSessionErrored() async throws {
        let background = try await observe("classic.run_error", .background)
        #expect(background[3].frameType == "error")
        #expect(background[3].client.status == "error" && background[3].server.status == "busy")

        let app = try await observe("classic.run_error", .app)
        #expect(app[1].frameType == "session_error")
        #expect(app[1].client.status == "error" && app[1].server.status == "busy")
        #expect(app[2].client.status == "busy" && app[2].server.status == "busy")

        // The focused session ignores the error frame.
        let focused = try await observe("classic.run_error", .focused)
        let errorFrame = try #require(focused.first { $0.frameType == "error" })
        #expect(errorFrame.client.status == "busy" && errorFrame.server.status == "busy")
    }

    /// An abort's stop_confirmed releases `stopping` to ready while the server stays stopping until
    /// agent_settled, on all three paths.
    @Test func stopConfirmedReleasesStoppingBeforeTheServerDoes() async throws {
        let focused = try await observe("classic.abort_mid_turn", .focused)
        #expect(focused[3].frameType == "stop_requested" && focused[3].client.status == "stopping")
        #expect(focused[7].frameType == "stop_confirmed")
        #expect(focused[7].client.status == "ready" && focused[7].server.status == "stopping")
        #expect(focused[8].frameType == "session_summary")
        #expect(focused[8].client.status == "stopping" && focused[8].server.status == "stopping")
        #expect(focused[9].frameType == "agent_settled")
        #expect(focused[9].client.status == "ready" && focused[9].server.status == "stopping")

        let app = try await observe("classic.abort_mid_turn", .app)
        #expect(app[3].frameType == "stop_confirmed")
        #expect(app[3].client.status == "ready" && app[3].server.status == "stopping")
    }

    /// A terminate sends stop_confirmed with the server already stopped; session_ended is what
    /// finally puts the client on stopped.
    @Test func terminateShowsReadyBetweenStoppingAndStopped() async throws {
        let focused = try await observe("classic.terminate_busy", .focused)
        #expect(focused[3].client.status == "stopping")
        #expect(focused[7].frameType == "stop_confirmed")
        #expect(focused[7].client.status == "ready" && focused[7].server.status == "stopped")
        #expect(focused[8].frameType == "session_ended")
        #expect(focused[8].client.status == "stopped" && focused[8].server.status == "stopped")
        // programStatus is not cleared by either frame.
        #expect(focused[8].client.program == "working" && focused[8].server.program == "idle")
    }

    /// The activity readers: keep-alive ignores `stopping`, and a stop_failed on the app channel
    /// leaves the screen-awake reason on after the server is ready.
    @Test func activityReadersDisagreeWithTheServerWhileStopping() async throws {
        let abort = try await observe("classic.abort_mid_turn", .app)
        #expect(abort[1].frameType == "stop_requested")
        #expect(abort[1].client.status == "stopping" && abort[1].server.status == "stopping")
        #expect(abort[1].client.keepAlive == false && abort[1].server.keepAlive == true)

        let rejected = try await observe("classic.abort_rejected", .app)
        #expect(rejected[7].frameType == "session_summary")
        #expect(rejected[7].client.status == "ready" && rejected[7].server.status == "ready")
        #expect(rejected[7].client.awake == true && rejected[7].server.awake == false)
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
    let matches: (LifecycleReplayPath, String, [LifecycleField: LifecycleDifference]) -> Bool

    init(
        name: String,
        closedBy: String,
        reason: String,
        fields: Set<LifecycleField>,
        expectedFires: Int,
        matches: @escaping (LifecycleReplayPath, String, [LifecycleField: LifecycleDifference]) -> Bool
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
    /// A screen-awake session reason for the client. For the server, busy or stopping
    /// (`SessionStatus.isRunning`), the rule the client already applies to summaries.
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
    let plannedChange: String?
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
                plannedChange: item["plannedChange"] as? String,
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
        for (index, frame) in frames.enumerated() {
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
                    awake: frame.serverStatus.isRunning
                )
            ))
        }
        return observations
    }
}
