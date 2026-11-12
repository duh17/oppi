import Testing
import UIKit
@testable import Oppi

/// The trailing column's pure width math: free resize inside the side-by-side
/// range, 1:1 tracking past it toward full, resistance below the minimum, a
/// threshold-crossing commit to full or closed, velocity carried into that
/// decision, and a clean return to the remembered width (never wherever the
/// pull-back happened to stop) once full is left.
@Suite("Trailing column resize math")
struct TrailingColumnResizeTests {
    private let policy = TrailingColumnWidthPolicy(minimum: 240, ideal: 320, maximum: 480, full: 1000)

    // MARK: Width policy

    @Test func theScreenBesideKeepsItsMinimumAndFullLeavesOnlyTheGrabEdge() {
        let wide = TrailingColumnWidthPolicy.resolved(minWidth: 320, idealWidth: 520, maxWidth: 820, window: 1032)
        #expect(wide.maximum == 1032 - TrailingColumnWidthPolicy.screenMinimumWidth, "the panel's own 820 would squeeze the screen")
        #expect(wide.ideal == 520)
        #expect(wide.full == 1032 - TrailingColumnOverlayView.fullWindowGrabEdge)

        let roomy = TrailingColumnWidthPolicy.resolved(minWidth: 320, idealWidth: 400, maxWidth: 640, window: 1376)
        #expect(roomy.maximum == 640, "the panel's own ceiling when the window has room for both")

        // A narrow regular-width window: the panel gives way before the screen does.
        let narrow = TrailingColumnWidthPolicy.resolved(minWidth: 320, idealWidth: 400, maxWidth: 640, window: 680)
        #expect(narrow.maximum == 680 - TrailingColumnWidthPolicy.screenMinimumWidth)
        #expect(narrow.minimum == narrow.maximum)
        #expect(narrow.ideal == narrow.maximum)
    }

    // MARK: Following the finger

    @Test func resistanceStaysBoundedByItsDimensionHoweverFarTheOvershoot() {
        let dimension: CGFloat = 100
        let near = ColumnRubberBand.resisted(20, dimension: dimension)
        let far = ColumnRubberBand.resisted(10_000, dimension: dimension)
        #expect(near > 0 && near < dimension)
        #expect(far > near, "more overshoot still pulls a little further")
        #expect(far < dimension, "resistance never reaches a full dimension of extra travel")
    }

    @Test func liveWidthTracksTheFingerFromMinimumAllTheWayToFull() {
        for raw: CGFloat in [240, 300, 480, 700, 1000] {
            #expect(ColumnRubberBand.liveWidth(forRawTarget: raw, policy: policy) == raw)
        }
        #expect(ColumnRubberBand.liveWidth(forRawTarget: 1400, policy: policy) == policy.full)
    }

    @Test func liveWidthResistsBelowMinimumAndMeetsTheCloseThresholdWithTheFinger() {
        let belowMinimum = ColumnRubberBand.liveWidth(forRawTarget: 100, policy: policy)
        #expect(belowMinimum > 100, "a raw target under minimum is pulled back toward it")
        #expect(belowMinimum < policy.minimum, "but still short of minimum while the drag continues")
        let atThreshold = ColumnRubberBand.liveWidth(forRawTarget: policy.closeThreshold, policy: policy)
        #expect(abs(atThreshold - policy.closeThreshold) < 0.001)
    }

