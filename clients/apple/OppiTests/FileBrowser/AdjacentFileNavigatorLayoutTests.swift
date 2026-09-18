import Testing
@testable import Oppi

@Suite("Adjacent file navigator layout")
struct AdjacentFileNavigatorLayoutTests {
    @Test func documentPillKeepsBothDirectionsLeading() {
        let slots = AdjacentFileNavigatorLayout.slots(
            canGoPrevious: true,
            canGoNext: true,
            placement: .leadingPill
        )

        #expect(slots.map(\.corner) == [.leading, .leading])
        #expect(slots.map(\.systemImage) == ["chevron.left", "chevron.right"])
        #expect(slots.map(\.accessibilityLabel) == ["Previous file", "Next file"])
        #expect(!slots.contains { $0.corner == .trailing })
    }

    @Test func documentPillKeepsASingleDirectionInTheOriginalLeadingSlot() {
        let previousOnly = AdjacentFileNavigatorLayout.slots(
            canGoPrevious: true,
            canGoNext: false,
            placement: .leadingPill
        )
        let nextOnly = AdjacentFileNavigatorLayout.slots(
            canGoPrevious: false,
            canGoNext: true,
            placement: .leadingPill
        )

        #expect(previousOnly == [
            AdjacentFileNavigatorLayout.Slot(
                corner: .leading,
                systemImage: "chevron.left",
                accessibilityLabel: "Previous file"
            )
        ])
        #expect(nextOnly == [
            AdjacentFileNavigatorLayout.Slot(
                corner: .leading,
                systemImage: "chevron.right",
                accessibilityLabel: "Next file"
            )
        ])
    }

    @Test func audioSplitKeepsPreviousLeadingAndNextTrailing() {
        let slots = AdjacentFileNavigatorLayout.slots(
            canGoPrevious: true,
            canGoNext: true,
            placement: .splitCorners
        )

        #expect(slots == [
            AdjacentFileNavigatorLayout.Slot(
                corner: .leading,
                systemImage: "chevron.left",
                accessibilityLabel: "Previous file"
            ),
            AdjacentFileNavigatorLayout.Slot(
                corner: .trailing,
                systemImage: "chevron.right",
                accessibilityLabel: "Next file"
            )
        ])
    }

    @Test func audioSplitNextOnlyStaysTrailing() {
        let slots = AdjacentFileNavigatorLayout.slots(
            canGoPrevious: false,
            canGoNext: true,
            placement: .splitCorners
        )

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
        #expect(
            AdjacentFileNavigatorLayout.slots(
                canGoPrevious: false,
                canGoNext: false,
                placement: .leadingPill
            ).isEmpty
        )
        #expect(
            AdjacentFileNavigatorLayout.slots(
                canGoPrevious: false,
                canGoNext: false,
                placement: .splitCorners
            ).isEmpty
        )
    }

    @Test func previousNeverUsesTrailing() {
        for placement in [AdjacentFileNavigatorPlacement.leadingPill, .splitCorners] {
            for canGoNext in [false, true] {
                let slots = AdjacentFileNavigatorLayout.slots(
                    canGoPrevious: true,
                    canGoNext: canGoNext,
                    placement: placement
                )
                let previous = slots.filter { $0.accessibilityLabel == "Previous file" }
                #expect(previous.count == 1)
                #expect(previous.first?.corner == .leading)
            }
        }
    }

    @Test func leadingAccessoryCountTreatsTheDocumentPillAsOneControl() {
        #expect(
            AdjacentFileNavigatorLayout.leadingAccessoryCount(
                canGoPrevious: true,
                canGoNext: true,
                placement: .leadingPill
            ) == 1
        )
        #expect(
            AdjacentFileNavigatorLayout.leadingAccessoryCount(
                canGoPrevious: false,
                canGoNext: true,
                placement: .leadingPill
            ) == 1
        )
        #expect(
            AdjacentFileNavigatorLayout.leadingAccessoryCount(
                canGoPrevious: true,
                canGoNext: true,
                placement: .splitCorners
            ) == 1
        )
        #expect(
            AdjacentFileNavigatorLayout.leadingAccessoryCount(
                canGoPrevious: false,
                canGoNext: true,
                placement: .splitCorners
            ) == 0
        )
        #expect(
            AdjacentFileNavigatorLayout.leadingAccessoryCount(
                canGoPrevious: false,
                canGoNext: false,
                placement: .leadingPill
            ) == 0
        )
    }

    @Test func groupedPillUsesCompactChevronHitsInsideOneControlHeight() {
        #expect(AdjacentFileNavigatorLayout.groupedHitWidth == 44)
        #expect(AdjacentFileNavigatorLayout.groupedHorizontalInset == 6)
        #expect(FullScreenFloatingControlChrome.controlSize == 56)
    }

    @Test func readerDocumentsUseALeadingPillAndAudioVideoKeepSplitCorners() {
        #expect(AdjacentFileNavigatorPlacementPolicy.placement(for: .text) == .leadingPill)
        #expect(AdjacentFileNavigatorPlacementPolicy.placement(for: .image) == .leadingPill)
        #expect(AdjacentFileNavigatorPlacementPolicy.placement(for: .pdf) == .leadingPill)
        #expect(AdjacentFileNavigatorPlacementPolicy.placement(for: .usdz) == .leadingPill)
        #expect(AdjacentFileNavigatorPlacementPolicy.placement(for: .binary) == .leadingPill)
        #expect(AdjacentFileNavigatorPlacementPolicy.placement(for: .audio) == .splitCorners)
        #expect(AdjacentFileNavigatorPlacementPolicy.placement(for: .video) == .splitCorners)
    }
}
