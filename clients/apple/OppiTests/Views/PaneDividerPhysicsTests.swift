import Testing
import UIKit
@testable import Oppi

/// The divider's pure width math: free resize inside the side-by-side range,
/// 1:1 tracking past it toward full, resistance below the minimum, a
/// threshold-crossing commit to full or closed, velocity carried into that
/// decision, and a clean return to the remembered width (never wherever the
/// pull-back happened to stop) once full is left.
@Suite("Pane divider math")
struct PaneDividerMathTests {
    private let policy = PaneWidthPolicy(minimum: 240, ideal: 320, maximum: 480, full: 1000)

    // MARK: Width policy

    @Test func theLeafBesideKeepsItsMinimumAndFullLeavesOnlyTheGrabEdge() {
        let beside = PaneWidthPolicy.screenMinimumWidth + PanePresentation.dividerThickness
        let wide = PaneWidthPolicy.resolved(minWidth: 320, idealWidth: 520, maxWidth: 820, window: 1032)
        #expect(wide.maximum == 1032 - beside, "the companion's own 820 would squeeze the leaf")
        #expect(wide.ideal == 520)
        #expect(wide.full == 1032 - PaneWidthPolicy.fullWindowGrabEdge)
        #expect(wide.fitsBeside)

        let roomy = PaneWidthPolicy.resolved(minWidth: 320, idealWidth: 400, maxWidth: 640, window: 1376)
        #expect(roomy.maximum == 640, "the companion's own ceiling when the window has room for both")
    }

    /// The iPad mini in portrait: the sidebar is a drawer over the panes, so
    /// the host has the whole 744 pt and a list companion fits beside the
    /// chat (375 + 1 + 368).
    @Test func theMiniInPortraitHoldsTheChatAndAListBesideIt() {
        let portrait = PaneWidthPolicy.resolved(minWidth: 320, idealWidth: 400, maxWidth: 640, window: 744)
        #expect(portrait.fitsBeside)
        #expect(portrait.maximum == 368)
        #expect(portrait.ideal == 368)
    }

    /// A window too narrow for both minimums: the companion has no ordinary
    /// range and opens over the leaf instead of a sliver beside it.
    @Test func aCompanionThatDoesNotFitBesideStaysFull() {
        let narrow = PaneWidthPolicy.resolved(minWidth: 320, idealWidth: 400, maxWidth: 640, window: 680)
        #expect(!narrow.fitsBeside)
        let outcome = PaneSnapResolver.resolve(
            rawWidth: 300, widthVelocity: 0, policy: narrow, rememberedWidth: 300, wasFull: true
        )
        #expect(outcome == .full)
        let closing = PaneSnapResolver.resolve(
            rawWidth: 0, widthVelocity: 0, policy: narrow, rememberedWidth: 300, wasFull: true
        )
        #expect(closing == .closed, "it still closes")
    }

    // MARK: Following the finger

    @Test func resistanceStaysBoundedByItsDimensionHoweverFarTheOvershoot() {
        let dimension: CGFloat = 100
        let near = PaneRubberBand.resisted(20, dimension: dimension)
        let far = PaneRubberBand.resisted(10_000, dimension: dimension)
        #expect(near > 0 && near < dimension)
        #expect(far > near, "more overshoot still pulls a little further")
        #expect(far < dimension, "resistance never reaches a full dimension of extra travel")
    }

    @Test func liveWidthTracksTheFingerFromMinimumAllTheWayToFull() {
        for raw: CGFloat in [240, 300, 480, 700, 1000] {
            #expect(PaneRubberBand.liveWidth(forRawTarget: raw, policy: policy) == raw)
        }
        #expect(PaneRubberBand.liveWidth(forRawTarget: 1400, policy: policy) == policy.full)
    }

    @Test func liveWidthResistsBelowMinimumAndMeetsTheCloseThresholdWithTheFinger() {
        let belowMinimum = PaneRubberBand.liveWidth(forRawTarget: 100, policy: policy)
        #expect(belowMinimum > 100, "a raw target under minimum is pulled back toward it")
        #expect(belowMinimum < policy.minimum, "but still short of minimum while the drag continues")
        let atThreshold = PaneRubberBand.liveWidth(forRawTarget: policy.closeThreshold, policy: policy)
        #expect(abs(atThreshold - policy.closeThreshold) < 0.001)
    }

    @Test func aGrabMidMotionPicksTheDividerUpWhereItIsDrawn() {
        // An open still settling draws widths below minimum; the raw target
        // recovered from them must draw the same width, or the companion jumps.
        for drawn: CGFloat in [10, 90, 200, 239, 240, 600, 1000] {
            let raw = PaneRubberBand.rawTarget(forLiveWidth: drawn, policy: policy)
            #expect(abs(PaneRubberBand.liveWidth(forRawTarget: raw, policy: policy) - drawn) < 0.01, "drawn \(drawn)")
        }
    }

