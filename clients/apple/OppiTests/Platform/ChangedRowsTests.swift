import Testing
@testable import Oppi

@Suite("ChangedRows")
struct ChangedRowsTests {
    private enum Row: Hashable { case thinking, status, tools }

    @Test func firstPassChangesEveryRowThenOnlyTheRowWhoseInputsChanged() {
        var rows = ChangedRows<Row>()
        var inputs: [Row: AnyHashable] = [.thinking: "medium", .status: "loaded", .tools: 3]
        let all: [Row] = [.thinking, .status, .tools]

        #expect(Set(rows.changed(in: all) { (inputs[$0] ?? AnyHashable(0)) }) == Set(all))
        #expect(rows.changed(in: all) { (inputs[$0] ?? AnyHashable(0)) }.isEmpty)

        // A resource load flipping the status row must not rebuild the pop-up row.
        inputs[.status] = "loading"
        #expect(rows.changed(in: all) { (inputs[$0] ?? AnyHashable(0)) } == [.status])
        #expect(rows.changed(in: all) { (inputs[$0] ?? AnyHashable(0)) }.isEmpty)
    }

    @Test func aRowThatLeavesAndReturnsIsChangedAgain() {
        var rows = ChangedRows<Row>()
        _ = rows.changed(in: [.thinking, .status]) { _ in 1 }
        _ = rows.changed(in: [.thinking]) { _ in 1 }
        #expect(rows.changed(in: [.thinking, .status]) { _ in 1 } == [.status])
    }
}
