import Foundation
import Testing
import UIKit
@testable import Oppi

/// Real-timeline geometry for the device bug where an expanded Read of
/// completed markdown paints its H1 over the previous collapsed skill row.
///
/// Production layout uses `.estimated(100)` and 8pt `interGroupSpacing`.
/// Completed markdown publishes the 620pt capped viewport immediately.
/// That outer sizing pass must land while the expand/collapse anchor is
/// still active, without reloading the following row.
@Suite("Expanded read markdown row overlap", .serialized)
@MainActor
struct ReadMarkdownExpandOverlapTests {
    private static let heading = "Oppi Work-Item Delivery"
    private static let gapTolerance: CGFloat = 0.5
    private static let productionGap: CGFloat = 8
    private static let expectedExpandedReadHeight: CGFloat = 651.67

    @Test func expandedReadMarkdownDoesNotOverlapNeighborSkillRows() async throws {
        let fixture = try Self.makeSkillReadSkillFixture()
        defer { Self.tearDownSkillReadSkillFixture(fixture) }

        let beforeIP = fixture.beforeIP
        let readIP = fixture.readIP
        let afterIP = fixture.afterIP
        let collectionView = fixture.wh.collectionView

        try Self.assertCollapsedChromeOnly(in: collectionView, item: beforeIP.item)
        try Self.assertCollapsedChromeOnly(in: collectionView, item: readIP.item)
        try Self.assertCollapsedChromeOnly(in: collectionView, item: afterIP.item)
        try Self.assertNeighborGeometry(
            in: collectionView,
            beforeIP: beforeIP,
            readIP: readIP,
            afterIP: afterIP,
            heading: Self.heading,
            phase: "before tap",
            requireExpandedReadBody: false
        )

        let headerScreenYBefore = try #require(
            collectionView.layoutAttributesForItem(at: readIP).map {
                $0.frame.minY - collectionView.contentOffset.y
            }
        )
        let contentOffsetBefore = collectionView.contentOffset.y
        let followingIdentityBefore = try #require(
            Self.rowContentIdentity(in: collectionView, at: afterIP)
        )
        let reconfiguredBefore = fixture.wh.coordinator.debugReconfiguredItemIDs
        let wideInvalidationsBefore =
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            )

        var remeasuredIDs: [String] = []
        var remeasuredWhileAnchored = false
        ToolTimelineRowPresentationHelpers.anchoredRemeasureHookForTesting = { view, itemID in
            guard view === collectionView else { return }
            remeasuredIDs.append(itemID)
            if (view as? AnchoredCollectionView)?.expandCollapseAnchorItemID != nil
                || (view as? AnchoredCollectionView)?.expandCollapseAnchorIP != nil {
                remeasuredWhileAnchored = true
            }
        }
        defer {
            ToolTimelineRowPresentationHelpers.anchoredRemeasureHookForTesting = nil
        }

        fixture.wh.coordinator.collectionView(collectionView, didSelectItemAt: readIP)
        collectionView.layoutIfNeeded()

        try Self.assertNeighborGeometry(
            in: collectionView,
            beforeIP: beforeIP,
            readIP: readIP,
            afterIP: afterIP,
            heading: Self.heading,
            phase: "synchronously after didSelectItemAt",
            requireExpandedReadBody: true,
            requireSettledCompletedViewport: false
        )

        let settled = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            collectionView.layoutIfNeeded()
            guard let toolRow = collectionView.cellForItem(at: readIP).flatMap({
                timelineFirstView(ofType: ToolTimelineRowContentView.self, in: $0.contentView)
            }) else {
                return false
            }
            let cellHeight = collectionView.cellForItem(at: readIP)?.frame.height ?? 0
            return remeasuredWhileAnchored
                && abs(toolRow.expandedContainer.bounds.height
                    - ToolTimelineRowContentView.maxExpandedViewportHeight) <= 1
                && abs(cellHeight - Self.expectedExpandedReadHeight) <= 1
        }
        #expect(
            settled,
            "Completed markdown never reached the 620pt outer size while the expand anchor was active"
        )

        try Self.assertNeighborGeometry(
            in: collectionView,
            beforeIP: beforeIP,
            readIP: readIP,
            afterIP: afterIP,
            heading: Self.heading,
            phase: "after anchored remeasure",
            requireExpandedReadBody: true,
            requireSettledCompletedViewport: true
        )

        try expectTimelineRowsUseConfigurationType(
            in: collectionView,
            items: [beforeIP.item],
            as: CollapsedToolTimelineRowConfiguration.self
        )
        try expectTimelineRowsUseConfigurationType(
            in: collectionView,
            items: [readIP.item],
            as: ToolTimelineRowConfiguration.self
        )
        let afterItem = try #require(fixture.items.first { $0.id == fixture.skillAfterID })
        #expect(
            fixture.wh.coordinator.toolRowConfiguration(
                itemID: fixture.skillAfterID,
                item: afterItem
            ) is CollapsedToolTimelineRowConfiguration,
            "Following skill row must stay chrome-only after the Read expands"
        )

        let followingIdentityAfter = try #require(
            Self.rowContentIdentity(in: collectionView, at: afterIP),
            "Following skill cell must stay installed after the Read expands"
        )
        #expect(
            followingIdentityAfter.cell === followingIdentityBefore.cell,
            "Following visible cell instance must survive the Read expand"
        )
        #expect(
            followingIdentityAfter.content === followingIdentityBefore.content,
            "Following visible UIContentView instance must survive the Read expand"
        )

        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            ) == wideInvalidationsBefore,
            "Expand settlement must not timeline-wide invalidateLayout()"
        )

        let reconfiguredAfter = fixture.wh.coordinator.debugReconfiguredItemIDs
        let newReconfigured = Array(reconfiguredAfter.dropFirst(reconfiguredBefore.count))
        #expect(
            newReconfigured.allSatisfy { $0 == fixture.readID },
            "Settlement must not reconfigure neighbor rows; got \(newReconfigured)"
        )
        #expect(
            remeasuredIDs == [fixture.readID],
            "Exactly one tapped-row remeasure; got \(remeasuredIDs)"
        )
        #expect(remeasuredWhileAnchored, "200→620 remeasure must run while the expand anchor is active")

        let headerScreenYAfter = try #require(
            collectionView.layoutAttributesForItem(at: readIP).map {
                $0.frame.minY - collectionView.contentOffset.y
            }
        )
        #expect(
            abs(headerScreenYAfter - headerScreenYBefore) <= Self.gapTolerance,
            "Tapped header screen Y drifted \(headerScreenYAfter - headerScreenYBefore)pt after the second pass"
        )
        #expect(
            abs(collectionView.contentOffset.y - contentOffsetBefore) < 80,
            "Collection contentOffset jumped \(collectionView.contentOffset.y - contentOffsetBefore)pt after the second pass"
        )

        await Task.yield()
        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()
        try Self.assertNeighborGeometry(
            in: collectionView,
            beforeIP: beforeIP,
            readIP: readIP,
            afterIP: afterIP,
            heading: Self.heading,
            phase: "after additional runloop/layout cycle",
            requireExpandedReadBody: true,
            requireSettledCompletedViewport: true
        )
        let followingIdentityAfterExtraCycle = try #require(
            Self.rowContentIdentity(in: collectionView, at: afterIP),
            "Following skill cell must stay installed after an extra layout cycle"
        )
        #expect(followingIdentityAfterExtraCycle.cell === followingIdentityBefore.cell)
        #expect(followingIdentityAfterExtraCycle.content === followingIdentityBefore.content)
    }

    @Test func anchoredRemeasureFollowsOriginalItemIdentityAfterStructuralInsert() async throws {
        let fixture = try Self.makeSkillReadSkillFixture()
        defer { Self.tearDownSkillReadSkillFixture(fixture) }

        var remeasuredIDs: [String] = []
        ToolTimelineRowPresentationHelpers.anchoredRemeasureHookForTesting = { view, itemID in
            guard view === fixture.wh.collectionView else { return }
            remeasuredIDs.append(itemID)
        }
        defer {
            ToolTimelineRowPresentationHelpers.anchoredRemeasureHookForTesting = nil
        }

        fixture.wh.coordinator.collectionView(fixture.wh.collectionView, didSelectItemAt: fixture.readIP)
        fixture.wh.collectionView.layoutIfNeeded()

        let injectedID = "injected-above-read"
        var items = fixture.items
        items.insert(
            .assistantMessage(
                id: injectedID,
                text: "Structural insert above the anchored Read.",
                timestamp: Date()
            ),
            at: 0
        )
        fixture.wh.applyItems(items, isBusy: false)

        let remeasuredOriginal = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            fixture.wh.collectionView.layoutIfNeeded()
            return remeasuredIDs.contains(fixture.readID)
        }
        #expect(remeasuredOriginal, "Original Read identity was not remeasured after a structural insert")
        #expect(
            remeasuredIDs.contains(fixture.readID),
            "Deferred remeasure used a stale index path; ids=\(remeasuredIDs)"
        )
        #expect(
            !remeasuredIDs.contains(injectedID),
            "Deferred remeasure targeted the inserted row; ids=\(remeasuredIDs)"
        )
        #expect(
            !remeasuredIDs.contains("tc-skill-agent-workflow"),
            "Deferred remeasure targeted the previous skill at the stale index path; ids=\(remeasuredIDs)"
        )
        #expect(
            remeasuredIDs.filter { $0 == fixture.readID }.count == 1,
            "Exactly one tapped-row remeasure after the insert; ids=\(remeasuredIDs)"
        )
        #expect(fixture.wh.reducer.expandedItemIDs.contains(fixture.readID))
    }

    @Test func expandedReadMarkdownDoesNotOverlapMoreThanEightInstalledFollowingRows() async throws {
        let fixture = try Self.makeSkillReadSkillFixture(followingSkillCount: 12)
        defer { Self.tearDownSkillReadSkillFixture(fixture) }

        let collectionView = fixture.wh.collectionView
        let followingBefore = Self.installedFollowingIdentities(
            in: collectionView,
            after: fixture.readIP.item,
            ids: fixture.wh.coordinator.currentIDs
        )
        #expect(
            followingBefore.count >= 9,
            "Need at least nine installed following compact rows; got \(followingBefore.count)"
        )
        let ninthBefore = try #require(followingBefore.dropFirst(8).first)

        var remeasuredIDs: [String] = []
        var ninthDuringRemeasure: InstalledFollowerGeometry?
        var followingDuringRemeasure: [InstalledFollowingIdentity] = []
        ToolTimelineRowPresentationHelpers.anchoredRemeasureHookForTesting = { view, itemID in
            guard view === collectionView else { return }
            remeasuredIDs.append(itemID)
            followingDuringRemeasure = Self.installedFollowingIdentities(
                in: view,
                after: fixture.readIP.item,
                ids: fixture.wh.coordinator.currentIDs
            )
            if let ninth = followingDuringRemeasure.first(where: { $0.itemID == ninthBefore.itemID }),
               let attrs = view.layoutAttributesForItem(
                at: IndexPath(item: ninth.index, section: 0)
               )?.frame {
                ninthDuringRemeasure = InstalledFollowerGeometry(
                    identity: ninth,
                    cellFrame: ninth.cell.frame,
                    attributesFrame: attrs
                )
            }
        }
        defer { ToolTimelineRowPresentationHelpers.anchoredRemeasureHookForTesting = nil }

        let reconfiguredBefore = fixture.wh.coordinator.debugReconfiguredItemIDs
        let wideInvalidationsBefore =
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            )

        fixture.wh.coordinator.collectionView(collectionView, didSelectItemAt: fixture.readIP)
        collectionView.layoutIfNeeded()

        let settled = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            collectionView.layoutIfNeeded()
            let cellHeight = collectionView.cellForItem(at: fixture.readIP)?.frame.height ?? 0
            return remeasuredIDs.contains(fixture.readID)
                && abs(cellHeight - Self.expectedExpandedReadHeight) <= 1
        }
        #expect(settled, "Completed markdown never reached the 620pt outer size while the expand anchor was active")

        try Self.assertNeighborGeometry(
            in: collectionView,
            beforeIP: fixture.beforeIP,
            readIP: fixture.readIP,
            afterIP: fixture.afterIP,
            heading: Self.heading,
            phase: "after anchored remeasure with 12 following rows",
            requireExpandedReadBody: true,
            requireSettledCompletedViewport: true
        )

        let ninth = try #require(
            ninthDuringRemeasure,
            "Ninth following cell must still be installed during remeasure"
        )
        #expect(
            ninth.identity.cell === ninthBefore.cell,
            "Ninth following cell instance must survive expand settlement"
        )
        #expect(
            ninth.identity.content === ninthBefore.content,
            "Ninth following configured UIContentView must survive expand settlement"
        )
        #expect(
            abs(ninth.cellFrame.minY - ninth.attributesFrame.minY) <= 0.5
                && abs(ninth.cellFrame.height - ninth.attributesFrame.height) <= 0.5,
            "Ninth following cell stayed at the pre-growth frame. cell=\(ninth.cellFrame) attrs=\(ninth.attributesFrame)"
        )

        for row in followingDuringRemeasure {
            let attrs = try #require(
                collectionView.layoutAttributesForItem(at: IndexPath(item: row.index, section: 0))?.frame
            )
            #expect(
                abs(row.cell.frame.minY - attrs.minY) <= 0.5
                    && abs(row.cell.frame.height - attrs.height) <= 0.5,
                "Installed following cell \(row.itemID) drifted from attributes. cell=\(row.cell.frame) attrs=\(attrs)"
            )
        }

        let newReconfigured = Array(
            fixture.wh.coordinator.debugReconfiguredItemIDs.dropFirst(reconfiguredBefore.count)
        )
        #expect(newReconfigured.allSatisfy { $0 == fixture.readID }, "got \(newReconfigured)")
        #expect(remeasuredIDs == [fixture.readID], "got \(remeasuredIDs)")
        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            ) == wideInvalidationsBefore
        )

        await Task.yield()
        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()
        try Self.assertNeighborGeometry(
            in: collectionView,
            beforeIP: fixture.beforeIP,
            readIP: fixture.readIP,
            afterIP: fixture.afterIP,
            heading: Self.heading,
            phase: "after extra layout cycle with 12 following rows",
            requireExpandedReadBody: true,
            requireSettledCompletedViewport: true
        )
    }

    @Test func disappearedExpandAnchorIdentityDoesNotRemeasureStaleIndexPath() async throws {
        let fixture = try Self.makeSkillReadSkillFixture()
        defer { Self.tearDownSkillReadSkillFixture(fixture) }

        let collectionView = fixture.wh.collectionView
        let anchoredCV = try #require(collectionView as? AnchoredCollectionView)
        var remeasuredIDs: [String] = []
        ToolTimelineRowPresentationHelpers.anchoredRemeasureHookForTesting = { view, itemID in
            guard view === collectionView else { return }
            remeasuredIDs.append(itemID)
        }
        defer { ToolTimelineRowPresentationHelpers.anchoredRemeasureHookForTesting = nil }

        fixture.wh.coordinator.collectionView(collectionView, didSelectItemAt: fixture.readIP)
        collectionView.layoutIfNeeded()
        #expect(anchoredCV.expandCollapseAnchorItemID == fixture.readID)

        let staleIP = fixture.readIP
        let itemsWithoutRead = fixture.items.filter { $0.id != fixture.readID }
        fixture.wh.applyItems(itemsWithoutRead, isBusy: false)
        collectionView.layoutIfNeeded()

        #expect(
            anchoredCV.expandCollapseAnchorItemID == nil,
            "Missing stable expand ID must expire the anchor, not keep \(String(describing: anchoredCV.expandCollapseAnchorItemID))"
        )
        #expect(
            anchoredCV.expandCollapseAnchorIP == nil,
            "Missing stable expand ID must not keep stale IP \(String(describing: anchoredCV.expandCollapseAnchorIP))"
        )

        let reconfiguredBeforeForce = fixture.wh.coordinator.debugReconfiguredItemIDs
        let remainingCell = try #require(
            collectionView.visibleCells.first
                ?? collectionView.subviews.compactMap { $0 as? UICollectionViewCell }.first,
            "Need an installed cell to force a post-removal invalidation"
        )
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(
            startingAt: remainingCell.contentView
        )
        collectionView.layoutIfNeeded()

        #expect(
            !remeasuredIDs.contains(fixture.skillAfterID),
            "Disappeared Read identity retargeted the following skill; ids=\(remeasuredIDs)"
        )
        #expect(
            !remeasuredIDs.contains("tc-skill-agent-workflow"),
            "Disappeared Read identity retargeted the previous skill; ids=\(remeasuredIDs)"
        )
        let forcedReconfigured = Array(
            fixture.wh.coordinator.debugReconfiguredItemIDs.dropFirst(reconfiguredBeforeForce.count)
        )
        #expect(
            !forcedReconfigured.contains(fixture.skillAfterID),
            "Stale index path \(staleIP) reconfigured the following skill; got \(forcedReconfigured)"
        )
        #expect(anchoredCV.expandCollapseAnchorItemID == nil)
        #expect(anchoredCV.expandCollapseAnchorIP == nil)
    }

    @Test func synchronousLayoutInvalidationGuardDoesNotSuppressAnotherTimeline() {
        final class NestedInvalidationLayout: UICollectionViewFlowLayout {
            var invalidationCount = 0
            var nestedInvalidate: (() -> Void)?

            override func invalidateLayout() {
                invalidationCount += 1
                if let nested = nestedInvalidate {
                    nestedInvalidate = nil
                    nested()
                }
                super.invalidateLayout()
            }
        }

        let layoutA = NestedInvalidationLayout()
        layoutA.itemSize = CGSize(width: 390, height: 50)
        let collectionA = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 400),
            collectionViewLayout: layoutA
        )
        let sourceA = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        collectionA.addSubview(sourceA)

        let layoutB = NestedInvalidationLayout()
        layoutB.itemSize = CGSize(width: 390, height: 50)
        let collectionB = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 400),
            collectionViewLayout: layoutB
        )
        let sourceB = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        collectionB.addSubview(sourceB)

        layoutA.nestedInvalidate = {
            ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(
                startingAt: sourceB
            )
        }

        let baselineACount =
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionA
            )
        let baselineBCount =
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionB
            )
        let baselineB = layoutB.invalidationCount
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(
            startingAt: sourceA
        )
        #expect(
            layoutB.invalidationCount > baselineB,
            "A synchronous invalidation on one timeline must not drop another timeline's layout pass"
        )
        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionA
            ) == baselineACount + 1
        )
        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionB
            ) == baselineBCount + 1
        )
    }

    @Test func offscreenValidExpandAnchorClearsWhenRemeasureHasNoInstalledCell() async throws {
        let fixture = try Self.makeSkillReadSkillFixture(followingSkillCount: 40)
        defer { Self.tearDownSkillReadSkillFixture(fixture) }

        let collectionView = fixture.wh.collectionView
        let coordinator = fixture.wh.coordinator
        let anchoredCV = try #require(collectionView as? AnchoredCollectionView)
        let lastIndexPath = IndexPath(item: coordinator.currentIDs.count - 1, section: 0)
        collectionView.scrollToItem(at: lastIndexPath, at: .bottom, animated: false)
        let viewportHeight = max(collectionView.bounds.height, 844)
        let bottomOffset = max(0, collectionView.contentSize.height - viewportHeight)
        setTimelineUserScrollOffsetY(collectionView, bottomOffset)
        settleTimelineLayout(collectionView, passes: 2)

        #expect(coordinator.currentIDs.contains(fixture.readID))
        #expect(
            collectionView.cellForItem(at: fixture.readIP) == nil,
            "The valid Read identity must be offscreen for the missing-cell regression"
        )
        let sourceCell = try #require(
            collectionView.visibleCells.first,
            "Need an installed row to request enclosing invalidation"
        )

        coordinator.anchoredReconfigureToolRow(
            itemID: fixture.readID,
            anchorIndexPath: fixture.readIP,
            in: collectionView
        )
        #expect(anchoredCV.expandCollapseAnchorItemID == fixture.readID)

        let suppressedInvalidations =
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            )
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(
            startingAt: sourceCell.contentView
        )
        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            ) == suppressedInvalidations,
            "An active anchor must route through item-local remeasurement even when its cell is absent"
        )

        let cleanedUp = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            collectionView.layoutIfNeeded()
            return anchoredCV.expandCollapseAnchorItemID == nil
                && anchoredCV.expandCollapseAnchorIP == nil
        }
        #expect(cleanedUp, "Matching-generation cleanup must clear an unmeasurable anchor")
        #expect(anchoredCV.detachedAnchorIsActive, "Cleanup must hand off to detached anchoring")

        let wideInvalidationsBefore =
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            )
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(
            startingAt: sourceCell.contentView
        )
        collectionView.layoutIfNeeded()
        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            ) == wideInvalidationsBefore + 1,
            "Cleared anchor must not suppress a later enclosing invalidation"
        )
    }

    @Test func rapidExpandCollapseReexpandKeepsFinalAnchoredRemeasure() async throws {
        let fixture = try Self.makeSkillReadSkillFixture()
        defer { Self.tearDownSkillReadSkillFixture(fixture) }

        let collectionView = fixture.wh.collectionView
        let coordinator = fixture.wh.coordinator
        let wideInvalidationsBefore =
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            )

        var remeasuredIDs: [String] = []
        ToolTimelineRowPresentationHelpers.anchoredRemeasureHookForTesting = { view, itemID in
            guard view === collectionView else { return }
            remeasuredIDs.append(itemID)
        }
        defer {
            ToolTimelineRowPresentationHelpers.anchoredRemeasureHookForTesting = nil
        }

        coordinator.collectionView(collectionView, didSelectItemAt: fixture.readIP)
        let generationN = try #require(
            (collectionView as? AnchoredCollectionView)?.expandCollapseAnchorGeneration
        )
        coordinator.collectionView(collectionView, didSelectItemAt: fixture.readIP)
        coordinator.collectionView(collectionView, didSelectItemAt: fixture.readIP)
        let anchoredCV = try #require(collectionView as? AnchoredCollectionView)
        #expect(anchoredCV.expandCollapseAnchorGeneration != generationN)
        #expect(
            !anchoredCV.clearExpandCollapseAnchor(generation: generationN),
            "Stale generation N cleanup must not clear the final pin"
        )
        #expect(
            anchoredCV.expandCollapseAnchorItemID == fixture.readID,
            "Final generation must keep the Read pin after rapid re-expand"
        )
        #expect(fixture.wh.reducer.expandedItemIDs.contains(fixture.readID))
        collectionView.layoutIfNeeded()
        collectionView.layoutIfNeeded()

        let settled = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            collectionView.layoutIfNeeded()
            if collectionView.cellForItem(at: fixture.readIP) == nil {
                collectionView.scrollToItem(
                    at: fixture.readIP,
                    at: .centeredVertically,
                    animated: false
                )
                collectionView.layoutIfNeeded()
            }
            guard let toolRow = collectionView.cellForItem(at: fixture.readIP).flatMap({
                timelineFirstView(ofType: ToolTimelineRowContentView.self, in: $0.contentView)
            }) else {
                return false
            }
            let attrHeight = collectionView.layoutAttributesForItem(at: fixture.readIP)?.frame.height ?? 0
            let cellHeight = collectionView.cellForItem(at: fixture.readIP)?.frame.height ?? 0
            return abs(toolRow.expandedContainer.bounds.height
                - ToolTimelineRowContentView.maxExpandedViewportHeight) <= 1
                && abs(attrHeight - Self.expectedExpandedReadHeight) <= 1
                && abs(cellHeight - Self.expectedExpandedReadHeight) <= 1
                && remeasuredIDs.contains(fixture.readID)
        }
        if collectionView.cellForItem(at: fixture.readIP) == nil {
            collectionView.scrollToItem(
                at: fixture.readIP,
                at: .centeredVertically,
                animated: false
            )
            collectionView.layoutIfNeeded()
        }
        #expect(
            settled,
            "Final generation never reached the 620pt viewport. remeasures=\(remeasuredIDs) attrs=\(collectionView.layoutAttributesForItem(at: fixture.readIP)?.frame.height ?? -1)"
        )

        try Self.assertNeighborGeometry(
            in: collectionView,
            beforeIP: fixture.beforeIP,
            readIP: fixture.readIP,
            afterIP: fixture.afterIP,
            heading: Self.heading,
            phase: "after rapid expand/collapse/re-expand",
            requireExpandedReadBody: true,
            requireSettledCompletedViewport: true
        )
        #expect(remeasuredIDs == [fixture.readID], "got \(remeasuredIDs)")
        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            ) == wideInvalidationsBefore,
            "Final generation must not timeline-wide invalidateLayout()"
        )

        await Task.yield()
        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()
        await Task.yield()
        collectionView.layoutIfNeeded()
        #expect(
            remeasuredIDs == [fixture.readID],
            "Extra cycles must not add another remeasure; got \(remeasuredIDs)"
        )
        try Self.assertNeighborGeometry(
            in: collectionView,
            beforeIP: fixture.beforeIP,
            readIP: fixture.readIP,
            afterIP: fixture.afterIP,
            heading: Self.heading,
            phase: "after extra cycles following rapid re-expand",
            requireExpandedReadBody: true,
            requireSettledCompletedViewport: true
        )
        #expect(
            ToolTimelineRowPresentationHelpers.debugTimelineWideInvalidationCountForTesting(
                collectionView
            ) == wideInvalidationsBefore
        )
    }

    // MARK: - Assertions

    private static func assertCollapsedChromeOnly(
        in collectionView: UICollectionView,
        item: Int
    ) throws {
        let cell = try configuredTimelineCell(in: collectionView, item: item)
        #expect(
            cell.contentConfiguration is CollapsedToolTimelineRowConfiguration,
            "Item \(item) should stay chrome-only while collapsed"
        )
    }

    private static func assertNeighborGeometry(
        in collectionView: UICollectionView,
        beforeIP: IndexPath,
        readIP: IndexPath,
        afterIP: IndexPath,
        heading: String,
        phase: String,
        requireExpandedReadBody: Bool,
        requireSettledCompletedViewport: Bool = false
    ) throws {
        let snapshot = try geometrySnapshot(
            in: collectionView,
            beforeIP: beforeIP,
            readIP: readIP,
            afterIP: afterIP,
            heading: heading
        )
        let dump = snapshot.dump

        try assertPairwiseGap(snapshot.before, snapshot.read, phase: phase, dump: dump)
        try assertPairwiseGap(snapshot.read, snapshot.after, phase: phase, dump: dump)

        guard requireExpandedReadBody else { return }

        let headingRect = try #require(
            snapshot.headingInCollection,
            "Missing H1 '\(heading)' at \(phase). \(dump)"
        )
        let readFrame = try #require(snapshot.read.cellFrame, "Missing Read cell at \(phase). \(dump)")
        let beforeFrame = try #require(snapshot.before.cellFrame, "Missing previous skill cell at \(phase). \(dump)")
        let viewport = try #require(
            snapshot.expandedViewportInCollection,
            "Missing expanded viewport at \(phase). \(dump)"
        )
        let expandedContainerHeight = try #require(
            snapshot.expandedContainerHeight,
            "Missing expandedContainer bounds at \(phase). \(dump)"
        )
        let afterFrame = snapshot.after.cellFrame ?? snapshot.after.attributes

        #expect(
            headingRect.minY >= readFrame.minY - Self.gapTolerance
                && headingRect.maxY <= readFrame.maxY + Self.gapTolerance
                && headingRect.minX >= readFrame.minX - 8
                && headingRect.maxX <= readFrame.maxX + 8,
            "Unclipped H1 escaped the Read cell at \(phase). heading=\(headingRect) read=\(readFrame). \(dump)"
        )
        #expect(
            headingRect.minY >= beforeFrame.maxY - Self.gapTolerance,
            "H1 overlaps previous skill chrome at \(phase). heading.minY=\(headingRect.minY) previous.maxY=\(beforeFrame.maxY). \(dump)"
        )
        let headingInPrevious = headingRect.intersection(beforeFrame)
        #expect(
            headingInPrevious.width <= 0.5 || headingInPrevious.height <= 0.5,
            "H1 intersects previous skill chrome at \(phase). overlap=\(headingInPrevious). \(dump)"
        )
        #expect(
            viewport.maxY <= readFrame.maxY + 0.5,
            "Expanded viewport escaped the Read cell at \(phase). viewport=\(viewport) read=\(readFrame). \(dump)"
        )
        guard requireSettledCompletedViewport else { return }

        #expect(
            abs(snapshot.read.attributes.height - Self.expectedExpandedReadHeight) <= 1,
            "Outer Read attributes height was \(snapshot.read.attributes.height)pt instead of 651.67pt at \(phase). \(dump)"
        )
        #expect(
            abs(readFrame.height - Self.expectedExpandedReadHeight) <= 1,
            "Outer Read cell height was \(readFrame.height)pt instead of 651.67pt at \(phase). \(dump)"
        )
        #expect(
            abs(expandedContainerHeight - ToolTimelineRowContentView.maxExpandedViewportHeight) <= 1,
            "expandedContainer height \(expandedContainerHeight)pt != 620pt viewport at \(phase). \(dump)"
        )
        let headingInNext = headingRect.intersection(afterFrame.insetBy(dx: 0, dy: 0.5))
        #expect(
            headingInNext.width <= 0.5 || headingInNext.height <= 0.5,
            "H1 intersects next skill chrome at \(phase). overlap=\(headingInNext). \(dump)"
        )
    }

    private static func assertPairwiseGap(
        _ upper: RowFrame,
        _ lower: RowFrame,
        phase: String,
        dump: String
    ) throws {
        let attributeGap = lower.attributes.minY - upper.attributes.maxY
        #expect(
            abs(attributeGap - Self.productionGap) <= Self.gapTolerance,
            "Layout attributes gap \(attributeGap)pt != 8±0.5pt at \(phase) between item \(upper.indexPath.item) and \(lower.indexPath.item). \(dump)"
        )

        if let upperCell = upper.cellFrame, let lowerCell = lower.cellFrame {
            let cellGap = lowerCell.minY - upperCell.maxY
            #expect(
                abs(cellGap - Self.productionGap) <= Self.gapTolerance,
                "Cell frames gap \(cellGap)pt != 8±0.5pt at \(phase) between item \(upper.indexPath.item) and \(lower.indexPath.item). \(dump)"
            )
            #expect(
                abs(upperCell.minY - upper.attributes.minY) <= 0.5
                    && abs(upperCell.height - upper.attributes.height) <= 0.5,
                "Cell frame drifted from attributes for item \(upper.indexPath.item) at \(phase). cell=\(upperCell) attrs=\(upper.attributes). \(dump)"
            )
            #expect(
                abs(lowerCell.minY - lower.attributes.minY) <= 0.5
                    && abs(lowerCell.height - lower.attributes.height) <= 0.5,
                "Cell frame drifted from attributes for item \(lower.indexPath.item) at \(phase). cell=\(lowerCell) attrs=\(lower.attributes). \(dump)"
            )
        }
    }

    // MARK: - Geometry

    private struct RowFrame {
        let indexPath: IndexPath
        let attributes: CGRect
        let cellFrame: CGRect?
    }

    private struct GeometrySnapshot {
        let before: RowFrame
        let read: RowFrame
        let after: RowFrame
        let headingInCollection: CGRect?
        let expandedViewportInCollection: CGRect?
        let expandedContainerHeight: CGFloat?
        let dump: String
    }

    private struct RowContentIdentity {
        let cell: UICollectionViewCell
        let content: UIView
    }

    private struct InstalledFollowingIdentity {
        let itemID: String
        let index: Int
        let cell: UICollectionViewCell
        let content: UIView
    }

    private struct InstalledFollowerGeometry {
        let identity: InstalledFollowingIdentity
        let cellFrame: CGRect
        let attributesFrame: CGRect
    }

    private static func installedFollowingIdentities(
        in collectionView: UICollectionView,
        after itemIndex: Int,
        ids: [String]
    ) -> [InstalledFollowingIdentity] {
        collectionView.subviews.compactMap { view -> InstalledFollowingIdentity? in
            guard let cell = view as? UICollectionViewCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  indexPath.section == 0,
                  indexPath.item > itemIndex,
                  indexPath.item < ids.count,
                  let content = firstConfiguredContentView(in: cell.contentView) else {
                return nil
            }
            return InstalledFollowingIdentity(
                itemID: ids[indexPath.item],
                index: indexPath.item,
                cell: cell,
                content: content
            )
        }
        .sorted { $0.index < $1.index }
    }

    private static func geometrySnapshot(
        in collectionView: UICollectionView,
        beforeIP: IndexPath,
        readIP: IndexPath,
        afterIP: IndexPath,
        heading: String
    ) throws -> GeometrySnapshot {
        let before = try rowFrame(in: collectionView, at: beforeIP)
        let read = try rowFrame(in: collectionView, at: readIP)
        let after = try rowFrame(in: collectionView, at: afterIP)
        let readCell = collectionView.cellForItem(at: readIP)
        if let markdown = readCell.flatMap({
            timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: $0.contentView)
        }) {
            markdown.debugLayoutVisibleMarkdownCellsForTesting()
        }

        let expandedContainer = readCell.flatMap {
            timelineFirstView(ofType: ToolTimelineRowContentView.self, in: $0.contentView)?
                .expandedContainer
        }

        let headingInCollection = readCell.flatMap {
            headingRect(named: heading, in: $0, collectionView: collectionView)
        }
        let expandedViewportInCollection = expandedContainer.flatMap { container in
            container.isHidden ? nil : container.convert(container.bounds, to: collectionView)
        }
        let expandedContainerHeight = expandedContainer.flatMap { container in
            container.isHidden ? nil : container.bounds.height
        }

        let dump = [
            "before.attrs=\(before.attributes)",
            "before.cell=\(String(describing: before.cellFrame))",
            "read.attrs=\(read.attributes)",
            "read.cell=\(String(describing: read.cellFrame))",
            "after.attrs=\(after.attributes)",
            "after.cell=\(String(describing: after.cellFrame))",
            "heading=\(String(describing: headingInCollection))",
            "viewportFrame=\(String(describing: expandedViewportInCollection))",
            "expandedHeight=\(String(describing: expandedContainerHeight))",
            "anchorIP=\((collectionView as? AnchoredCollectionView)?.expandCollapseAnchorIP as Any)",
        ].joined(separator: " ")

        return GeometrySnapshot(
            before: before,
            read: read,
            after: after,
            headingInCollection: headingInCollection,
            expandedViewportInCollection: expandedViewportInCollection,
            expandedContainerHeight: expandedContainerHeight,
            dump: dump
        )
    }

    private static func rowFrame(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) throws -> RowFrame {
        let attributes = try #require(
            collectionView.layoutAttributesForItem(at: indexPath)?.frame,
            "Missing layout attributes at \(indexPath)"
        )
        return RowFrame(
            indexPath: indexPath,
            attributes: attributes,
            cellFrame: collectionView.cellForItem(at: indexPath)?.frame
        )
    }

    private static func headingRect(
        named heading: String,
        in cell: UICollectionViewCell,
        collectionView: UICollectionView
    ) -> CGRect? {
        let matches = timelineAllTextRenderViews(in: cell.contentView)
            .filter { timelineRenderedText(of: $0).contains(heading) }
        guard let view = matches.min(by: { $0.bounds.height < $1.bounds.height }) else {
            return nil
        }
        // Merged markdown text segments are taller than the 620pt viewport.
        // The H1 is the first line; use that unclipped origin instead of
        // clipping the whole document through SafeSizingCell.
        let raw = view.convert(view.bounds, to: collectionView)
        let lineHeight = min(max(raw.height, 1), 48)
        return CGRect(x: raw.minX, y: raw.minY, width: raw.width, height: lineHeight)
    }

    private static func rowContentIdentity(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> RowContentIdentity? {
        guard let cell = collectionView.cellForItem(at: indexPath),
              let content = firstConfiguredContentView(in: cell.contentView) else {
            return nil
        }
        return RowContentIdentity(cell: cell, content: content)
    }

    private static func firstConfiguredContentView(in root: UIView) -> UIView? {
        if root is UIContentView { return root }
        for subview in root.subviews {
            if let content = firstConfiguredContentView(in: subview) {
                return content
            }
        }
        return nil
    }

    // MARK: - Fixtures

    private struct SkillReadSkillFixture {
        let wh: WindowedTimelineHarness
        let items: [ChatItem]
        let readID: String
        let skillAfterID: String
        let beforeIP: IndexPath
        let readIP: IndexPath
        let afterIP: IndexPath
    }

    private static func isolateSharedPresentersForTesting() {
        FeatureEducationTipPresentationCoordinator.shared.resetForTesting()
        ToolTimelineRowContentView.forcesInlineFeatureTipsForTesting = false
        // Occupy the shared presenter so leftover TipKit `shouldDisplay`
        // cannot insert a `bodyStack` sibling. Do not invalidate TipKit;
        // that cancelled the 200→620 remeasure in full OppiTests.
        _ = FeatureEducationTipPresentationCoordinator.shared.claim(
            tipID: "read-markdown-expand-overlap.block",
            ownerID: UUID(),
            force: true
        )
    }

    private static func tearDownSkillReadSkillFixture(_ fixture: SkillReadSkillFixture) {
        fixture.wh.window.isHidden = true
        FeatureEducationTipPresentationCoordinator.shared.resetForTesting()
    }

    private static func makeSkillReadSkillFixture(
        followingSkillCount: Int = 1
    ) throws -> SkillReadSkillFixture {
        isolateSharedPresentersForTesting()
        let wh = makeWindowedTimelineHarness(
            sessionId: followingSkillCount > 1
                ? "s-read-md-overlap-many-follow"
                : "s-read-md-overlap",
            useAnchoredCollectionView: true
        )

        let skillBeforeID = "tc-skill-agent-workflow"
        let readID = "tc-read-work-item-delivery"
        let followingCount = max(1, followingSkillCount)
        let followingIDs = (0..<followingCount).map { index in
            index == 0 ? "tc-skill-testing" : "tc-skill-follow-\(index)"
        }
        let skillAfterID = followingIDs[0]
        let markdown = ToolExpandScrollMatrixCase.sampleMarkdownDocument(
            title: Self.heading,
            sections: 16
        )

        installSkillRead(
            id: skillBeforeID,
            skillName: "agent-workflow",
            toolArgsStore: wh.toolArgsStore,
            toolOutputStore: wh.toolOutputStore
        )
        installCompletedMarkdownRead(
            id: readID,
            markdown: markdown,
            toolArgsStore: wh.toolArgsStore,
            toolOutputStore: wh.toolOutputStore
        )
        for (index, followingID) in followingIDs.enumerated() {
            installSkillRead(
                id: followingID,
                skillName: index == 0 ? "testing" : "follow-\(index)",
                toolArgsStore: wh.toolArgsStore,
                toolOutputStore: wh.toolOutputStore
            )
        }

        var items: [ChatItem] = []
        for index in 0..<8 {
            items.append(.assistantMessage(
                id: "pre-\(index)",
                text: String(repeating: "Lead-in paragraph \(index). ", count: 10),
                timestamp: Date()
            ))
        }
        items.append(skillToolCall(id: skillBeforeID, skillName: "agent-workflow"))
        items.append(markdownToolCall(id: readID, markdown: markdown))
        for (index, followingID) in followingIDs.enumerated() {
            items.append(skillToolCall(
                id: followingID,
                skillName: index == 0 ? "testing" : "follow-\(index)"
            ))
        }
        if followingCount == 1 {
            for index in 0..<8 {
                items.append(.assistantMessage(
                    id: "post-\(index)",
                    text: String(repeating: "Trailing paragraph \(index). ", count: 12),
                    timestamp: Date()
                ))
            }
        }

        wh.applyItems(items, isBusy: false)
        settleTimelineLayout(wh.collectionView, passes: 2)

        let beforeIndex = try #require(items.firstIndex { $0.id == skillBeforeID })
        let readIndex = try #require(items.firstIndex { $0.id == readID })
        let afterIndex = try #require(items.firstIndex { $0.id == skillAfterID })
        let beforeIP = IndexPath(item: beforeIndex, section: 0)
        let readIP = IndexPath(item: readIndex, section: 0)
        let afterIP = IndexPath(item: afterIndex, section: 0)

        wh.scrollController.detachFromBottomForUserScroll()
        let beforeAttrs = try #require(wh.collectionView.layoutAttributesForItem(at: beforeIP))
        setTimelineUserScrollOffsetY(wh.collectionView, max(0, beforeAttrs.frame.minY - 24))
        settleTimelineLayout(wh.collectionView, passes: 2)
        let settledBeforeAttrs = try #require(
            wh.collectionView.layoutAttributesForItem(at: beforeIP)
        )
        setTimelineUserScrollOffsetY(
            wh.collectionView,
            max(0, settledBeforeAttrs.frame.minY - 24)
        )
        settleTimelineLayout(wh.collectionView, passes: 2)

        return SkillReadSkillFixture(
            wh: wh,
            items: items,
            readID: readID,
            skillAfterID: skillAfterID,
            beforeIP: beforeIP,
            readIP: readIP,
            afterIP: afterIP
        )
    }

    private static func installSkillRead(
        id: String,
        skillName: String,
        toolArgsStore: ToolArgsStore,
        toolOutputStore: ToolOutputStore
    ) {
        let path = "/Users/dev/.pi/agent/skills/\(skillName)/SKILL.md"
        let output = "---\nname: \(skillName)\n---"
        toolArgsStore.set([
            "path": .string(path),
            "offset": .number(1),
            "limit": .number(220),
        ], for: id)
        toolOutputStore.append(output, to: id)
    }

    private static func installCompletedMarkdownRead(
        id: String,
        markdown: String,
        toolArgsStore: ToolArgsStore,
        toolOutputStore: ToolOutputStore
    ) {
        let path = "Docs/Work-Item-Delivery.md"
        toolArgsStore.set([
            "path": .string(path),
            "offset": .number(1),
            "limit": .number(300),
        ], for: id)
        toolOutputStore.append(markdown, to: id)
    }

    private static func skillToolCall(id: String, skillName: String) -> ChatItem {
        let path = "/Users/dev/.pi/agent/skills/\(skillName)/SKILL.md"
        let output = "---\nname: \(skillName)\n---"
        return .toolCall(
            id: id,
            tool: "read",
            argsSummary: "path: \(path)",
            outputPreview: output,
            outputByteCount: output.utf8.count,
            isError: false,
            isDone: true
        )
    }

    private static func markdownToolCall(id: String, markdown: String) -> ChatItem {
        return .toolCall(
            id: id,
            tool: "read",
            argsSummary: "read Docs/Work-Item-Delivery.md",
            outputPreview: "# \(Self.heading)",
            outputByteCount: markdown.utf8.count,
            isError: false,
            isDone: true
        )
    }
}
