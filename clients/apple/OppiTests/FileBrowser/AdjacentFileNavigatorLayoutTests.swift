import Testing
@testable import Oppi

@Suite("Adjacent file navigator layout")
struct AdjacentFileNavigatorLayoutTests {
    @Test func previousPinsLeadingAndNextPinsTrailing() {
        let slots = AdjacentFileNavigatorLayout.slots(canGoPrevious: true, canGoNext: true)

        #expect(slots.map(\.corner) == [.leading, .trailing])
        #expect(slots.map(\.systemImage) == ["chevron.left", "chevron.right"])
        #expect(slots.map(\.accessibilityLabel) == ["Previous file", "Next file"])
    }

    @Test func previousOnlyStaysLeading() {
        let slots = AdjacentFileNavigatorLayout.slots(canGoPrevious: true, canGoNext: false)

        #expect(slots == [
            AdjacentFileNavigatorLayout.Slot(
                corner: .leading,
                systemImage: "chevron.left",
                accessibilityLabel: "Previous file"
            )
        ])
        #expect(!slots.contains { $0.corner == .trailing })
    }

    @Test func nextOnlyStaysTrailing() {
        let slots = AdjacentFileNavigatorLayout.slots(canGoPrevious: false, canGoNext: true)

        #expect(slots == [
            AdjacentFileNavigatorLayout.Slot(
                corner: .trailing,
                systemImage: "chevron.right",
                accessibilityLabel: "Next file"
            )
        ])
        #expect(!slots.contains { $0.corner == .leading })
    }

    @Test func neitherDirectionProducesNoControls() {
        #expect(AdjacentFileNavigatorLayout.slots(canGoPrevious: false, canGoNext: false).isEmpty)
    }

    @Test func previousNeverUsesTrailingOrCenter() {
        for canGoNext in [false, true] {
            let slots = AdjacentFileNavigatorLayout.slots(canGoPrevious: true, canGoNext: canGoNext)
            let previous = slots.filter { $0.accessibilityLabel == "Previous file" }
            #expect(previous.count == 1)
            #expect(previous.first?.corner == .leading)
        }
    }

    @Test func nextNeverUsesLeadingOrCenter() {
        for canGoPrevious in [false, true] {
            let slots = AdjacentFileNavigatorLayout.slots(canGoPrevious: canGoPrevious, canGoNext: true)
            let next = slots.filter { $0.accessibilityLabel == "Next file" }
            #expect(next.count == 1)
            #expect(next.first?.corner == .trailing)
        }
    }
}
