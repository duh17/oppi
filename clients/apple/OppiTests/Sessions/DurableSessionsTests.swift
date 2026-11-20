import Foundation
import Testing
@testable import Oppi

@Suite("Durable Sessions")
struct DurableSessionsTests {
    private func decide(
        offered: Bool,
        durableDefault: Bool = false,
        incognito: Bool = false,
        chose engine: SessionEngine? = nil,
        agent resolution: DurableSessions.AgentResolution = .resolved,
        agentRequires required: SessionEngine? = nil
    ) -> DurableSessions.LaunchDecision {
        DurableSessions.launchDecision(
            serverOffersDurable: offered,
            durableByDefault: durableDefault,
            incognito: incognito,
            chosenEngine: engine,
            agentResolution: resolution,
            agentRequiredEngine: required
        )
    }

    @Test func aDurableOnlyAgentLaunchesDurableWithAFixedPillWhateverWasChosen() {
        for chose in [nil, SessionEngine.classic, .durable] {
            let fixed = decide(offered: true, chose: chose, agentRequires: .durable)
            #expect(fixed.engine == .durable, "chose \(String(describing: chose))")
            #expect(fixed.showsPill)
            #expect(!fixed.canToggle)
            #expect(!fixed.blocksLaunch)
            #expect(fixed.fixedReason != nil)
        }
        // An unresolved Agent still holds the launch.
        #expect(decide(offered: true, agent: .pending, agentRequires: .durable).blocksLaunch)
    }

    @Test func newSessionsStartClassicWithASwitchUnlessDurableIsTheDefault() {
        let classic = decide(offered: true)
        #expect(classic.engine == .classic)
        #expect(classic.showsPill)
        #expect(classic.canToggle)
        #expect(classic.fixedReason == nil)

        let durable = decide(offered: true, durableDefault: true)
        #expect(durable.engine == .durable)
        #expect(durable.showsPill)
        #expect(durable.canToggle)
    }

    @Test func durableNeedsTheServerEvenWhenItIsTheDefault() {
        let classic = decide(offered: false, durableDefault: true, chose: .durable)
        #expect(classic.engine == .classic)
        #expect(!classic.showsPill)
        #expect(!classic.canToggle)
        #expect(classic.fixedReason == nil)
    }

    @Test func thePillChoiceOverridesTheDefaultForOneLaunchInEitherDirection() {
        let durable = decide(offered: true, chose: .durable)
        #expect(durable.engine == .durable)
        #expect(durable.canToggle)

        let classic = decide(offered: true, durableDefault: true, chose: .classic)
        #expect(classic.engine == .classic)
        #expect(classic.canToggle)
        #expect(classic.fixedReason == nil)
    }

    @Test func incognitoLaunchRunsClassicWithoutAnEnginePillEvenWhenDurableWasChosen() {
        for chose in [nil, SessionEngine.durable] {
            let incognito = decide(offered: true, durableDefault: true, incognito: true, chose: chose)
            #expect(incognito.engine == .classic)
            #expect(!incognito.showsPill)
            #expect(!incognito.canToggle)
        }
    }

    @Test func aLaunchWhoseSavedAgentIsNotResolvedIsBlockedAndNeverDurable() {
        for resolution in [DurableSessions.AgentResolution.pending, .failed] {
            for chose in [nil, SessionEngine.durable] {
                let held = decide(offered: true, durableDefault: true, chose: chose, agent: resolution)
                #expect(held.blocksLaunch, "\(resolution), chose \(String(describing: chose))")
                #expect(held.engine == .classic)
                #expect(!held.canToggle)
                #expect(held.fixedReason == resolution.blockReason)
            }
        }
        #expect(!decide(offered: true, agent: .resolved).blocksLaunch)
        // Without durable there is nothing to protect, so the hold does not apply.
        #expect(!decide(offered: false, agent: .pending).blocksLaunch)
        #expect(!decide(offered: false, agent: .failed).blocksLaunch)
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
