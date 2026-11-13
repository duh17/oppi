#if DEBUG
import UIKit

/// Schedules in the real workspace shell over a fixture server with a real week of
/// runs (`SCREENSHOT_SCREEN=schedules-calendar`). The twelve schedules, their times,
/// workspaces, models, costs, and outcomes are a real server's, shaped into the week
/// around the simulator's today; the calendar's clock is posed at 8:42 AM so the night,
/// the morning's problems, a running run, the now line, and the next runs all show.
///
/// `SCREENSHOT_SCHEDULES_OPEN=1` opens Schedules at launch; without it a test opens it
/// from the sidebar. `SCREENSHOT_COLOR_SCHEME` picks the theme.
final class ScheduleCalendarPreviewController: PreviewRootController {
    private let opensSchedules: Bool
    private let shellRoot: AppRootEnvironment

    init() {
        let environment = ProcessInfo.processInfo.environment
        ScreenshotVolatileDefaults.applyThemeScheme(environment["SCREENSHOT_COLOR_SCHEME"])
        opensSchedules = environment["SCREENSHOT_SCHEDULES_OPEN"] == "1"
        let world = ScheduleCalendarPreviewWorld(now: Self.posedNow())
        ScheduleCalendarModel.previewOffset = world.now.timeIntervalSince(Date())
        ScheduleCalendarFixtureURLProtocol.world = world

        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        let server = Self.server()
        coordinator.serverStore.replaceServersForPreview([server])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScheduleCalendarFixtureURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://schedules-preview.invalid:7749") ?? URL(fileURLWithPath: "/"),
            token: "sk_preview",
            configuration: configuration
        )
        let connection = coordinator.activatePreviewServer(server, apiClient: client, scheduleCalendar: true)
        for workspace in world.workspaces {
            connection.workspaceStore.upsert(workspace, serverId: server.id)
        }
        connection.sessionStore.switchServer(to: server.id)
        connection.sessionStore.sessions = world.sessions
        let root = AppRootEnvironment.preview(coordinator: coordinator)
        root.navigation.app.revealPairedServerShell()
        shellRoot = root
        super.init(root: root, themeStore: root.themeStore, content: QuickSessionOverShellController(root: root))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ScreenshotPreviewOrientation.applyRequested()
        if opensSchedules {
            shellRoot.navigation.openWorkspaceUtility(.schedules)
        }
    }

    /// Today at 8:42, on the simulator's current second, so the calendar's minute
    /// ticks on the real minute boundary.
    private static func posedNow() -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let second = calendar.component(.second, from: now)
        return calendar.date(bySettingHour: 8, minute: 42, second: second, of: now) ?? now
    }

    private static func server() -> PairedServer {
        guard var server = PairedServer(from: ServerCredentials(
            host: "schedules-preview.invalid",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            scheme: .https,
            serverFingerprint: "sha256:schedules-preview",
            tlsCertFingerprint: "sha256:schedules-preview-leaf"
        )) else {
            preconditionFailure("schedules preview server")
        }
        server.badgeIcon = nil
        return server
    }
}

/// The fixture server's state: schedules, the week's runs and their sessions.
struct ScheduleCalendarPreviewWorld {
    struct Schedule {
        let id: String
        let name: String
        let workspaceId: String
        let model: String
        let trigger: [String: Any]
        /// Hours and minutes it is due on a day, by weekday (1 = Sunday).
        let times: (Int) -> [(Int, Int)]
        var existingSessionId: String? = nil
        /// The saved Agent it launches, from `agents`.
        var agentId: String? = nil
    }

    /// One past run: when, how it ended, how long, what it cost.
    struct Run {
        enum Outcome { case done, failed, needsYou, running }
        let schedule: Schedule
        let at: Date
        let outcome: Outcome
        let minutes: Double
        let cost: Double
        var manual = false
        /// The sessions the run's session launched, oldest first.
        var subagents: [Subagent] = []
    }

