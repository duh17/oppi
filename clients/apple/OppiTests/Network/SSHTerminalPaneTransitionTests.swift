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
            transition.drag(translationX: CGFloat(-step) * 150, neighbour: "next", offersNewPane: false)
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

        rig.transition.drag(translationX: -120, neighbour: "logs", offersNewPane: false)
        #expect(cover.transform.tx == -120)
        #expect(placeholder.transform.tx == -120 + rig.grid.bounds.width, "the incoming pane waits on the right")
        #expect(rig.transition.placeholderTitle == "logs")

        rig.transition.drag(translationX: 90, neighbour: nil, offersNewPane: false)
        #expect(cover.transform.tx > 0 && cover.transform.tx < 90, "an edge resists")
        #expect(placeholder.transform.tx == cover.transform.tx - rig.grid.bounds.width)
        #expect(rig.transition.placeholderTitle == nil)
    }

    /// Past the last pane the incoming side is the New Pane card, not a rubber
    /// band: the screen follows the finger one to one, and the card is dimmed
    /// until the drag is far enough that letting go opens a pane. The first
    /// pane's edge, and a drag that way, keep the rubber band.
    @Test func pastTheLastPaneTheIncomingSideIsTheNewPaneCard() throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        #expect(rig.transition.beginDrag())
        let (placeholder, cover) = (rig.layers[0], rig.layers[1])

        rig.transition.drag(translationX: -30, neighbour: nil, offersNewPane: true)
        #expect(cover.transform.tx == -30, "no resistance: the card comes with the finger")
        #expect(placeholder.transform.tx == -30 + rig.grid.bounds.width)
        #expect(rig.transition.isShowingNewPaneCard && rig.transition.placeholderTitle == "New Pane")
        #expect(!rig.transition.isNewPaneArmed, "dimmed below the threshold")

        rig.transition.drag(translationX: -80, neighbour: nil, offersNewPane: true)
        #expect(rig.transition.isNewPaneArmed, "lit past it")
        rig.transition.drag(translationX: -40, neighbour: nil, offersNewPane: true)
        #expect(!rig.transition.isNewPaneArmed, "and dimmed again when the finger comes back")

        rig.transition.drag(translationX: 90, neighbour: nil, offersNewPane: true)
        #expect(cover.transform.tx > 0 && cover.transform.tx < 90, "the first pane's edge resists")
        #expect(!rig.transition.isShowingNewPaneCard && rig.transition.placeholderTitle == nil)

        rig.transition.drag(translationX: -80, neighbour: nil, offersNewPane: false)
        #expect(cover.transform.tx > -80 && !rig.transition.isShowingNewPaneCard, "a session that cannot open a pane resists")
    }

    /// A release on the card slides it in and keeps it up while the host opens
    /// the pane, however long that takes (the pane's snapshot has not been
    /// asked for yet, so the grid's old screen must not show). Once the pane
    /// is open the card takes its name and lifts like any switch's.
    @Test func theNewPaneCardStaysUntilThePaneIsOpenThenWaitsForItsSnapshot() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        rig.transition.revealTimeout = .milliseconds(100)
        #expect(rig.transition.beginDrag())
        rig.transition.drag(translationX: -150, neighbour: nil, offersNewPane: true)
        rig.transition.endDragCreatingPane(velocityX: -800)
        #expect(rig.transition.phase == .settling && rig.transition.isAwaitingCreation)
        #expect(await settle(rig, to: .covering))
        #expect(rig.layers.count == 1 && rig.transition.placeholderTitle == "New Pane\u{2026}")

        // The old pane's screen is on the grid: neither a frame nor a snapshot of it lifts the card.
        rig.transition.snapshotRestored(of: "a", expecting: "a")
        rig.transition.frameDrawn()
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(400)) { rig.transition.phase == .covering })

        rig.transition.paneCreated(named: "shell")
        #expect(!rig.transition.isAwaitingCreation && rig.transition.placeholderTitle == "shell" && !rig.transition.isShowingNewPaneCard)
        rig.transition.frameDrawn()
        #expect(rig.transition.phase == .covering, "the new pane's snapshot is still to come")
        rig.transition.snapshotRestored(of: "new", expecting: "new")
        rig.transition.frameDrawn()
        #expect(rig.transition.phase == .idle)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.layers.isEmpty })
    }

    /// A pane that could not be opened sends the card away to the grid's old
    /// pane, whether the answer comes after the slide or during it, and leaves
    /// nothing over the grid.
    @Test func aFailedNewPaneSlidesTheCardAwayToTheOldPane() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        for lateAnswer in [true, false] {
            #expect(rig.transition.beginDrag())
            rig.transition.drag(translationX: -150, neighbour: nil, offersNewPane: true)
            rig.transition.endDragCreatingPane(velocityX: -800)
            if lateAnswer { #expect(await settle(rig, to: .covering)) }
            rig.transition.creationFailed()
            #expect(!rig.transition.isAwaitingCreation)
            #expect(await settle(rig, to: .idle))
            #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.layers.isEmpty }, "nothing stays over the grid")
            #expect(!rig.transition.isPlaceholderShown)
        }
    }

    /// A host that never answers cannot leave the card up for ever: after the
    /// creation timeout it goes, and a pane that opens later is a switch of its own.
    @Test func aNewPaneThatNeverOpensIsRevealedAfterTheCreationTimeout() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        rig.transition.creationTimeout = .milliseconds(1200)
        rig.transition.slideToNewPane()
        #expect(rig.transition.phase == .settling && rig.transition.isAwaitingCreation)
        #expect(await settle(rig, to: .covering))
        #expect(await settle(rig, to: .idle), "the timeout reveals whatever the grid shows")
        #expect(!rig.transition.isAwaitingCreation)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { rig.layers.isEmpty })

        rig.transition.paneCreated(named: "late")
        #expect(rig.transition.phase == .settling && rig.transition.placeholderTitle == "late", "the late pane slides in like a switch")
    }

    /// Opening a pane with no finger (VoiceOver, the menu) slides the old
    /// screen off the same way and says when the switch began and settled.
    @Test func openingAPaneWithNoFingerSlidesTheCardIn() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        var events: [Bool] = []
        rig.transition.onSwitching = { events.append($0) }
        rig.transition.slideToNewPane()
        #expect(events == [true] && rig.layers.count == 2)
        #expect(await settle(rig, to: .covering))
        #expect(events == [true, false] && rig.transition.placeholderTitle == "New Pane\u{2026}")
        // Not from rest: nothing slides again.
        rig.transition.slideToNewPane()
        #expect(rig.layers.count == 1)
    }

    /// Letting go short puts the screen back without asking for a pane, and
    /// leaves nothing over the grid.
    @Test func aShortDragSpringsBackAndLeavesNothingOverTheGrid() async throws {
        let rig = try Rig()
        defer { rig.dismiss() }
        #expect(rig.transition.beginDrag())
        rig.transition.drag(translationX: -30, neighbour: "logs", offersNewPane: false)
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
        rig.transition.drag(translationX: -30, neighbour: "b", offersNewPane: false)
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
        rig.transition.drag(translationX: -30, neighbour: "logs", offersNewPane: false)
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
