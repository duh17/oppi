import Testing
@testable import Oppi

@Suite("SettingValue")
struct SettingValueTests {
    private typealias State = SettingValue<String>

    @Test("What a row draws is the stored, shown, or last known value")
    func currentValue() {
        #expect(State.loading.current == nil)
        #expect(State.value("a", revision: 3).current == "a")
        #expect(State.saving(shown: "b", previous: "a").current == "b")
        #expect(State.failed(last: "a", reason: "x").current == "a")
        #expect(State.failed(last: nil, reason: "x").current == nil)
        #expect(State.unavailable(reason: "x").current == nil)
    }

    @Test("A change can start only from a known value to roll back to")
    func beginSaving() {
        #expect(State.value("a", revision: 3).beginSaving("b") == .saving(shown: "b", previous: "a"))
        // A failed write keeps its last value, so it can be tried again.
        #expect(State.failed(last: "a", reason: "x").beginSaving("b") == .saving(shown: "b", previous: "a"))
        #expect(State.failed(last: nil, reason: "x").beginSaving("b") == nil)
        #expect(State.loading.beginSaving("b") == nil)
        #expect(State.saving(shown: "b", previous: "a").beginSaving("c") == nil)
        #expect(State.unavailable(reason: "x").beginSaving("b") == nil)
    }

    @Test("A saved write settles to the value the store reports, with its revision")
    func saved() {
        let saving = State.saving(shown: "b", previous: "a")
        #expect(saving.saved(revision: 4) == .value("b", revision: 4))
        #expect(saving.saved(stored: "b2", revision: nil) == .value("b2", revision: nil))
        // Without a write in flight there is nothing to settle.
        #expect(State.value("a", revision: 3).saved(revision: 9) == .value("a", revision: 3))
    }

    @Test("A failed write rolls back to the previous value with the reason")
    func rolledBack() {
        #expect(State.saving(shown: "b", previous: "a").rolledBack(reason: "offline") == .failed(last: "a", reason: "offline"))
        #expect(State.value("a", revision: 3).rolledBack(reason: "offline") == .failed(last: "a", reason: "offline"))
        #expect(State.failed(last: "a", reason: "old").rolledBack(reason: "new") == .failed(last: "a", reason: "new"))
        #expect(State.loading.rolledBack(reason: "offline") == .failed(last: nil, reason: "offline"))
        #expect(State.unavailable(reason: "x").rolledBack(reason: "offline") == .failed(last: nil, reason: "offline"))
    }

    @Test("A write that lost to a newer revision returns to the previous value to be reloaded")
    func revertedToPrevious() {
        #expect(State.saving(shown: "b", previous: "a").revertedToPrevious() == .value("a", revision: nil))
        #expect(State.value("a", revision: 3).revertedToPrevious() == .value("a", revision: 3))
    }

    @Test("Each state answers the questions a row asks")
    func queries() {
        #expect(State.saving(shown: "b", previous: "a").isSaving)
        #expect(!State.value("a", revision: nil).isSaving)
        #expect(State.failed(last: "a", reason: "why").failureReason == "why")
        #expect(State.unavailable(reason: "no server").unavailableReason == "no server")
        #expect(State.value("a", revision: nil).failureReason == nil)
        #expect(State.value("a", revision: nil).canBeginSaving)
        #expect(!State.loading.canBeginSaving)
    }
}