    @Test func aGrabMidMotionPicksTheDividerUpWhereItIsDrawn() {
        // An open still settling draws widths below minimum; the raw target
        // recovered from them must draw the same width, or the pane jumps.
        for drawn: CGFloat in [10, 90, 200, 239, 240, 600, 1000] {
            let raw = ColumnRubberBand.rawTarget(forLiveWidth: drawn, policy: policy)
            #expect(abs(ColumnRubberBand.liveWidth(forRawTarget: raw, policy: policy) - drawn) < 0.01, "drawn \(drawn)")
        }
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
            rawWidth: 360, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .width(360))
    }

    @Test func releasingPastTheMaximumShortOfTheThresholdSettlesAtTheMaximum() {
        let outcome = ColumnSnapResolver.resolve(
            rawWidth: policy.expandThreshold - 1, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .width(policy.maximum))
    }

    @Test func releasingBelowTheCloseThresholdCloses() {
        let outcome = ColumnSnapResolver.resolve(
            rawWidth: policy.closeThreshold - 1, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .closed)
    }

    @Test func releasingPastTheExpandThresholdCommitsToFull() {
        let outcome = ColumnSnapResolver.resolve(
            rawWidth: policy.expandThreshold + 1, widthVelocity: 0, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .full)
    }

    @Test func aFastFlingCommitsEvenFromInsideTheOrdinaryRange() {
        // Still well inside the ordinary range, but moving fast enough toward
        // full that the projected stopping point crosses the threshold.
        let rawWidth: CGFloat = 440
        #expect(ColumnSnapResolver.zone(for: rawWidth, policy: policy) == .ordinary)
        let outcome = ColumnSnapResolver.resolve(
            rawWidth: rawWidth, widthVelocity: 3000, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .full, "a fast flick settles like a slower drag further in the same direction would have")
    }

    @Test func aFastFlingClosesEvenFromInsideTheOrdinaryRange() {
        let rawWidth: CGFloat = 260
        #expect(ColumnSnapResolver.zone(for: rawWidth, policy: policy) == .ordinary)
        let outcome = ColumnSnapResolver.resolve(
            rawWidth: rawWidth, widthVelocity: -3000, policy: policy, rememberedWidth: 320, wasFull: false
        )
        #expect(outcome == .closed)
    }

    @Test func leavingFullReturnsToTheRememberedWidthNotWhereThePullBackStopped() {
        // Dragged back from full into ordinary territory at an arbitrary
        // point (410): the pane still returns to what was remembered (300),
        // not to 410.
        let outcome = ColumnSnapResolver.resolve(
            rawWidth: 410, widthVelocity: 0, policy: policy, rememberedWidth: 300, wasFull: true
        )
        #expect(outcome == .width(300))
    }

    @Test func leavingFullAllTheWayToTheCloseEdgeStillCloses() {
        let outcome = ColumnSnapResolver.resolve(
            rawWidth: policy.closeThreshold - 1, widthVelocity: 0, policy: policy, rememberedWidth: 300, wasFull: true
        )
        #expect(outcome == .closed)
    }

    @Test func stayingNearFullSpringsBackToFull() {
        let outcome = ColumnSnapResolver.resolve(
            rawWidth: policy.full - 1, widthVelocity: 0, policy: policy, rememberedWidth: 300, wasFull: true
        )
        #expect(outcome == .full)
    }
}