    // MARK: Snap zones

    @Test func zoneNamesTheCommitRegionsAroundTheOrdinaryRange() {
        #expect(PaneSnapResolver.zone(for: 0, policy: policy) == .closing)
        #expect(PaneSnapResolver.zone(for: policy.closeThreshold, policy: policy) == .closing)
        #expect(PaneSnapResolver.zone(for: policy.closeThreshold + 1, policy: policy) == .ordinary)
        #expect(PaneSnapResolver.zone(for: 350, policy: policy) == .ordinary)
        #expect(PaneSnapResolver.zone(for: policy.expandThreshold, policy: policy) == .expanding)
        #expect(PaneSnapResolver.zone(for: policy.full, policy: policy) == .expanding)
    }

    // MARK: Resolving a drag's end

    @Test func aMidRangeReleaseWithNoVelocitySettlesWhereItStopped() {
        let outcome = PaneSnapResolver.resolve(
            rawWidth: 360, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .width(360))
    }

    @Test func releasingPastTheMaximumShortOfTheThresholdSettlesAtTheMaximum() {
        let outcome = PaneSnapResolver.resolve(
            rawWidth: policy.expandThreshold - 1, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .width(policy.maximum))
    }

    @Test func releasingBelowTheCloseThresholdCloses() {
        let outcome = PaneSnapResolver.resolve(
            rawWidth: policy.closeThreshold - 1, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .closed)
    }

    @Test func releasingPastTheExpandThresholdCommitsToFull() {
        let outcome = PaneSnapResolver.resolve(
            rawWidth: policy.expandThreshold + 1, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .full)
    }

    @Test func aFastFlingCommitsEvenFromInsideTheOrdinaryRange() {
        // Still well inside the ordinary range, but moving fast enough toward
        // full that the projected stopping point crosses the threshold.
        let rawWidth: CGFloat = 440
        #expect(PaneSnapResolver.zone(for: rawWidth, policy: policy) == .ordinary)
        let outcome = PaneSnapResolver.resolve(
            rawWidth: rawWidth, widthVelocity: 3000, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .full, "a fast flick settles like a slower drag further in the same direction would have")
    }

    @Test func aFastFlingClosesEvenFromInsideTheOrdinaryRange() {
        let rawWidth: CGFloat = 260
        #expect(PaneSnapResolver.zone(for: rawWidth, policy: policy) == .ordinary)
        let outcome = PaneSnapResolver.resolve(
            rawWidth: rawWidth, widthVelocity: -3000, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .closed)
    }

    @Test func leavingFullReturnsToTheRememberedWidthNotWhereThePullBackStopped() {
        // Dragged back from full into ordinary territory at an arbitrary
        // point (410): the companion still returns to what was remembered
        // (300), not to 410.
        let outcome = PaneSnapResolver.resolve(
            rawWidth: 410, widthVelocity: 0, policy: policy, rememberedWidth: 300, wasFull: true
        )
        #expect(outcome == .width(300))
    }

    @Test func leavingFullAllTheWayToTheCloseEdgeStillCloses() {
        let outcome = PaneSnapResolver.resolve(
            rawWidth: policy.closeThreshold - 1, widthVelocity: 0, policy: policy, rememberedWidth: 300, wasFull: true
        )
        #expect(outcome == .closed)
    }

    @Test func stayingNearFullSpringsBackToFull() {
        let outcome = PaneSnapResolver.resolve(
            rawWidth: policy.full - 1, widthVelocity: 0, policy: policy, rememberedWidth: 300, wasFull: true
        )
        #expect(outcome == .full)
    }
}

/// The divider end to end in a real window: dragging clamps to the
/// companion's own range, the leaf beside never narrows past its minimum and
/// stops reflowing once the companion slides over it, past the threshold the
/// companion takes the window but its grab edge, and a settled width is
/// remembered proportionally for the next companion, anywhere in the app,
/// that opens with nothing of its own yet remembered.
@MainActor
@Suite("Pane divider physics", .serialized)
struct PaneDividerPhysicsTests {
    @Test func dragClampsToTheCompanionsOwnMinimumAndMaximum() throws {
        let host = PaneTestHost(width: 1000)
        defer { host.hide() }
        host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
        let panes = host.panes
        #expect(panes.companionWidthForTesting == 300, "opens at its own ideal width with nothing remembered")

        host.drag(by: -50) // dragging toward the leaf widens the companion
        #expect(panes.companionWidthForTesting == 350)
        #expect(host.scenePanes.companionFraction == 0.35)

        // Past the maximum, short of the expand threshold: the companion
        // follows the finger over the leaf, then settles back at the
        // maximum rather than opening further.
        let divider = panes.dividerForTesting
        divider.onBegan?()
        divider.onChanged?(-170)
        #expect(panes.companionWidthForTesting == 520)
        divider.onEnded?(-170, 0)
        host.settle()
        #expect(panes.companionWidthForTesting == 500)

        // Below the minimum, short of the close threshold: resists, then
        // settles back at the minimum rather than closing.
        divider.onBegan?()
        divider.onChanged?(350)
        let resisted = try #require(panes.companionWidthForTesting)
        #expect(resisted < 200)
        #expect(resisted > 100)
        divider.onEnded?(350, 0)
        host.settle()
        #expect(panes.companionWidthForTesting == 200)
    }

