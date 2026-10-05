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
        ])
        #expect(listed.map(\.id) == ["new-durable", "old-durable"])
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

    @Test func durableQuickSessionLaunchStaysOnItsServer() {
        let context = QuickSessionLaunchContext(durableOnServer: "server-a")
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
}
