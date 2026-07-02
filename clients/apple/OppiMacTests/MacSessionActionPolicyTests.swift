import Testing
@testable import Oppi

@Suite("Mac session action policy")
struct MacSessionActionPolicyTests {
    @Test func stopIsAvailableForActiveSessionStates() {
        #expect(MacSessionActionPolicy.canStop(.starting))
        #expect(MacSessionActionPolicy.canStop(.ready))
        #expect(MacSessionActionPolicy.canStop(.busy))
    }

    @Test func stopIsHiddenForTerminalOrStoppingStates() {
        #expect(!MacSessionActionPolicy.canStop(.stopping))
        #expect(!MacSessionActionPolicy.canStop(.stopped))
        #expect(!MacSessionActionPolicy.canStop(.error))
    }

    @Test func deleteIsOnlyAvailableForTerminalHistoryRows() {
        #expect(MacSessionActionPolicy.canDelete(.stopped))
        #expect(MacSessionActionPolicy.canDelete(.error))
        #expect(!MacSessionActionPolicy.canDelete(.starting))
        #expect(!MacSessionActionPolicy.canDelete(.ready))
        #expect(!MacSessionActionPolicy.canDelete(.busy))
        #expect(!MacSessionActionPolicy.canDelete(.stopping))
    }
}
