import Testing
import UIKit
@testable import Oppi

/// The trailing column's pure snap-point and rubber-band math: free resize
/// inside the ordinary range, a threshold-crossing commit to full or closed
/// beyond it, velocity carried into that decision, and a clean return to the
/// remembered width (never wherever the pull-back happened to stop) once
/// full is left.
@Suite("Trailing column resize math")
struct TrailingColumnResizeTests {
    private let policy = TrailingColumnWidthPolicy(minimum: 240, ideal: 320, maximum: 480, full: 1000)

    // MARK: Rubber band

    @Test func noOvershootIsUnresisted() {
        #expect(ColumnRubberBand.resisted(0, dimension: 100) == 0)
        #expect(ColumnRubberBand.resisted(-5, dimension: 100) == 0)
    }

    @Test func resistanceStaysBoundedByItsDimensionHoweverFarTheOvershoot() {
        let dimension: CGFloat = 100
        let near = ColumnRubberBand.resisted(20, dimension: dimension)
        let far = ColumnRubberBand.resisted(10_000, dimension: dimension)
        #expect(near > 0 && near < dimension)
        #expect(far > near, "more overshoot still pulls a little further")
        #expect(far < dimension, "resistance never reaches a full dimension of extra travel")
    }

    @Test func liveWidthIsFreeInsideTheOrdinaryRange() {
        for raw: CGFloat in [240, 300, 400, 480] {
            #expect(ColumnRubberBand.liveWidth(forRawTarget: raw, policy: policy) == raw)
        }
    }

    @Test func liveWidthResistsBeyondMinimumAndMaximum() {
        let belowMinimum = ColumnRubberBand.liveWidth(forRawTarget: 100, policy: policy)
        #expect(belowMinimum > 100, "a raw target under minimum is pulled back toward it")
        #expect(belowMinimum < policy.minimum, "but still short of minimum while the drag continues")

        let aboveMaximum = ColumnRubberBand.liveWidth(forRawTarget: 900, policy: policy)
        #expect(aboveMaximum < 900, "a raw target near full is pulled back toward maximum")
        #expect(aboveMaximum > policy.maximum)

        let atFull = ColumnRubberBand.liveWidth(forRawTarget: policy.full, policy: policy)
        #expect(atFull < policy.full, "resistance keeps even the window's own edge short of full")
    }

    // MARK: Snap zones

    @Test func zoneNamesTheCommitRegionsAroundTheOrdinaryRange() {
        #expect(ColumnSnapResolver.zone(for: 0, policy: policy) == .closing)
        #expect(ColumnSnapResolver.zone(for: policy.closeThreshold, policy: policy) == .closing)
        #expect(ColumnSnapResolver.zone(for: policy.closeThreshold + 1, policy: policy) == .ordinary)
        #expect(ColumnSnapResolver.zone(for: 350, policy: policy) == .ordinary)
        #expect(ColumnSnapResolver.zone(for: policy.expandThreshold, policy: policy) == .expanding)
        #expect(ColumnSnapResolver.zone(for: policy.full, policy: policy) == .expanding)
    }

    // MARK: Resolving a drag's end

    @Test func aMidRangeReleaseWithNoVelocitySettlesWhereItStopped() {
        let outcome = ColumnSnapResolver.resolve(
            liveWidth: 360, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .width(360))
    }

    @Test func releasingBelowTheCloseThresholdCloses() {
        let outcome = ColumnSnapResolver.resolve(
            liveWidth: policy.closeThreshold - 1, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .closed)
    }

    @Test func releasingPastTheExpandThresholdCommitsToFull() {
        let outcome = ColumnSnapResolver.resolve(
            liveWidth: policy.expandThreshold + 1, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .full)
    }

    @Test func aFastFlingCommitsEvenFromInsideTheOrdinaryRange() {
        // Still well inside the ordinary range, but moving fast enough toward
        // full that the projected stopping point crosses the threshold.
        let liveWidth: CGFloat = 440
        #expect(ColumnSnapResolver.zone(for: liveWidth, policy: policy) == .ordinary)
        let outcome = ColumnSnapResolver.resolve(
            liveWidth: liveWidth, widthVelocity: 3000, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .full, "a fast flick settles like a slower drag further in the same direction would have")
    }