    /// A session a run launched: its saved Agent, what it cost, and whether it still works.
    struct Subagent {
        let agentId: String
        let emoji: String
        let name: String
        let cost: Double
        var working = false
    }

    /// A Night shift's crew as a real night launches it: workers (🛠), night agents (🌙), and
    /// scouts (🔎), `working` of the first ones still going, costing `total` between them.
    private static func crew(workers: Int, night: Int, scouts: Int, working: Int = 0, total: Double) -> [Subagent] {
        let roles = [("worker", "🛠", "Fix", workers), ("night-agent", "🌙", "Triage", night), ("scout", "🔎", "Scout", scouts)]
        let topics = ["flaky scroll test", "sidebar regressions", "push relay retries", "timeline jump", "composer focus", "iPad split width"]
        var crew: [Subagent] = []
        for (agentId, emoji, verb, count) in roles {
            for index in 0..<count {
                crew.append(Subagent(agentId: agentId, emoji: emoji, name: "\(verb): \(topics[(crew.count + index) % topics.count])", cost: 0))
            }
        }
        // Uneven costs, as real runs are, that add up to `total`.
        let weights = crew.indices.map { 1 + Double(($0 * 7) % 5) }
        let sum = weights.reduce(0, +)
        return crew.enumerated().map { index, member in
            Subagent(
                agentId: member.agentId, emoji: member.emoji, name: member.name,
                cost: (total * weights[index] / sum * 100).rounded() / 100, working: index < working
            )
        }
    }

    let now: Date
    let schedules: [Schedule]
    let runs: [Run]
    let workspaces: [Workspace]
    private let calendar = Calendar.autoupdatingCurrent

    private static let opus = "anthropic/claude-opus-5-5"
    private static let sonnet = "anthropic/claude-sonnet-5-5"
    private static let haiku = "anthropic/claude-haiku-5"

    init(now: Date) {
        self.now = now
        let zone = TimeZone.autoupdatingCurrent.identifier
        func cron(_ expression: String) -> [String: Any] {
            ["type": "cron", "expression": expression, "timeZone": zone]
        }
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let hawaiiAt = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today) ?? today
        let daily: (Int, Int) -> (Int) -> [(Int, Int)] = { hour, minute in { _ in [(hour, minute)] } }
        let kypu = Schedule(id: "jr8ZJpgN", name: "Nightly Kypu sync", workspaceId: "kypu", model: Self.haiku, trigger: cron("5 0 * * *"), times: daily(0, 5))
        let journal = Schedule(id: "2D6tt98J", name: "Daily life journal", workspaceId: "notebook", model: Self.haiku, trigger: cron("15 0 * * *"), times: daily(0, 15))
        let dream = Schedule(id: "2o1Ev3FF", name: "Notebook dream", workspaceId: "notebook", model: Self.opus, trigger: cron("0 3 * * *"), times: daily(3, 0))
        let night = Schedule(id: "u1C2kXLz", name: "Night shift", workspaceId: "oppi", model: Self.opus, trigger: cron("30 3 * * *"), times: daily(3, 30))
        let mirror = Schedule(id: "TepvbvMD", name: "Daily upstream mirror sync", workspaceId: "oppi", model: Self.opus, trigger: cron("0 6 * * *"), times: daily(6, 0))
        let testFlight = Schedule(id: "lkTKXni0", name: "Daily TestFlight + push relay report", workspaceId: "oppi", model: Self.haiku, trigger: cron("0 6 * * *"), times: daily(6, 0))
        let digest = Schedule(id: "pSo7hh0o", name: "Daily personalized HN + X digest", workspaceId: "chaosdonkey", model: Self.opus, trigger: cron("0 7 * * *"), times: daily(7, 0))
        let review = Schedule(id: "nr-5e72v", name: "Night shift: weekly review", workspaceId: "oppi", model: Self.opus, trigger: cron("0 8 * * 0"), times: { $0 == 1 ? [(8, 0)] : [] })
        let jobs = Schedule(
            id: "6xbwGEM4", name: "Weekday job hunt", workspaceId: "jobsearch", model: Self.sonnet, trigger: cron("30 8 * * 1-5"),
            times: { (2...6).contains($0) ? [(8, 30)] : [] }, agentId: "job-scout"
        )
        let hawaii = Schedule(
            id: "GETGZreb", name: "Clear Hawaii no-install override", workspaceId: "oppi", model: Self.opus,
            trigger: ["type": "at", "at": Self.ms(hawaiiAt), "timeZone": zone],
            times: { _ in [] }, existingSessionId: "sess-hawaii"
        )
        let nanny = Schedule(id: "9Bq6VFNy", name: "Nanny mail triage", workspaceId: "nanny", model: Self.sonnet, trigger: cron("0 9,17 * * *"), times: { _ in [(9, 0), (17, 0)] })
        let deps = Schedule(id: "NV2WG4hM", name: "Weekly dependency check", workspaceId: "oppi", model: Self.opus, trigger: cron("0 6 * * 1"), times: { $0 == 2 ? [(6, 0)] : [] })
        schedules = [kypu, journal, dream, night, mirror, testFlight, digest, review, jobs, hawaii, nanny, deps]

