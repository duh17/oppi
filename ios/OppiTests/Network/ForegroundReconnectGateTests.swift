import Testing
@testable import Oppi

@Suite("ForegroundReconnectGate")
struct ForegroundReconnectGateTests {
    @Test func doesNotReconnectWithoutBackground() {
        var gate = ForegroundReconnectGate()

        #expect(gate.shouldReconnect(for: .active) == false)
        #expect(gate.shouldReconnect(for: .inactive) == false)
        #expect(gate.shouldReconnect(for: .active) == false)
    }

    @Test func reconnectsAfterBackgroundThenActive() {
        var gate = ForegroundReconnectGate()

        #expect(gate.shouldReconnect(for: .background) == false)
        #expect(gate.shouldReconnect(for: .inactive) == false)
        #expect(gate.shouldReconnect(for: .active) == true)
    }

    @Test func backgroundFlagIsConsumedAfterFirstActive() {
        var gate = ForegroundReconnectGate()

        #expect(gate.shouldReconnect(for: .background) == false)
        #expect(gate.shouldReconnect(for: .active) == true)
        #expect(gate.shouldReconnect(for: .active) == false)
    }
}
