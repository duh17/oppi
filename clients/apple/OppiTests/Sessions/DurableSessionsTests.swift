import Foundation
import Testing
@testable import Oppi

@Suite("Durable Sessions experiment")
struct DurableSessionsTests {
    private func decide(
        experiment: Bool,
        offered: Bool,
        durableDefault: Bool = false,
        savedAgent: Bool = false,
        chose engine: SessionEngine? = nil,
        agent resolution: DurableSessions.AgentResolution = .resolved
    ) -> DurableSessions.LaunchDecision {
        DurableSessions.launchDecision(
            experimentEnabled: experiment,
            serverOffersDurable: offered,
            durableByDefault: durableDefault,
            savedAgentSelected: savedAgent,
            chosenEngine: engine,
            agentResolution: resolution
        )
    }

    @Test func newSessionsStartClassicWithASwitchUnlessDurableIsTheDefault() {
        let classic = decide(experiment: true, offered: true)
        #expect(classic.engine == .classic)
        #expect(classic.showsPill)
        #expect(classic.canToggle)
        #expect(classic.classicReason == nil)

        let durable = decide(experiment: true, offered: true, durableDefault: true)
        #expect(durable.engine == .durable)
        #expect(durable.showsPill)
        #expect(durable.canToggle)
    }

    @Test func durableNeedsTheDeviceOptInAndTheServerEvenWhenItIsTheDefault() {
        for (experiment, offered) in [(true, false), (false, true), (false, false)] {
            let classic = decide(experiment: experiment, offered: offered, durableDefault: true, chose: .durable)
            #expect(classic.engine == .classic, "experiment \(experiment), offered \(offered)")
            #expect(!classic.showsPill)
            #expect(!classic.canToggle)
        }
    }

    @Test func thePillChoiceOverridesTheDefaultForOneLaunchInEitherDirection() {
        let durable = decide(experiment: true, offered: true, chose: .durable)
        #expect(durable.engine == .durable)
        #expect(durable.canToggle)

        let classic = decide(experiment: true, offered: true, durableDefault: true, chose: .classic)
        #expect(classic.engine == .classic)
        #expect(classic.canToggle)
        #expect(classic.classicReason == nil)
    }

    @Test func savedAgentLaunchRunsClassicWithAReasonAndCannotBeToggled() {
        for chose in [nil, SessionEngine.durable] {
            let agent = decide(experiment: true, offered: true, durableDefault: true, savedAgent: true, chose: chose)
            #expect(agent.engine == .classic)
            #expect(agent.showsPill)
            #expect(!agent.canToggle)
            #expect(agent.classicReason == DurableSessions.savedAgentClassicReason)
        }
    }

    @Test func aLaunchWhoseSavedAgentIsNotResolvedIsBlockedAndNeverDurable() {
        for resolution in [DurableSessions.AgentResolution.pending, .failed] {
            for chose in [nil, SessionEngine.durable] {
                let held = decide(experiment: true, offered: true, durableDefault: true, chose: chose, agent: resolution)
                #expect(held.blocksLaunch, "\(resolution), chose \(String(describing: chose))")
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

    @Test func aChoiceOrAgentChangesNothingWhenDurableIsUnavailable() {
        let off = decide(experiment: false, offered: true, savedAgent: true, chose: .classic)
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