    @Test func theLeafBesideKeepsItsMinimumAndIsCoveredRatherThanSqueezedAtFull() throws {
        let host = PaneTestHost(width: 1000)
        defer { host.hide() }
        host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 900)
        let panes = host.panes
        let divider = panes.dividerForTesting
        let beside = PaneWidthPolicy.screenMinimumWidth + PanePresentation.dividerThickness
        let full = 1000 - PaneWidthPolicy.fullWindowGrabEdge

        // The companion's own 900 would leave the leaf 100 points; the
        // side-by-side range stops where the leaf keeps its minimum.
        divider.onBegan?()
        divider.onChanged?(-(1000 - beside - 300))
        host.window.layoutIfNeeded()
        #expect(panes.companionWidthForTesting == 1000 - beside)
        #expect(host.screenWidth == beside)
        #expect(panes.coverForTesting.alpha == 0)
        let layoutsAtMaximum = host.screen.layoutCount

        // On toward full, short of the threshold: the companion slides
        // over the leaf, which neither narrows nor lays out again, and
        // fades under it.
        divider.onChanged?(-(1000 - beside - 300) - 100)
        host.window.layoutIfNeeded()
        #expect(panes.companionWidthForTesting == 1000 - beside + 100)
        #expect(host.screenWidth == beside)
        #expect(host.screen.layoutCount == layoutsAtMaximum)
        #expect(panes.coverForTesting.alpha > 0 && panes.coverForTesting.alpha < 1)

