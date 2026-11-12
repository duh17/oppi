import Testing
import UIKit
@testable import Oppi

/// The pane host's state machine in a real window: what each leaf can see of
/// itself across a push over the owner, a window that narrows past the fit
/// rule, a rotation mid-drag and a memory warning; and the keyboard rule.
@MainActor
@Suite("Pane host", .serialized)
struct PaneHostControllerTests {
    /// WA1: in portrait the mini's sidebar is a drawer over the panes, never
    /// a tiled column, so the pane area is the whole 744 pt window.
    @Test func theMiniInPortraitKeepsTheSidebarADrawer() {
        let portrait = WorkspaceNavigationPresentation.resolve(
            horizontalSizeClass: .regular, verticalSizeClass: .regular, size: CGSize(width: 744, height: 1133)
        )
        #expect(portrait == .stack)
        let landscape = WorkspaceNavigationPresentation.resolve(
            horizontalSizeClass: .regular, verticalSizeClass: .regular, size: CGSize(width: 1133, height: 744)
        )
        #expect(landscape == .split)
    }

    /// WA1 in a real window: the chat keeps its minimum and a list companion
    /// takes the rest of the 744 pt.
    @Test func aPortraitMiniHostShowsTheLeafAndAListBesideIt() throws {
        withCleanCompanionWidth {
            let host = PaneTestHost(width: 744, height: 1133)
            defer { host.hide() }
            host.showPanel(minWidth: 320, idealWidth: 400, maxWidth: 640)
            #expect(host.panes.companionWidthForTesting == 368)
            #expect(abs(host.screenWidth - (744 - 368)) < 0.5)
            #expect(!host.panes.isFullForTesting)
        }
    }

