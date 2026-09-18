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

    @Test func accessoryCountsMatchVisibleCorners() {
        #expect(
            AdjacentFileNavigatorLayout.leadingAccessoryCount(canGoPrevious: true, canGoNext: true) == 1
        )
        #expect(
            AdjacentFileNavigatorLayout.trailingAccessoryCount(canGoPrevious: true, canGoNext: true) == 1
        )
        #expect(
            AdjacentFileNavigatorLayout.leadingAccessoryCount(canGoPrevious: false, canGoNext: true) == 0
        )
        #expect(
            AdjacentFileNavigatorLayout.trailingAccessoryCount(canGoPrevious: false, canGoNext: true) == 1
        )
        #expect(
            AdjacentFileNavigatorLayout.leadingAccessoryCount(canGoPrevious: true, canGoNext: false) == 1
        )
        #expect(
            AdjacentFileNavigatorLayout.trailingAccessoryCount(canGoPrevious: true, canGoNext: false) == 0
        )
        #expect(
            AdjacentFileNavigatorLayout.leadingAccessoryCount(canGoPrevious: false, canGoNext: false) == 0
        )
        #expect(
            AdjacentFileNavigatorLayout.trailingAccessoryCount(canGoPrevious: false, canGoNext: false) == 0
        )
    }
}
