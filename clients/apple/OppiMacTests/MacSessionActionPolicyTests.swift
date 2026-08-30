import Testing
@testable import Oppi

@Suite("Shared session action policy")
struct MacSessionActionPolicyTests {
    @Test func stopIsAvailableForActiveSessionStates() {
        #expect(SessionActionPolicy.canStop(.starting))
        #expect(SessionActionPolicy.canStop(.ready))
        #expect(SessionActionPolicy.canStop(.busy))
    }

    @Test func stopIsHiddenForTerminalOrStoppingStates() {
        #expect(!SessionActionPolicy.canStop(.stopping))
        #expect(!SessionActionPolicy.canStop(.stopped))
        #expect(!SessionActionPolicy.canStop(.error))
    }

    @Test func deleteIsOnlyAvailableForTerminalHistoryRows() {
        #expect(SessionActionPolicy.canDelete(.stopped))
        #expect(SessionActionPolicy.canDelete(.error))
        #expect(!SessionActionPolicy.canDelete(.starting))
        #expect(!SessionActionPolicy.canDelete(.ready))
        #expect(!SessionActionPolicy.canDelete(.busy))
        #expect(!SessionActionPolicy.canDelete(.stopping))
    }

    @Test func macNameRemainsAnAliasForCallers() {
        #expect(MacSessionActionPolicy.canStop(.ready) == SessionActionPolicy.canStop(.ready))
    }
}