        // The real week's outcomes and costs, by days before today.
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        var runs: [Run] = []
        func run(_ schedule: Schedule, _ daysAgo: Int, _ hour: Int, _ minute: Int, _ outcome: Run.Outcome, _ minutes: Double, _ cost: Double, manual: Bool = false, subagents: [Subagent] = []) {
            runs.append(Run(schedule: schedule, at: at(daysAgo, hour, minute), outcome: outcome, minutes: minutes, cost: cost, manual: manual, subagents: subagents))
        }
        // Earlier days: every scheduled run, done, at the real costs; one failed digest.
        let pastCosts: [String: [Double]] = [
            kypu.id: [0.01, 0.01, 0.01], journal.id: [0.02, 0.02, 0.02], dream.id: [2.37, 2.69, 5.28],
            night.id: [5.67, 25.55, 7.76], mirror.id: [1.29, 1.20, 0.99], testFlight.id: [0.01, 0.01, 0.01],
            digest.id: [2.41, 1.65, 1.92], review.id: [3.85], jobs.id: [0.69, 0.61],
            nanny.id: [0.12, 0.16, 0.22, 0.18, 0.15, 0.22], deps.id: [1.44],
        ]
        let pastMinutes: [String: Double] = [
            kypu.id: 0.5, journal.id: 0.5, dream.id: 5, night.id: 300, mirror.id: 2, testFlight.id: 0.7,
            digest.id: 6, review.id: 8, jobs.id: 4, nanny.id: 0.6, deps.id: 9,
        ]
        for daysAgo in 1...9 {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            let weekday = calendar.component(.weekday, from: day)
            for schedule in schedules {
                for (index, time) in schedule.times(weekday).enumerated() {
                    let costs = pastCosts[schedule.id] ?? [0.1]
                    let cost = costs[(daysAgo * 2 + index) % costs.count]
                    let failed = schedule.id == digest.id && daysAgo == 2
                    // A Night shift launches its crew; the night's dream sends a scout or two.
                    let crew: [Subagent] = switch schedule.id {
                    case night.id: Self.crew(workers: 12, night: 10, scouts: 4, total: 37.57 + Double(daysAgo % 3) * 4.2)
                    case dream.id: Self.crew(workers: 0, night: 0, scouts: 1 + daysAgo % 2, total: 0.86)
                    default: []
                    }
                    run(schedule, daysAgo, time.0, time.1, failed ? .failed : .done, pastMinutes[schedule.id] ?? 2, cost, subagents: crew)
                }
            }
        }
        // Today, by 8:42.
        run(kypu, 0, 0, 5, .done, 0.5, 0.01)
        run(journal, 0, 0, 15, .done, 0.5, 0.02)
        run(dream, 0, 3, 0, .done, 5, 2.51, subagents: Self.crew(workers: 0, night: 0, scouts: 2, total: 1.12))
        run(night, 0, 3, 30, .running, 0, 4.88, subagents: Self.crew(workers: 6, night: 5, scouts: 3, working: 2, total: 21.36))
        run(mirror, 0, 6, 0, .done, 2, 1.18)
        run(testFlight, 0, 6, 0, .done, 0.6, 0.01)
        if calendar.component(.weekday, from: today) == 2 { run(deps, 0, 6, 0, .done, 9, 1.44) }
        run(digest, 0, 7, 0, .failed, 5, 1.65)
        // Posed as a weekday whatever the simulator's day, so the morning always holds the
        // run waiting on you.
        run(jobs, 0, 8, 30, .needsYou, 12, 0.58)
        self.runs = runs

