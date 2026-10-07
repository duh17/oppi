import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Durable Sessions playground")
struct DurableSessionsPlaygroundTests {
    @Test func availableOnlyWhenTheDeviceOptsInAndTheServerOffersDurable() {
        #expect(DurableSessionsPlayground.isAvailable(experimentEnabled: true, serverOffersDurable: true))
        #expect(!DurableSessionsPlayground.isAvailable(experimentEnabled: true, serverOffersDurable: false))
        #expect(!DurableSessionsPlayground.isAvailable(experimentEnabled: false, serverOffersDurable: true))
        #expect(!DurableSessionsPlayground.isAvailable(experimentEnabled: false, serverOffersDurable: false))
    }

    @Test @MainActor func durableItemFollowsTerminalOrMcpAndPrecedesRemoteScreen() {
        for idiom in [UIUserInterfaceIdiom.phone, .pad] {
            let hidden = WorkspaceSidebarPrimaryUtilities.items(
                for: idiom, sshTerminalEnabled: true, hasSSHProfile: true, durableSessionsAvailable: false
            )
            #expect(!hidden.contains { $0.target == .durableSessions })

            let withTerminal = WorkspaceSidebarPrimaryUtilities.items(
                for: idiom, sshTerminalEnabled: true, hasSSHProfile: true, durableSessionsAvailable: true
            ).map(\.target)
            let terminal = withTerminal.firstIndex(of: .sshTerminal)
            #expect(terminal != nil)
            if let terminal { #expect(withTerminal[terminal + 1] == .durableSessions) }

            let withoutTerminal = WorkspaceSidebarPrimaryUtilities.items(
                for: idiom, sshTerminalEnabled: false, hasSSHProfile: false, durableSessionsAvailable: true
            ).map(\.target)
            let mcp = withoutTerminal.firstIndex(of: .mcpServers)
            #expect(mcp != nil)
            if let mcp { #expect(withoutTerminal[mcp + 1] == .durableSessions) }
            if idiom == .phone { #expect(withoutTerminal.last == .desktopStill) }
        }
    }

    @Test func listKeepsOnlyDurableWorkspaceSessionsNewestFirst() {
        let now = Date()
        func session(_ id: String, engine: SessionEngine, minutesAgo: Double, control: Bool = false) -> Session {
            Session(
                id: id,
                workspaceId: control ? nil : "ws",
                status: .ready,
                createdAt: now,
                lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                messageCount: 0,
                tokens: TokenUsage(input: 0, output: 0),
                cost: 0,
                control: control ? ControlSessionMetadata(domain: .agents, intent: .create, targetId: nil, targetName: nil) : nil,
                engine: engine
            )
        }
        let listed = DurableSessionsPlayground.sessions(from: [
            session("old-durable", engine: .durable, minutesAgo: 90),
            session("classic", engine: .classic, minutesAgo: 1),
            session("new-durable", engine: .durable, minutesAgo: 2),
            session("control", engine: .durable, minutesAgo: 0, control: true),
            {
                var conversation = session("control-conversation", engine: .durable, minutesAgo: 0)
                conversation.workspaceId = nil
                conversation.serverDurableRole = "control"
                return conversation
            }(),
        ])
        #expect(listed.map(\.id) == ["new-durable", "old-durable"])
    }

    @Test func listKeepsOlderHistoryAndPrefersLiveCopies() {
        let now = Date()
        func session(_ id: String, status: SessionStatus, daysAgo: Double, engine: SessionEngine = .durable) -> Session {
            Session(
                id: id,
                workspaceId: "ws",
                status: status,
                createdAt: now,
                lastActivity: now.addingTimeInterval(-daysAgo * 86_400),
                messageCount: 0,
                tokens: TokenUsage(input: 0, output: 0),
                cost: 0,
                engine: engine
            )
        }
        let listed = DurableSessionsPlayground.sessions(
            history: [
                session("month-old", status: .stopped, daysAgo: 30),
                session("recent", status: .ready, daysAgo: 1),
            ],
            live: [
                session("recent", status: .busy, daysAgo: 0),
                session("just-created", status: .ready, daysAgo: 0.5),
                session("classic", status: .ready, daysAgo: 0, engine: .classic),
            ]
        )
        #expect(listed.map(\.id) == ["recent", "just-created", "month-old"])
        #expect(listed.first?.status == .busy)
    }

    @Test func serverInfoAdvertisesDurableSessionsOnlyWhenPresent() throws {
        func capabilities(_ extra: String) throws -> ServerInfo.Capabilities? {
            let json = """
            {"name":"t","version":"0.50.0","uptime":1,"os":"darwin","arch":"arm64","hostname":"t",
             "nodeVersion":"v24","piVersion":"0.85.0","configVersion":1,"identity":null,
             "capabilities":{"sessionStream":{"version":1}\(extra)},
             "stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}}
            """
            return try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8)).capabilities
        }
        #expect(try capabilities(#","durableSessions":{"version":1}"#)?.durableSessions?.version == 1)
        #expect(try capabilities("")?.durableSessions == nil)
    }

    @Test func durableScopeKeepsStoppedHistoryPastTheAllSessionsWindow() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func stopped(_ id: String, daysAgo: Double) -> Session {
            Session(
                id: id,
                workspaceId: "ws",
                status: .stopped,
                createdAt: now,
                lastActivity: now.addingTimeInterval(-daysAgo * 86_400),
                messageCount: 0,
                tokens: TokenUsage(input: 0, output: 0),
                cost: 0,
                engine: .durable
            )
        }
        let sessions = [stopped("today", daysAgo: 0), stopped("month-old", daysAgo: 30)]
        func stoppedIds(_ scope: SessionInboxScope) -> [String] {
            SessionInboxGrouping.make(
                items: sessions,
                now: now,
                calendar: calendar,
                session: { $0 },
                attention: { _ in .none },
                stoppedDayLimit: scope.stoppedDayLimit
            ).stoppedGroups.flatMap { $0.items.map(\.id) }
        }
        #expect(stoppedIds(.all) == ["today"])
        #expect(stoppedIds(.durable) == ["today", "month-old"])
    }