        // Past the threshold: full is the window but its grab edge, the
        // leaf covered there, and VoiceOver kept in the companion.
        divider.onChanged?(-800)
        divider.onEnded?(-800, 0)
        host.settle()
        host.window.layoutIfNeeded()
        #expect(panes.isFullForTesting)
        #expect(panes.companionWidthForTesting == full)
        #expect(host.screenWidth == beside)
        #expect(host.screen.layoutCount == layoutsAtMaximum)
        #expect(panes.coverForTesting.alpha == 1)
        #expect(panes.coverForTesting.frame.maxX <= PaneWidthPolicy.fullWindowGrabEdge)
        #expect(panes.primary.view.accessibilityElementsHidden)
        #expect(divider.frame.minX == 0, "the whole grab edge drags the companion back")
    }

    @Test func pastTheExpandThresholdTakesTheFullWindowAndBackReturnsToTheRememberedWidth() throws {
        let host = PaneTestHost(width: 1000)
        defer { host.hide() }
        host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
        let panes = host.panes

        // Settle an ordinary width to remember first.
        host.drag(by: -200)
        #expect(panes.companionWidthForTesting == 500)
        #expect(panes.isFullForTesting == false)

        // Past the expand threshold: commits to full, the leaf covered.
        host.drag(by: -400)
        #expect(panes.isFullForTesting == true)
        #expect(panes.companionWidthForTesting == 1000 - PaneWidthPolicy.fullWindowGrabEdge)

        // A grab at full picks the companion up where it is, with no jump.
        let divider = panes.dividerForTesting
        divider.onBegan?()
        divider.onChanged?(0)
        #expect(panes.companionWidthForTesting == 1000 - PaneWidthPolicy.fullWindowGrabEdge)

        // Dragging back out of full and releasing mid-range returns to
        // the remembered width (500), not wherever the drag stopped.
        divider.onChanged?(600)
        divider.onEnded?(600, 0)
        host.settle()
        #expect(panes.isFullForTesting == false)
        #expect(panes.companionWidthForTesting == 500)
    }

    @Test func aGrabWhileOpeningPicksTheCompanionUpWhereItIsDrawn() throws {
        let host = PaneTestHost(width: 1000)
        defer { host.hide() }
        host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500, settles: false)
        let panes = host.panes
        let divider = panes.dividerForTesting
        // Let the open draw part of the way.
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        divider.onBegan?()
        let drawn = try #require(panes.companionWidthForTesting)
        let companion = try #require(panes.companionForTesting)
        #expect(drawn < 300, "the open was still under way")
        #expect(abs(drawn - companion.view.frame.width) < 0.5, "the width is read back from the drawn companion, not the open's target")
        divider.onChanged?(0)
        let picked = try #require(panes.companionWidthForTesting)
        #expect(abs(picked - drawn) < 0.5)
    }

    /// A1: one adjustable element whose actions match the gestures.
    @Test func theDividerIsOneAdjustableElementWhoseActionsMatchTheGestures() throws {
        let host = PaneTestHost(width: 1000)
        defer { host.hide() }
        host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
        let panes = host.panes
        let divider = panes.dividerForTesting
        #expect(divider.isAccessibilityElement)
        #expect(divider.accessibilityTraits.contains(.adjustable))
        #expect(divider.accessibilityIdentifier == "pane.divider.0")
        #expect(divider.accessibilityValue == String(localized: "300 points"))

        divider.accessibilityIncrement()
        host.settle()
        #expect(panes.companionWidthForTesting == 300 + PaneDividerView.accessibilityStep)
        #expect(divider.accessibilityValue == String(localized: "\(Int(300 + PaneDividerView.accessibilityStep)) points"))

        for _ in 0..<20 {
            divider.accessibilityDecrement()
            host.settle()
        }
        #expect(panes.companionWidthForTesting == 200, "never steps below the companion's own minimum")

        divider.onExpandRequested?()
        host.settle()
        #expect(panes.isFullForTesting == true)
        #expect(divider.accessibilityValue == String(localized: "Full window"))
        divider.onRestoreRequested?()
        host.settle()
        #expect(panes.isFullForTesting == false)
        #expect(panes.companionWidthForTesting == 200)
    }

    @Test func draggingPastTheCloseThresholdDismissesLikeItsOwnDoneControl() throws {
        let host = PaneTestHost(width: 1000)
        defer { host.hide() }
        host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
        var dismissed = false
        host.screen.leaf.onDismissRequested = { dismissed = true }

        host.drag(by: 250) // raw = 300 - 250 = 50, under the close threshold (100)
        #expect(dismissed)
    }

    @Test func aGrabWhileClosingCannotStrandTheCompanionHalfRemoved() throws {
        let host = PaneTestHost(width: 1000)
        defer { host.hide() }
        host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
        let panes = host.panes
        let divider = panes.dividerForTesting
        host.screen.hidePanel()
        divider.onBegan?()
        divider.onChanged?(-100)
        divider.onEnded?(-100, 0)
        host.settle()
        #expect(panes.companionForTesting == nil, "the close ran to its end and took the companion off")
        #expect(host.screenWidth == 1000)
    }

    /// A push over the owner while its companion slides out lands the close,
    /// so the owner is not left waiting for it: a later panel opens, and its
    /// divider takes drags.
    @Test func aPushOverTheOwnerMidCloseLandsTheClose() throws {
        let host = PaneTestHost(width: 1000, inNavigation: true)
        defer { host.hide() }
        host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
        var closedRan = false
        host.screen.hidePanel()
        host.screen.leaf.whenClosed { closedRan = true }
        let stack = try #require(host.panes.primary as? UINavigationController)
        stack.pushViewController(UIViewController(), animated: false)
        host.window.layoutIfNeeded()
        #expect(closedRan, "the close completed instead of stopping in place")
        #expect(host.panes.companionForTesting == nil)

        stack.popViewController(animated: false)
        host.window.layoutIfNeeded()
        host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
        #expect(host.screen.leaf.mountedScreenForTesting != nil, "a panel opens again")
        #expect(host.panes.dividerForTesting.isUserInteractionEnabled)
        host.drag(by: -50)
        #expect(host.panes.companionWidthForTesting == 350)
    }

    /// The window's `ScenePanes` keeps the share for every host it mounts
    /// (a stack/split swap builds a new one) and for the saved tree.
    @Test func aSettledWidthIsRememberedProportionallyByTheNextCompanion() throws {
        let firstHost = PaneTestHost(width: 1000)
        firstHost.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 900)
        firstHost.drag(by: -100) // settles at 400 of 1000: a 0.4 fraction
        #expect(firstHost.panes.companionWidthForTesting == 400)
        firstHost.hide()

        // A second, unrelated companion, in a differently sized window,
        // opens at the same fraction of its own width rather than the
        // first one's absolute points.
        let secondHost = PaneTestHost(width: 800, scenePanes: firstHost.scenePanes)
        defer { secondHost.hide() }
        secondHost.showPanel(minWidth: 200, idealWidth: 260, maxWidth: 700)
        #expect(secondHost.panes.companionWidthForTesting == 320, "0.4 of the second window's 800pt width")
    }
}