        func workspace(_ id: String, _ name: String, _ emoji: String) -> Workspace {
            Workspace(id: id, name: name, icon: .emoji(emoji), createdAt: today, updatedAt: today)
        }
        workspaces = [
            workspace("oppi", "oppi", "🍕"),
            workspace("kypu", "kypu", "🫏"),
            workspace("notebook", "notebook", "📓"),
            workspace("chaosdonkey", "chaosdonkey.dev", "🦄"),
            workspace("jobsearch", "jobSearch", "👨‍🌾"),
            workspace("nanny", "nanny", "🍼"),
        ]
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func runId(_ run: Run) -> String { "run-\(run.schedule.id)-\(ms(run.at))" }
    private static func sessionId(_ run: Run) -> String { "sess-\(run.schedule.id)-\(ms(run.at))" }
    private static func subagentId(_ run: Run, _ index: Int) -> String { "\(sessionId(run))-sub\(index)" }

    /// A subagent's session: launched a few minutes apart after its run, each done within
    /// the hour unless it still works.
    private func subagentSession(_ run: Run, _ index: Int) -> Session {
        let member = run.subagents[index]
        let created = run.at.addingTimeInterval(Double(index + 1) * 9 * 60)
        let settled = min(now, created.addingTimeInterval(Double(14 + (index * 11) % 40) * 60))
        return Session(
            id: Self.subagentId(run, index),
            workspaceId: run.schedule.workspaceId,
            name: member.name,
            status: member.working ? .busy : .stopped,
            createdAt: created,
            lastActivity: member.working ? now : settled,
            programStatus: member.working
                ? ProgramStatus(state: .working, since: now.addingTimeInterval(-90))
                : ProgramStatus(state: .done, since: settled),
            model: member.agentId == "scout" ? Self.sonnet : Self.opus,
            messageCount: 24,
            tokens: TokenUsage(input: 180_000, output: 9_000),
            cost: member.cost,
            launch: SessionLaunchMetadata(agentId: member.agentId, agentIcon: .emoji(member.emoji)),
            parentSessionId: Self.sessionId(run)
        )
    }

    /// Each run's session and the subagents it launched, as the app's session list holds them.
    var sessions: [Session] {
        runs.map { run in
            let program = programStatus(run)
            return Session(
                id: Self.sessionId(run),
                workspaceId: run.schedule.workspaceId,
                workspaceName: workspaces.first { $0.id == run.schedule.workspaceId }?.name,
                name: run.schedule.name,
                status: run.outcome == .running ? .busy : (run.outcome == .needsYou ? .ready : .stopped),
                createdAt: run.at,
                lastActivity: program.since,
                programStatus: program,
                model: run.schedule.model,
                messageCount: 6,
                tokens: TokenUsage(input: 40_000, output: 6_000),
                cost: run.cost
            )
        } + runs.flatMap { run in run.subagents.indices.map { subagentSession(run, $0) } }
    }