    @Test func durableQuickSessionBarLaunchesDurableOnItsServerOnly() {
        #expect(SessionInboxScope.all.quickSessionLaunch(serverId: "server-a", durableAvailable: false) == .standard)
        #expect(SessionInboxScope.durable.quickSessionLaunch(serverId: "server-a", durableAvailable: false) == .unavailable)
        #expect(SessionInboxScope.durable.quickSessionLaunch(serverId: nil, durableAvailable: true) == .unavailable)

        let launch = SessionInboxScope.durable.quickSessionLaunch(serverId: "server-a", durableAvailable: true)
        guard case .context(let context) = launch else {
            Issue.record("Durable scope must hand Quick Session a launch context, got \(launch)")
            return
        }
        #expect(context.engine == .durable)
        let pick = QuickSessionLaunchSelection.initialWorkspace(
            launchContext: context,
            workspaces: [
                .init(serverId: "server-b", workspaceId: "b1", name: "b1"),
                .init(serverId: "server-a", workspaceId: "a1", name: "a1"),
            ],
            preferred: nil
        )
        #expect(pick?.serverId == "server-a")
    }

    @Test func durableQuickSessionCannotLaunchASavedAgent() throws {
        #expect(!QuickSessionLaunchSelection.allowsAgents(engine: .durable))
        #expect(QuickSessionLaunchSelection.launchAgentId(selected: "reviewer", engine: .classic) == "reviewer")

        // A remembered Agent selection cannot turn a durable launch into an Agent launch.
        let agentId = QuickSessionLaunchSelection.launchAgentId(selected: "reviewer", engine: .durable)
        let plan = try QuickSessionLaunchRouting.plan(for: QuickSessionLaunchRequest(
            workspaceId: "ws",
            agentId: agentId,
            prompt: "Review this",
            hasAttachments: false,
            hasRepoReferences: false
        )).get()
        #expect(plan.mode == .plainPi)
    }
}