/// `TrailingColumnController` end to end in a real window: dragging the
/// divider clamps to the panel's own range, the screen beside never narrows
/// past its minimum and stops reflowing once the pane slides over it, past
/// the threshold the pane takes the window but its grab edge, and a settled
/// width is remembered proportionally for the next column, anywhere in the
/// app, that opens with nothing of its own yet remembered.
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
            host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column
            #expect(controller.widthForTesting == 300, "opens at its own ideal width with nothing remembered")

            host.drag(by: -50) // dragging toward the screen widens the column
            #expect(controller.widthForTesting == 350)
            #expect(AppPreferences.TrailingColumn.widthFraction == 0.35)

            // Past the maximum, short of the expand threshold: the pane
            // follows the finger over the screen, then settles back at the
            // maximum rather than opening further.
            let handle = try #require(controller.resizeHandleForTesting)
            handle.onBegan?()
            handle.onChanged?(-170)
            #expect(controller.widthForTesting == 520)
            handle.onEnded?(-170, 0)
            host.settle()
            #expect(controller.widthForTesting == 500)

            // Below the minimum, short of the close threshold: resists, then
            // settles back at the minimum rather than closing.
            handle.onBegan?()
            handle.onChanged?(350)
            #expect(controller.widthForTesting! < 200)
            #expect(controller.widthForTesting! > 100)
            handle.onEnded?(350, 0)
            host.settle()
            #expect(controller.widthForTesting == 200)
        }
    }

    @Test func theScreenBesideKeepsItsMinimumAndIsCoveredRatherThanSqueezedAtFull() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 900)
            let controller = host.screen.column
            let overlay = try #require(controller.overlayForTesting)
            let handle = try #require(controller.resizeHandleForTesting)
            let screenMinimum = TrailingColumnWidthPolicy.screenMinimumWidth
            let full = 1000 - TrailingColumnOverlayView.fullWindowGrabEdge

            // The panel's own 900 would leave the screen 100 points; the
            // side-by-side range stops where the screen keeps its minimum.
            handle.onBegan?()
            handle.onChanged?(-(1000 - screenMinimum - 300))
            host.window.layoutIfNeeded()
            #expect(controller.widthForTesting == 1000 - screenMinimum)
            #expect(host.screenWidth == screenMinimum)
            #expect(overlay.cover.alpha == 0)
            let layoutsAtMaximum = host.screen.layoutCount

            // On toward full, short of the threshold: the pane slides over
            // the screen, which neither narrows nor lays out again, and fades
            // under it.
            handle.onChanged?(-(1000 - screenMinimum - 300) - 100)
            host.window.layoutIfNeeded()
            #expect(controller.widthForTesting == 1000 - screenMinimum + 100)
            #expect(host.screenWidth == screenMinimum)
            #expect(host.screen.layoutCount == layoutsAtMaximum)
            #expect(overlay.cover.alpha > 0 && overlay.cover.alpha < 1)

            // Past the threshold: full is the window but its grab edge, the
            // screen covered there, and VoiceOver kept in the pane.
            handle.onChanged?(-800)
            handle.onEnded?(-800, 0)
            host.settle()
            host.window.layoutIfNeeded()
            #expect(controller.isFullForTesting)
            #expect(controller.widthForTesting == full)
            #expect(host.screenWidth == screenMinimum)
            #expect(host.screen.layoutCount == layoutsAtMaximum)
            #expect(overlay.cover.alpha == 1)
            #expect(overlay.cover.frame.maxX <= TrailingColumnOverlayView.fullWindowGrabEdge)
            #expect(overlay.accessibilityViewIsModal)
            #expect(handle.frame.minX == 0, "the whole grab edge drags the pane back")
        }
    }

    @Test func pastTheExpandThresholdTakesTheFullWindowAndBackReturnsToTheRememberedWidth() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column

            // Settle an ordinary width to remember first.
            host.drag(by: -200)
            #expect(controller.widthForTesting == 500)
            #expect(controller.isFullForTesting == false)

            // Past the expand threshold: commits to full, the screen covered.
            host.drag(by: -400)
            #expect(controller.isFullForTesting == true)
            #expect(controller.widthForTesting == 1000 - TrailingColumnOverlayView.fullWindowGrabEdge)

            // A grab at full picks the pane up where it is, with no jump.
            let handle = try #require(controller.resizeHandleForTesting)
            handle.onBegan?()
            handle.onChanged?(0)
            #expect(controller.widthForTesting == 1000 - TrailingColumnOverlayView.fullWindowGrabEdge)

            // Dragging back out of full and releasing mid-range returns to
            // the remembered width (500), not wherever the drag stopped.
            handle.onChanged?(600)
            handle.onEnded?(600, 0)
            host.settle()
            #expect(controller.isFullForTesting == false)
            #expect(controller.widthForTesting == 500)
        }
    }

    @Test func aGrabWhileOpeningPicksThePaneUpWhereItIsDrawn() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500, settles: false)
            let controller = host.screen.column
            let overlay = try #require(controller.overlayForTesting)
            let handle = try #require(controller.resizeHandleForTesting)
            // Let the open draw part of the way.
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            handle.onBegan?()
            let drawn = try #require(controller.widthForTesting)
            #expect(drawn < 300, "the open was still under way")
            #expect(abs(drawn - overlay.column.frame.width) < 0.5, "the width is read back from the drawn column, not the open's target")
            handle.onChanged?(0)
            #expect(abs(controller.widthForTesting! - drawn) < 0.5)
        }
    }

    @Test func expandAndRestoreAccessibilityActionsMatchTheGesturesOutcome() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column
            let handle = try #require(controller.resizeHandleForTesting)

            handle.onExpandRequested?()
            #expect(controller.isFullForTesting == true)
            #expect(controller.widthForTesting == 1000 - TrailingColumnOverlayView.fullWindowGrabEdge)
            #expect(handle.accessibilityValue == String(localized: "Full window"))

            handle.onRestoreRequested?()
            #expect(controller.isFullForTesting == false)
            #expect(controller.widthForTesting == 300)
        }
    }

    @Test func accessibilityIncrementAndDecrementStepByAFixedAmountClampedToRange() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column
            let handle = try #require(controller.resizeHandleForTesting)

            handle.accessibilityIncrement()
            host.settle()
            #expect(controller.widthForTesting == 300 + TrailingColumnResizeHandle.accessibilityStep)

            for _ in 0..<20 {
                handle.accessibilityDecrement()
                host.settle()
            }
            #expect(controller.widthForTesting == 200, "never steps below the panel's own minimum")
        }
    }

    @Test func draggingPastTheCloseThresholdDismissesLikeItsOwnDoneControl() throws {
        withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column
            var dismissed = false
            controller.onDismissRequested = { dismissed = true }

            host.drag(by: 250) // raw = 300 - 250 = 50, under the close threshold (100)
            #expect(dismissed)
        }
    }

    @Test func aGrabWhileClosingCannotStrandThePanelHalfRemoved() throws {
        try withCleanWidthPreference {
            let host = makeHost(width: 1000)
            defer { host.hide() }
            host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
            let controller = host.screen.column
            let handle = try #require(controller.resizeHandleForTesting)
            host.screen.column.show(nil, root: makeTestAppRoot())
            handle.onBegan?()
            handle.onChanged?(-100)
            handle.onEnded?(-100, 0)
            host.settle()
            #expect(controller.overlayForTesting == nil, "the close ran to its end and took the panel off")
        }
    }

    @Test func aSettledWidthIsRememberedProportionallyByTheNextColumn() throws {
        withCleanWidthPreference {
            let firstHost = makeHost(width: 1000)
            firstHost.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 900)
            firstHost.drag(by: -100) // settles at 400 of 1000: a 0.4 fraction
            #expect(firstHost.screen.column.widthForTesting == 400)
            firstHost.hide()

            // A second, unrelated column, in a differently sized window,
            // opens at the same fraction of its own width rather than the
            // first column's absolute points.
            let secondHost = makeHost(width: 800)
            defer { secondHost.hide() }
            secondHost.showPanel(minWidth: 200, idealWidth: 260, maxWidth: 700)
            #expect(secondHost.screen.column.widthForTesting == 320, "0.4 of the second window's 800pt width")
        }
    }

    // MARK: - Fixture

    @MainActor
    private struct Host {
        let screen: ResizeHostScreen
        let window: UIWindow

        /// The screen's own width beside the column: its safe area, which
        /// the column insets.
        var screenWidth: CGFloat { screen.view.safeAreaLayoutGuide.layoutFrame.width }

        func showPanel(minWidth: CGFloat, idealWidth: CGFloat, maxWidth: CGFloat, settles: Bool = true) {
            screen.showPanel(root: makeTestAppRoot(), minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth)
            if settles { settle() }
        }

        /// One whole drag of the divider, released with no velocity, landed.
        func drag(by translationX: CGFloat) {
            guard let handle = screen.column.resizeHandleForTesting else { return }
            handle.onBegan?()
            handle.onChanged?(translationX)
            handle.onEnded?(translationX, 0)
            settle()
        }

        func settle() {
            screen.column.finishSettleForTesting()
            window.layoutIfNeeded()
        }

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
/// screens mount one. Its content fills the safe area the column insets, as
/// the chat's does, and counts its own layout passes: a reflow of the
/// screen beside.
@MainActor
private final class ResizeHostScreen: UIViewController {
    lazy var column = TrailingColumnController(screen: self)
    private let content = LayoutCountingView()
    var layoutCount: Int { content.layoutCount }

    override func viewDidLoad() {
        super.viewDidLoad()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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

private final class LayoutCountingView: UIView {
    private(set) var layoutCount = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCount += 1
    }
}