    private func programStatus(_ run: Run) -> ProgramStatus {
        let settled = run.at.addingTimeInterval(run.minutes * 60)
        switch run.outcome {
        case .done: return ProgramStatus(state: .done, since: settled)
        case .failed: return ProgramStatus(state: .error, message: "Provider returned 529", since: settled)
        case .needsYou: return ProgramStatus(state: .blocked, kind: .question, message: "Apply to these three?", since: settled)
        case .running: return ProgramStatus(state: .working, since: now.addingTimeInterval(-120))
        }
    }

    // MARK: - Wire

    func schedulesBody() -> [String: Any] {
        ["schedules": schedules.map { summary($0) }]
    }

    private func summary(_ schedule: Schedule) -> [String: Any] {
        var action: [String: Any] = [
            "type": schedule.existingSessionId == nil ? "new_session" : "existing_session",
            "workspaceId": schedule.workspaceId,
            "promptChars": 400,
        ]
        if let sessionId = schedule.existingSessionId { action["sessionId"] = sessionId }
        if let agentId = schedule.agentId { action["agentId"] = agentId }
        return [
            "id": schedule.id, "name": schedule.name, "status": "active", "trigger": schedule.trigger,
            "action": action, "version": 3, "createdAt": Self.ms(now) - 86_400_000 * 60, "updatedAt": Self.ms(now) - 86_400_000,
        ]
    }

    func scheduleBody(_ id: String) -> [String: Any]? {
        guard let schedule = schedules.first(where: { $0.id == id }) else { return nil }
        var body = summary(schedule)
        let action: [String: Any] = if let sessionId = schedule.existingSessionId {
            ["type": "existing_session", "workspaceId": schedule.workspaceId, "sessionId": sessionId, "prompt": "Clear the override."]
        } else {
            ["type": "new_session", "workspaceId": schedule.workspaceId, "prompt": "Run the \(schedule.name.lowercased()).", "model": schedule.model]
        }
        body["action"] = action
        return ["schedule": body]
    }

    func runsBody(_ id: String) -> [String: Any] {
        ["runs": runs.filter { $0.schedule.id == id }.reversed().prefix(20).map { run -> [String: Any] in
            [
                "id": Self.runId(run), "scheduleId": id, "kind": run.manual ? "manual" : "due",
                "slotKey": "cron:\(Self.ms(run.at))", "idempotencyKey": "k-\(Self.runId(run))",
                "status": "completed",
                "action": ["type": "new_session", "workspaceId": run.schedule.workspaceId, "promptChars": 400],
                "createdAt": Self.ms(run.at), "updatedAt": Self.ms(run.at), "sessionId": Self.sessionId(run),
                "promptDispatch": "delivered",
            ]
        }]
    }

    /// `GET /agents`: the saved Agent the job hunt launches.
    func agentsBody() -> [String: Any] {
        let stamp = Self.ms(now) - 86_400_000 * 30
        return ["agents": [[
            "id": "job-scout", "name": "Job scout", "icon": ["kind": "emoji", "value": "🧭"],
            "status": "active", "version": 2, "createdAt": stamp, "updatedAt": stamp,
        ]]]
    }