    /// R4: a push over the owner parks its companion at once; the view stays
    /// in the hierarchy, hidden, for `parkedViewLifetime`, then leaves it;
    /// the owner's return shows the same stack, at its top.
    @Test func aPushOverTheOwnerParksTheCompanionAndItsReturnShowsTheSameStack() async throws {
        try await withCleanCompanionWidthAsync {
            let host = PaneTestHost(width: 1000, inNavigation: true, parkedViewLifetime: 0.2)
            defer { host.hide() }
            let companion = PaneCompanionScreen()
            host.showPanel(makeScreen: { companion })
            let container = try #require(host.screen.leaf.containerForTesting as? UINavigationController)
            let pushedInside = PaneCompanionScreen()
            container.pushViewController(pushedInside, animated: false)
            host.window.layoutIfNeeded()
            #expect(pushedInside.visibilities.isEmpty, "only the leaf's front screen hears the transition")
            #expect(host.screen.visibilities.last == .visible(focused: true))

            let stack = try #require(host.panes.primary as? UINavigationController)
            stack.pushViewController(UIViewController(), animated: false)
            host.window.layoutIfNeeded()
            #expect(pushedInside.visibilities.last == .parked)
            #expect(container.view.window != nil, "a parked view stays a while for a quick return")
            #expect(container.view.isHidden)
            #expect(host.screenWidth == 1000, "the primary has the window to itself")

            #expect(await waitForMainActorCondition(timeout: .seconds(3)) { container.view.window == nil },
                    "the parked view left the hierarchy")
            #expect(container.parent == nil)

            stack.popViewController(animated: false)
            host.window.layoutIfNeeded()
            #expect(host.screen.leaf.containerForTesting === container, "the same leaf came back")
            #expect(container.topViewController === pushedInside, "at its stack top")
            #expect(pushedInside.visibilities.last == .visible(focused: false))
            #expect(container.view.window != nil)
            #expect(host.screenWidth < 1000)
        }
    }

    /// R4 and the fit rule: a window too narrow for both minimums covers the
    /// leaf with its companion; widening puts both back side by side.
    @Test func aNarrowingWindowCoversTheLeafAndWideningRestoresIt() throws {
        try withCleanCompanionWidth {
            let host = PaneTestHost(width: 1000)
            defer { host.hide() }
            let companion = PaneCompanionScreen()
            host.showPanel(minWidth: 320, idealWidth: 400, maxWidth: 640, makeScreen: { companion })
            #expect(host.screen.visibilities.last == .visible(focused: true))

            host.resize(width: 600)
            #expect(host.panes.companionWidthForTesting == 600 - PaneWidthPolicy.fullWindowGrabEdge)
            #expect(host.screen.visibilities.last == .covered)
            #expect(companion.visibilities.last == .visible(focused: false))
            #expect(host.panes.focusedScreen === companion, "Find acts in the only leaf showing")

            // The divider offers only what it can do: close, not "show chat".
            let divider = host.panes.dividerForTesting
            #expect(divider.mode == .noRoomBeside)
            #expect(divider.accessibilityCustomActions?.map(\.name) == [String(localized: "Close Panel")])
            var closed = false
            host.screen.leaf.onDismissRequested = { closed = true }
            let close = try #require(divider.accessibilityCustomActions?.first)
            _ = close.actionHandler?(close)
            #expect(closed)

            host.resize(width: 1000)
            #expect(host.panes.companionWidthForTesting == 400)
            #expect(host.screen.visibilities.last == .visible(focused: true))
            #expect(!host.panes.isFullForTesting, "full was the fit, not the person's choice")
            #expect(host.panes.dividerForTesting.mode == .beside)
            #expect(host.panes.focusedScreen === host.screen)
        }
    }

    /// R5: a rotation mid-drag cancels the drag at the last settled width,
    /// scaled to the new bounds; the rest of the gesture moves nothing.
    @Test func aRotationDuringADragCancelsItAtTheLastSettledWidth() throws {
        withCleanCompanionWidth {
            let host = PaneTestHost(width: 1000)
            defer { host.hide() }
            host.showPanel(minWidth: 200, idealWidth: 300, maxWidth: 500)
            host.drag(by: -100) // settles at 400 of 1000
            let divider = host.panes.dividerForTesting
            divider.onBegan?()
            divider.onChanged?(-80)
            #expect(host.panes.companionWidthForTesting == 480)

            host.resize(width: 800)
            #expect(host.panes.companionWidthForTesting == 320, "0.4 of the new width")
            divider.onChanged?(-200)
            divider.onEnded?(-200, 0)
            host.settle()
            #expect(host.panes.companionWidthForTesting == 320, "the cancelled drag moves nothing")
            #expect(host.panes.restingFractionForTesting == 0.4)
        }
    }

    /// P1: a memory warning reduces two parked leaves to what rebuilds them;
    /// each is rebuilt when its owner returns.
    @Test func aMemoryWarningDropsParkedLeavesAndTheirOwnersRebuildThem() throws {
        try withCleanCompanionWidth {
            let host = PaneTestHost(width: 1000, inNavigation: true)
            defer { host.hide() }
            var builds = 0
            let make: () -> UIViewController = {
                builds += 1
                return PaneCompanionScreen()
            }
            host.showPanel(makeScreen: make)
            let stack = try #require(host.panes.primary as? UINavigationController)
            let second = PaneLeafScreen()
            stack.pushViewController(second, animated: false)
            host.window.layoutIfNeeded()
            second.showPanel(root: host.root, minWidth: 320, idealWidth: 400, maxWidth: 640, makeScreen: make)
            host.settle()
            stack.pushViewController(UIViewController(), animated: false)
            host.window.layoutIfNeeded()
            #expect(builds == 2)
            #expect(host.screen.leaf.containerForTesting != nil)
            #expect(second.leaf.containerForTesting != nil)

            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            #expect(host.screen.leaf.containerForTesting == nil)
            #expect(second.leaf.containerForTesting == nil)

            stack.popViewController(animated: false)
            host.window.layoutIfNeeded()
            #expect(builds == 3, "the returning owner's leaf is rebuilt")
            #expect(second.leaf.mountedScreenForTesting is PaneCompanionScreen)
            #expect(host.panes.companionWidthForTesting == 400)
        }
    }

    /// K1: the composer's field leaves the companion alone (no layout pass,
    /// no frame change); a companion field keeps the leaf beside in place
    /// and takes focus; a field in a sheet leaves every leaf following the
    /// keyboard.
    @Test func onlyTheFirstRespondersLeafFollowsTheKeyboard() async throws {
        await withCleanCompanionWidthAsync {
            let host = PaneTestHost(width: 1000, inNavigation: true)
            defer { host.hide() }
            let companion = PaneCompanionScreen()
            host.showPanel(makeScreen: { companion })
            let frame = companion.view.frame
            let layouts = companion.layoutCount

            beginEditing(host.screen.field)
            host.window.layoutIfNeeded()
            #expect(host.screen.followsKeyboard)
            #expect(companion.layoutCount == layouts, "the composer's keyboard lays out only its own leaf")
            #expect(companion.view.frame == frame)
            #expect(host.panes.focusedLeaf == .primary)

            beginEditing(companion.field)
            #expect(!host.screen.followsKeyboard, "a companion field leaves the chat's composer in place")
            #expect(host.panes.focusedLeaf == .companion)
            #expect(companion.visibilities.last == .visible(focused: true))
            #expect(host.screen.visibilities.last == .visible(focused: false))

            let sheet = UIViewController()
            let sheetField = UITextField()
            sheet.view.addSubview(sheetField)
            host.screen.present(sheet, animated: false)
            #expect(await waitForMainActorCondition(timeout: .seconds(3)) { sheetField.window === host.window })
            beginEditing(sheetField)
            #expect(host.screen.followsKeyboard, "a sheet's field is neither leaf")
            sheet.dismiss(animated: false)

            beginEditing(companion.field)
            #expect(!host.screen.followsKeyboard)
            host.screen.hidePanel()
            host.settle()
            #expect(host.screen.followsKeyboard, "closing the companion gives the keyboard back")
            #expect(host.panes.focusedLeaf == .primary)
        }
    }

    private func beginEditing(_ field: UITextField) {
        NotificationCenter.default.post(name: UITextField.textDidBeginEditingNotification, object: field)
    }
}

@MainActor
private func withCleanCompanionWidthAsync(_ body: () async throws -> Void) async rethrows {
    let defaults = UserDefaults.standard
    let key = AppPreferences.TrailingColumn.widthFractionKey
    let original = defaults.object(forKey: key)
    defer {
        if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    defaults.removeObject(forKey: key)
    try await body()
}
