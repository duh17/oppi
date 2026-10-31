import Testing
import UIKit
@testable import Oppi

/// The slide between a Rex terminal's panes, on a real grid in a window: what
/// covers the grid, and when it lets go.
@Suite("SSH terminal pane transition", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalPaneTransitionTests {
    @MainActor
    final class Rig {
        let window: UIWindow
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let grid: SSHTerminalGridView
        var transition: SSHTerminalPaneTransition { grid.paneTransition }

        init() throws {
            grid = SSHTerminalGridView(channel: try SSHTerminalChannel(), paste: { _ in }, followChanged: { _ in })
            grid.frame = container.bounds
            container.addSubview(grid)
            let host = UIViewController()
            host.view.addSubview(container)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.makeKeyAndVisible()
            container.layoutIfNeeded()
        }

        func dismiss() {
            window.isHidden = true
            window.rootViewController = nil
        }

        /// What sits above the grid in its container: the placeholder, then the old screen.
        var layers: [UIView] { container.subviews.filter { $0 !== grid } }

        /// A drag far enough to commit, lifted: the old screen slides off.
        func commit(step: Int = 1) {
            #expect(transition.beginDrag())
            transition.drag(translationX: CGFloat(-step) * 150, neighbour: "next")
            transition.endDrag(committing: step, velocityX: CGFloat(-step) * 800)
        }
    }

    func settle(_ rig: Rig, to phase: SSHTerminalPaneTransition.Phase) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) { rig.transition.phase == phase }
    }

    /// While a pane lies that way the old screen follows the finger and the
    /// pane's name waits on the side it comes from; at the end of the strip
    /// the screen gives way instead, with nothing named.
    @Test func theOldScreenFollowsTheFingerAndAnEdgeGivesWay() throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        #expect(rig.transition.beginDrag())
        #expect(!rig.transition.beginDrag(), "one transition at a time")
        let (placeholder, cover) = (rig.layers[0], rig.layers[1])

        rig.transition.drag(translationX: -120, neighbour: "logs")
        #expect(cover.transform.tx == -120)
        #expect(placeholder.transform.tx == -120 + rig.grid.bounds.width, "the incoming pane waits on the right")
        #expect(rig.transition.placeholderTitle == "logs")

        rig.transition.drag(translationX: 90, neighbour: nil)
        #expect(cover.transform.tx > 0 && cover.transform.tx < 90, "an edge resists")
        #expect(placeholder.transform.tx == cover.transform.tx - rig.grid.bounds.width)
        #expect(rig.transition.placeholderTitle == nil)
    }

    /// Letting go short puts the screen back without asking for a pane, and
    /// leaves nothing over the grid.
    @Test func aShortDragSpringsBackAndLeavesNothingOverTheGrid() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        #expect(rig.transition.beginDrag())
        rig.transition.drag(translationX: -30, neighbour: "logs")
        rig.transition.endDrag(committing: nil, velocityX: 0)
        #expect(await settle(rig, to: .idle))
        #expect(rig.layers.isEmpty && !rig.transition.isPlaceholderShown)
    }

    /// A committed switch slides the old screen away and then covers the grid
    /// with the incoming pane's placeholder: a frame drawn before the pane's
    /// snapshot is applied is still the old pane's, so the cover stays until a
    /// frame follows the snapshot.
    @Test func aCommittedSwitchCoversTheGridUntilTheNewPanesSnapshotIsDrawn() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        rig.commit()
        #expect(await settle(rig, to: .covering))
        #expect(rig.layers.count == 1 && rig.layers[0].transform == .identity, "only the placeholder is left, over the grid")
        #expect(rig.transition.placeholderTitle == "next")

        rig.transition.frameDrawn()
        #expect(rig.transition.phase == .covering, "a frame of the old pane does not lift it")
        rig.transition.snapshotRestored(of: "b", expecting: "b")
        #expect(rig.transition.phase == .covering, "the snapshot alone is not on the screen yet")
        rig.transition.frameDrawn()
        #expect(rig.transition.phase == .idle && !rig.transition.isPlaceholderShown)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.layers.isEmpty })
    }

    /// A snapshot that lands while the old screen is still sliding off waits for
    /// the slide: the cover goes once both are done.
    @Test func aSnapshotThatLandsMidSlideLiftsTheCoverWhenTheSlideEnds() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        rig.commit()
        #expect(rig.transition.phase == .settling)
        rig.transition.snapshotRestored(of: "b", expecting: "b")
        rig.transition.frameDrawn()
        #expect(await settle(rig, to: .idle))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.layers.isEmpty })
    }

    /// A pane that never answers cannot leave the grid blank.
    @Test func aPaneThatNeverAnswersIsRevealedAfterTheTimeout() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        // Longer than the slide, so the cover is seen before the timeout lifts it.
        rig.transition.revealTimeout = .milliseconds(1200)
        rig.commit()
        #expect(await settle(rig, to: .covering))
        #expect(rig.transition.isPlaceholderShown)
        #expect(await settle(rig, to: .idle), "the timeout reveals whatever the grid shows")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.layers.isEmpty })
    }

    /// A snapshot nobody waits for (the first open, a reconnect) lifts and
    /// covers nothing.
    @Test func aSnapshotWithNoSwitchBehindItChangesNothing() throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        rig.transition.snapshotRestored(of: "b", expecting: "b")
        rig.transition.frameDrawn()
        #expect(rig.transition.phase == .idle && rig.layers.isEmpty)
    }

    /// A second switch while the cover is up waits for the newest pane's
    /// snapshot, not the one before it: B's snapshot can still land after C was
    /// asked for, and it is not the screen the cover stands in for.
    @Test func aSecondSwitchWhileCoveredWaitsForTheNewestPanesSnapshot() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        rig.transition.slide(toward: 1, neighbour: "b")
        #expect(await settle(rig, to: .covering))
        rig.transition.slide(toward: 1, neighbour: "c")
        #expect(rig.transition.placeholderTitle == "c")

        // B's snapshot lands after C was asked for.
        rig.transition.snapshotRestored(of: "b", expecting: "c")
        rig.transition.frameDrawn()
        #expect(rig.transition.phase == .covering, "b's screen is not c's")
        rig.transition.snapshotRestored(of: "c", expecting: "c")
        rig.transition.frameDrawn()
        #expect(rig.transition.phase == .idle)
    }

    /// The same overtaking while the first slide is still running.
    @Test func anOvertakenSwitchsSnapshotDoesNotLiftTheCoverWhileSliding() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        rig.transition.slide(toward: 1, neighbour: "b")
        #expect(rig.transition.phase == .settling)
        rig.transition.slide(toward: 1, neighbour: "c")
        rig.transition.snapshotRestored(of: "b", expecting: "c")
        rig.transition.frameDrawn()
        #expect(await settle(rig, to: .covering), "the slide ends, and the cover stays")
        rig.transition.frameDrawn()
        #expect(rig.transition.phase == .covering)
        rig.transition.snapshotRestored(of: "c", expecting: "c")
        rig.transition.frameDrawn()
        #expect(rig.transition.phase == .idle)
    }

    /// A switch that comes while the screen is springing back is still a
    /// covered switch: the spring-back's views are dropped, not left to tear
    /// the cover down when they finish.
    @Test func aSwitchDuringASpringBackStillSlidesAndCovers() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        #expect(rig.transition.beginDrag())
        rig.transition.drag(translationX: -30, neighbour: "b")
        rig.transition.endDrag(committing: nil, velocityX: 0)
        #expect(rig.transition.phase == .settling)

        rig.transition.slide(toward: 1, neighbour: "b")
        #expect(rig.transition.phase == .settling && rig.transition.placeholderTitle == "b")
        #expect(await settle(rig, to: .covering), "the switch is covered, not torn down with the spring-back")
        #expect(rig.layers.count == 1 && rig.transition.isPlaceholderShown)
        rig.transition.snapshotRestored(of: "b", expecting: "b")
        rig.transition.frameDrawn()
        #expect(rig.transition.phase == .idle)
    }

    /// A switch with no finger behind it slides the same way, covers, and lifts.
    @Test func aSwitchWithNoFingerSlidesAndCoversTheSameWay() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        rig.transition.slide(toward: -1, neighbour: "prev")
        #expect(rig.transition.phase == .settling && rig.layers.count == 2)
        #expect(rig.transition.placeholderTitle == "prev")
        #expect(await settle(rig, to: .covering))
        rig.transition.snapshotRestored(of: "b", expecting: "b")
        rig.transition.frameDrawn()
        #expect(await settle(rig, to: .idle))
    }

    /// A grid taken out of its screen (a terminal switch) must not leave the
    /// slide's views behind in the parent it left.
    @Test func aGridThatLeavesItsViewTakesTheSlideWithIt() throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        rig.commit()
        #expect(rig.layers.count == 2)
        rig.grid.removeFromSuperview()
        #expect(rig.container.subviews.isEmpty && rig.transition.phase == .idle)
    }

    /// What the layout minimap listens to: a switch begins when a finger goes
    /// down (or a switch with no finger starts) and settles when the slide or
    /// the spring back ends, not when the new pane's screen is drawn.
    @Test func theTransitionSaysWhenASwitchBeginsAndSettles() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        var events: [Bool] = []
        rig.transition.onSwitching = { events.append($0) }

        rig.commit()
        #expect(events == [true], "a finger down, then the slide runs")
        #expect(await settle(rig, to: .covering))
        #expect(events == [true, false], "the slide ended; the placeholder still covers the grid")
        rig.transition.snapshotRestored(of: "b", expecting: "b")
        rig.transition.frameDrawn()
        #expect(await settle(rig, to: .idle))
        #expect(events == [true, false], "lifting the cover is not a switch")

        events = []
        #expect(rig.transition.beginDrag())
        rig.transition.drag(translationX: -30, neighbour: "logs")
        rig.transition.endDrag(committing: nil, velocityX: 0)
        #expect(events == [true])
        #expect(await settle(rig, to: .idle))
        #expect(events == [true, false], "the spring back ended")

        events = []
        rig.transition.slide(toward: 1, neighbour: "next")
        #expect(events == [true])
        #expect(await settle(rig, to: .covering))
        #expect(events == [true, false])
        // Another switch while the new screen is awaited is a flash of its own.
        rig.transition.slide(toward: 1, neighbour: "later")
        #expect(events == [true, false, true, false])
    }

    /// A grid that leaves its view mid-swipe ends the switch; a switch that
    /// cannot slide (no view to slide in) still began and settled.
    @Test func aDroppedOrUnslidableSwitchStillSettles() throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        var events: [Bool] = []
        rig.transition.onSwitching = { events.append($0) }
        #expect(rig.transition.beginDrag())
        rig.grid.removeFromSuperview()
        #expect(events == [true, false])

        events = []
        rig.transition.slide(toward: 1, neighbour: "next")
        #expect(events == [true, false])
    }
}
