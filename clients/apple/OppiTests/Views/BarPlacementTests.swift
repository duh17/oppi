import CoreGraphics
import Testing
@testable import Oppi

private enum Tool: String, BarLayoutAction {
    case a, b, c, d, e
    static let defaultShown: Set<Tool> = Set(allCases)
}

/// One button of a `Tool`; `index` tells apart the several buttons one action
/// can stand for.
private struct ToolSlot: BarSlot, Equatable {
    var item: Tool
    var index = 0
    var menuWhenTurnedOff = true
    var menuWhenCrowdedOut = true
    var id: String { "\(item.rawValue).\(index)" }
}

private func names(_ slots: [ToolSlot]) -> [String] { slots.map(\.id) }

/// The rules every customizable bar shares (`BarLayout.placement`), and how
/// many buttons a bar has room for (`BarCapacity`, the chat bar's widths).
@Suite("Bar placement")
struct BarPlacementTests {
    private let everything = Set(Tool.allCases)
    private let oneEach: (Tool) -> [ToolSlot] = { [ToolSlot(item: $0)] }

    @Test func theUsersOrderIsThePriorityAndTheRestLeaveFromTheEndIntoTheMenu() {
        let layout = BarLayout<Tool>(order: [.c, .a, .e, .b, .d], shown: everything)
        let placement = layout.placement(available: everything, capacity: 2, slots: oneEach)
        #expect(names(placement.bar) == ["c.0", "a.0"])
        #expect(names(placement.menu) == ["e.0", "b.0", "d.0"])

        let roomy = layout.placement(available: everything, capacity: 9, slots: oneEach)
        #expect(names(roomy.bar) == ["c.0", "a.0", "e.0", "b.0", "d.0"])
        #expect(roomy.menu.isEmpty)
        #expect(layout.placement(available: everything, capacity: -1, slots: oneEach).bar.isEmpty)
    }

    @Test func turnedOffAndCrowdedOutButtonsShareTheMenuInTheUsersOrder() {
        let layout = BarLayout<Tool>(order: [.c, .a, .e, .b, .d], shown: [.c, .e, .b])
        let placement = layout.placement(available: everything, capacity: 1, slots: oneEach)
        #expect(names(placement.bar) == ["c.0"])
        // a and d are off, e and b had no room: one menu, in the bar's order.
        #expect(names(placement.menu) == ["a.0", "e.0", "b.0", "d.0"])
    }

    @Test func anActionTheScreenCannotOfferIsNeitherDrawnNorOfferedAndTakesNoRoom() {
        let layout = BarLayout<Tool>(order: Tool.allCases, shown: [.a, .b, .c])
        let placement = layout.placement(available: [.b, .c, .d], capacity: 2, slots: oneEach)
        #expect(names(placement.bar) == ["b.0", "c.0"])
        #expect(names(placement.menu) == ["d.0"])
    }

    @Test func aButtonThatOptsOutOfTheMenuIsLeftOutThere() {
        let slots: (Tool) -> [ToolSlot] = { tool in
            switch tool {
            case .a: [ToolSlot(item: .a, menuWhenCrowdedOut: false)]
            case .d: [ToolSlot(item: .d, menuWhenTurnedOff: false)]
            default: [ToolSlot(item: tool)]
            }
        }
        let layout = BarLayout<Tool>(order: [.b, .a, .c, .d, .e], shown: [.b, .a, .c])
        let placement = layout.placement(available: everything, capacity: 1, slots: slots)
        #expect(names(placement.bar) == ["b.0"])
        // a had no room but stays out of the menu; d is off and stays out too.
        #expect(names(placement.menu) == ["c.0", "e.0"])
    }

    @Test func anActionThatStandsForSeveralButtonsSpendsOneSlotEach() {
        let slots: (Tool) -> [ToolSlot] = { tool in
            tool == .b ? (0..<3).map { ToolSlot(item: .b, index: $0) } : [ToolSlot(item: tool)]
        }
        let layout = BarLayout<Tool>(order: Tool.allCases, shown: [.a, .b, .c])
        let placement = layout.placement(available: everything, capacity: 3, slots: slots)
        #expect(names(placement.bar) == ["a.0", "b.0", "b.1"])
        #expect(names(placement.menu) == ["b.2", "c.0", "d.0", "e.0"])
    }

    @Test func capacityIsWholeSlotsOfWhatTheFixedItemsLeave() {
        #expect(BarCapacity.slots(width: 300, fixed: 80) == 5)
        #expect(BarCapacity.slots(width: 300, fixed: 79) == 5)
        #expect(BarCapacity.slots(width: 300, fixed: 81) == 4)
        #expect(BarCapacity.slots(width: 40, fixed: 80) == 0)
        #expect(BarCapacity.slots(width: 300, fixed: 0, slotWidth: 100) == 3)
    }

    /// The chat bar beside Back, a title, and …: an iPhone and the narrowest
    /// pane hold a few buttons, 500 pt the whole catalog, an iPad mini in
    /// portrait everything. The iPad's sidebar toggle takes one place.
    @MainActor
    @Test func theChatBarHoldsAFewButtonsAtIPhoneWidthAndEveryButtonFromAbout500Points() {
        let catalog = ChatTopBarAction.allCases.count
        #expect(ChatBarItems.capacity(barWidth: 375, leadingItems: 1) == 3)
        #expect(ChatBarItems.capacity(barWidth: 500, leadingItems: 1) >= catalog)
        #expect(ChatBarItems.capacity(barWidth: 744, leadingItems: 2) >= catalog)
        #expect(ChatBarItems.capacity(barWidth: 375, leadingItems: 2) < ChatBarItems.capacity(barWidth: 375, leadingItems: 1))
        // No width yet (before the first layout): nothing is crowded out.
        #expect(ChatBarItems.capacity(barWidth: 0, leadingItems: 1) >= catalog)
    }
}