    @Test func aFastFlingClosesEvenFromInsideTheOrdinaryRange() {
        let liveWidth: CGFloat = 260
        #expect(ColumnSnapResolver.zone(for: liveWidth, policy: policy) == .ordinary)
        let outcome = ColumnSnapResolver.resolve(
            liveWidth: liveWidth, widthVelocity: -3000, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .closed)
    }

    @Test func leavingFullReturnsToTheRememberedWidthNotWhereThePullBackStopped() {
        // Dragged back from full into ordinary territory at an arbitrary
        // point (410): the pane still returns to what was remembered (300),
        // not to 410.
        let outcome = ColumnSnapResolver.resolve(
            liveWidth: 410, widthVelocity: 0, policy: policy, rememberedWidth: 300, wasFull: true
        )
        #expect(outcome == .width(300))
    }

    @Test func leavingFullAllTheWayToTheCloseEdgeStillCloses() {
        let outcome = ColumnSnapResolver.resolve(
            liveWidth: policy.closeThreshold - 1, widthVelocity: 0, policy: policy, rememberedWidth: 300, wasFull: true
        )
        #expect(outcome == .closed)
    }

    @Test func stayingNearFullSpringsBackToFull() {
        let outcome = ColumnSnapResolver.resolve(
            liveWidth: policy.full - 1, widthVelocity: 0, policy: policy, rememberedWidth: 300, wasFull: true
        )
        #expect(outcome == .full)
    }

    @Test func clampedToOrdinaryRangeStaysWithinMinimumAndMaximum() {
        #expect(policy.clampedToOrdinaryRange(0) == policy.minimum)
        #expect(policy.clampedToOrdinaryRange(10_000) == policy.maximum)
        #expect(policy.clampedToOrdinaryRange(360) == 360)
    }
}

/// `TrailingColumnController` end to end in a real window: dragging the
/// divider clamps to the panel's own range, past it commits to full or
/// closed, and a settled width is remembered proportionally for the next
/// column, anywhere in the app, that opens with nothing of its own yet
/// remembered.
@MainActor
@Suite("Trailing column controller", .serialized)
struct TrailingColumnControllerTests {
    private func withCleanWidthPreference(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let key = AppPreferences.TrailingColumn.widthFractionKey
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        try body()
    }

