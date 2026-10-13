import Foundation
import Testing
@testable import Oppi

@Suite("Durable Sessions experiment")
struct DurableSessionsTests {
    private func decide(
        experiment: Bool,
        offered: Bool,
        savedAgent: Bool = false,
        chose classic: Bool = false,
        agent resolution: DurableSessions.AgentResolution = .resolved
    ) -> DurableSessions.LaunchDecision {
        DurableSessions.launchDecision(
            experimentEnabled: experiment,
            serverOffersDurable: offered,
            savedAgentSelected: savedAgent,
            userChoseClassic: classic,
            agentResolution: resolution
        )
    }

    @Test func newSessionsStartDurableOnlyWhenTheDeviceOptsInAndTheServerOffersDurable() {
        let durable = decide(experiment: true, offered: true)
        #expect(durable.engine == .durable)
        #expect(durable.showsPill)
        #expect(durable.canToggle)
        #expect(durable.classicReason == nil)

        for (experiment, offered) in [(true, false), (false, true), (false, false)] {
            let classic = decide(experiment: experiment, offered: offered)
            #expect(classic.engine == .classic, "experiment \(experiment), offered \(offered)")
            #expect(!classic.showsPill)
            #expect(!classic.canToggle)
        }
    }

    @Test func switchingToClassicIsOneLaunchAndReversible() {
        let classic = decide(experiment: true, offered: true, chose: true)
        #expect(classic.engine == .classic)
        #expect(classic.showsPill)
        #expect(classic.canToggle)
        #expect(classic.classicReason == nil)
    }

    @Test func savedAgentLaunchRunsClassicWithAReasonAndCannotBeToggled() {
        for chose in [false, true] {
            let agent = decide(experiment: true, offered: true, savedAgent: true, chose: chose)
            #expect(agent.engine == .classic)
            #expect(agent.showsPill)
            #expect(!agent.canToggle)
            #expect(agent.classicReason == DurableSessions.savedAgentClassicReason)
        }
    }

    @Test func aLaunchWhoseSavedAgentIsNotResolvedIsBlockedAndNeverDurable() {
        for resolution in [DurableSessions.AgentResolution.pending, .failed] {
            for chose in [false, true] {
                let held = decide(experiment: true, offered: true, chose: chose, agent: resolution)
                #expect(held.blocksLaunch, "\(resolution), chose classic \(chose)")
                #expect(held.engine == .classic)
                #expect(!held.canToggle)
                #expect(held.classicReason == resolution.blockReason)
            }
        }
        #expect(!decide(experiment: true, offered: true, agent: .resolved).blocksLaunch)
        #expect(!decide(experiment: true, offered: true, savedAgent: true).blocksLaunch)
        // Without durable there is nothing to protect, so the hold does not apply.
        #expect(!decide(experiment: false, offered: true, agent: .pending).blocksLaunch)
        #expect(!decide(experiment: true, offered: false, agent: .failed).blocksLaunch)
    }

    @Test func aClassicChoiceOrAgentChangesNothingWhenDurableIsUnavailable() {
        let off = decide(experiment: false, offered: true, savedAgent: true, chose: true)
        #expect(off.engine == .classic)
        #expect(!off.showsPill)
        #expect(off.classicReason == nil)
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
}