    /// `GET /schedules/calendar`: runs in the range with their sessions, then what is
    /// still to come by each active schedule's times.
    func calendarBody(from: Int64, to: Int64) -> [String: Any] {
        var entries: [[String: Any]] = []
        for run in runs where Self.ms(run.at) >= from && Self.ms(run.at) < to {
            let program = programStatus(run)
            var programBody: [String: Any] = ["state": program.state.rawValue, "since": Self.ms(program.since)]
            if let kind = program.kind { programBody["kind"] = kind.rawValue }
            if let message = program.message { programBody["message"] = message }
            var session: [String: Any] = [
                "id": Self.sessionId(run), "workspaceId": run.schedule.workspaceId,
                "status": run.outcome == .running ? "busy" : (run.outcome == .needsYou ? "ready" : "stopped"),
                "programStatus": programBody, "cost": run.cost, "model": run.schedule.model,
            ]
            if run.outcome == .done || run.outcome == .failed { session["settledAt"] = Self.ms(program.since) }
            if !run.subagents.isEmpty {
                session["descendants"] = run.subagents.indices.map { index -> [String: Any] in
                    let sub = subagentSession(run, index)
                    let program = sub.programStatus ?? ProgramStatus(state: .done, since: sub.lastActivity)
                    return [
                        "id": sub.id, "workspaceId": run.schedule.workspaceId, "name": sub.name ?? "",
                        "status": sub.status.rawValue, "createdAt": Self.ms(sub.createdAt),
                        "lastActivity": Self.ms(sub.lastActivity),
                        "programStatus": ["state": program.state.rawValue, "since": Self.ms(program.since)],
                        "model": sub.model ?? "", "messageCount": sub.messageCount,
                        "tokens": ["input": sub.tokens.input, "output": sub.tokens.output], "cost": sub.cost,
                        "agentId": run.subagents[index].agentId,
                        "agentIcon": ["kind": "emoji", "value": run.subagents[index].emoji],
                        "parentSessionId": Self.sessionId(run),
                    ]
                }
            }
            entries.append([
                "scheduleId": run.schedule.id, "slotKey": "cron:\(Self.ms(run.at))", "at": Self.ms(run.at),
                "run": [
                    "id": Self.runId(run), "kind": run.manual ? "manual" : "due", "status": "completed",
                    "createdAt": Self.ms(run.at), "startedAt": Self.ms(run.at) + 1_000,
                    "completedAt": Self.ms(run.at) + 3_000, "promptDispatch": "delivered", "session": session,
                ],
            ])
        }
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(max(from, Self.ms(now))) / 1000))
        var day = start
        while Self.ms(day) < to {
            let weekday = calendar.component(.weekday, from: day)
            for schedule in schedules {
                var times = schedule.times(weekday).compactMap { calendar.date(bySettingHour: $0.0, minute: $0.1, second: 0, of: day) }
                if schedule.existingSessionId != nil, let at = schedule.trigger["at"] as? Int64, calendar.isDate(Date(timeIntervalSince1970: Double(at) / 1000), inSameDayAs: day) {
                    times.append(Date(timeIntervalSince1970: Double(at) / 1000))
                }
                for time in times where time > now && Self.ms(time) >= from && Self.ms(time) < to {
                    entries.append(["scheduleId": schedule.id, "slotKey": "cron:\(Self.ms(time))", "at": Self.ms(time)])
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? Date(timeIntervalSince1970: Double(to) / 1000)
        }
        entries.sort { ($0["at"] as? Int64 ?? 0) < ($1["at"] as? Int64 ?? 0) }
        var named = schedules.map { summary($0) }
        for index in named.indices { named[index]["model"] = schedules[index].model }
        return ["from": from, "to": to, "now": Self.ms(now), "schedules": named, "entries": entries]
    }
}

/// Answers the Schedules screens' requests from `world`.
final class ScheduleCalendarFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var world: ScheduleCalendarPreviewWorld?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let path = url.path
        let method = request.httpMethod ?? "GET"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> Int64 { query.first { $0.name == name }?.value.flatMap(Int64.init) ?? 0 }
        let parts = path.split(separator: "/").map(String.init)
        var body: Any?
        if let world = Self.world {
            switch (method, parts.count, parts.first ?? "", parts.last ?? "") {
            case ("GET", 1, "schedules", _): body = world.schedulesBody()
            case ("GET", 2, "schedules", "calendar"): body = world.calendarBody(from: value("from"), to: value("to"))
            case ("GET", 2, "schedules", _): body = world.scheduleBody(parts[1])
            case ("GET", 3, "schedules", "runs"): body = world.runsBody(parts[1])
            case ("GET", 1, "agents", _): body = world.agentsBody()
            default: body = nil
            }
        }
        let status = body == nil ? 404 : 200
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data(#"{"error":"not in the preview"}"#.utf8)
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