    @Test func dragClampsToThePanelsOwnMinimumAndMaximum() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.screen.showPanel(root: makeTestAppRoot(), minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column
            #expect(controller.widthForTesting == 300, "opens at its own ideal width with nothing remembered")

            let handle = try #require(controller.resizeHandleForTesting)
            handle.onBegan?()
            handle.onChanged?(-50) // dragging toward the chat widens the column
            #expect(controller.widthForTesting == 350)
            handle.onEnded?(-50, 0)
            #expect(controller.widthForTesting == 350)
            #expect(AppPreferences.TrailingColumn.widthFraction == 0.35)

            // Past the soft maximum, but short of the expand threshold:
            // rubber-bands while dragging (resisted, not clamped hard to
            // the maximum, and not reaching the raw target either), then
            // settles back at the maximum rather than opening further.
            handle.onBegan?()
            handle.onChanged?(-170)
            #expect(controller.widthForTesting! > 500)
            #expect(controller.widthForTesting! < 620)
            handle.onEnded?(-170, 0)
            #expect(controller.widthForTesting == 500)

            // Below the minimum, short of the close threshold: rubber-bands,
            // then settles back at the minimum rather than closing.
            handle.onBegan?()
            handle.onChanged?(350)
            #expect(controller.widthForTesting! < 200)
            #expect(controller.widthForTesting! > 100)
            handle.onEnded?(350, 0)
            #expect(controller.widthForTesting == 200)
        }
    }

    @Test func pastTheExpandThresholdTakesTheFullWindowAndBackReturnsToTheRememberedWidth() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.screen.showPanel(root: makeTestAppRoot(), minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column

            // Settle an ordinary width to remember first.
            let handle = try #require(controller.resizeHandleForTesting)
            handle.onBegan?()
            handle.onChanged?(-200)
            handle.onEnded?(-200, 0)
            #expect(controller.widthForTesting == 500)
            #expect(controller.isFullForTesting == false)

            // Past the expand threshold: commits to full, the chat collapsed.
            handle.onBegan?()
            handle.onChanged?(-400)
            handle.onEnded?(-400, 0)
            #expect(controller.isFullForTesting == true)
            #expect(controller.widthForTesting == 1000)

            // Dragging back out of full and releasing mid-range returns to
            // the remembered width (500), not wherever the drag stopped.
            handle.onBegan?()
            handle.onChanged?(600)
            handle.onEnded?(600, 0)
            #expect(controller.isFullForTesting == false)
            #expect(controller.widthForTesting == 500)
        }
    }

    @Test func expandAndRestoreAccessibilityActionsMatchTheGesturesOutcome() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.screen.showPanel(root: makeTestAppRoot(), minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column
            let handle = try #require(controller.resizeHandleForTesting)

            handle.onExpandRequested?()
            #expect(controller.isFullForTesting == true)
            #expect(controller.widthForTesting == 1000)

            handle.onRestoreRequested?()
            #expect(controller.isFullForTesting == false)
            #expect(controller.widthForTesting == 300)
        }
    }

    @Test func accessibilityIncrementAndDecrementStepByAFixedAmountClampedToRange() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.screen.showPanel(root: makeTestAppRoot(), minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column
            let handle = try #require(controller.resizeHandleForTesting)

            handle.accessibilityIncrement()
            #expect(controller.widthForTesting == 300 + TrailingColumnResizeHandle.accessibilityStep)

            for _ in 0..<20 { handle.accessibilityDecrement() }
            #expect(controller.widthForTesting == 200, "never steps below the panel's own minimum")
        }
    }

    @Test func draggingPastTheCloseThresholdDismissesLikeItsOwnDoneControl() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.screen.showPanel(root: makeTestAppRoot(), minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column
            var dismissed = false
            controller.onDismissRequested = { dismissed = true }
            let handle = try #require(controller.resizeHandleForTesting)

            handle.onBegan?()
            handle.onChanged?(250) // raw = 300 - 250 = 50, under the close threshold (100)
            handle.onEnded?(250, 0)
            #expect(dismissed)
        }
    }

    @Test func aSettledWidthIsRememberedProportionallyByTheNextColumn() throws {
        try withCleanWidthPreference {
            let firstHost = makeHost(width: 1000)
            firstHost.screen.showPanel(root: makeTestAppRoot(), minWidth: 200, idealWidth: 300, maxWidth: 900)
            let firstHandle = try #require(firstHost.screen.column.resizeHandleForTesting)
            firstHandle.onBegan?()
            firstHandle.onChanged?(-100) // settles at 400 of 1000: a 0.4 fraction
            firstHandle.onEnded?(-100, 0)
            #expect(firstHost.screen.column.widthForTesting == 400)
            firstHost.hide()

            // A second, unrelated column, in a differently sized window,
            // opens at the same fraction of its own width rather than the
            // first column's absolute points.
            let secondHost = makeHost(width: 800)
            defer { secondHost.hide() }
            secondHost.screen.showPanel(root: makeTestAppRoot(), minWidth: 200, idealWidth: 260, maxWidth: 700)
            #expect(secondHost.screen.column.widthForTesting == 320, "0.4 of the second window's 800pt width")
        }
    }

    // MARK: - Fixture

    private struct Host {
        let screen: ResizeHostScreen
        let window: UIWindow

        func hide() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func makeHost(width: CGFloat) -> Host {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { fatalError("Missing UIWindowScene for TrailingColumnControllerTests") }
        let screen = ResizeHostScreen()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        window.rootViewController = screen
        window.makeKeyAndVisible()
        screen.view.layoutIfNeeded()
        return Host(screen: screen, window: window)
    }
}

/// A bare screen with a trailing column, the way the chat and the review
/// screens mount one.
@MainActor
private final class ResizeHostScreen: UIViewController {
    lazy var column = TrailingColumnController(screen: self)

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(column)
        column.view.frame = .zero
        view.addSubview(column.view)
        column.didMove(toParent: self)
    }

    func showPanel(root: AppRootEnvironment, minWidth: CGFloat, idealWidth: CGFloat, maxWidth: CGFloat) {
        column.show(
            TrailingColumnController.Panel(
                id: "panel", minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
                makeScreen: { UIViewController() }
            ),
            root: root
        )
    }
}
