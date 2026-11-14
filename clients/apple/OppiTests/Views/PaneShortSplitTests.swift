import Testing
import UIKit
@testable import Oppi

/// Split Down on the iPad mini in portrait, with the lower pane dragged as
/// short as it goes: it keeps its minimum above the home indicator, its strip
/// stays out of the system's swipe-up zone, the launcher's choices never draw
/// over each other, and Web Page opens the browser with its address field up,
/// lifted over its column while the keyboard covers the pane.
@MainActor
@Suite("Pane short split", .serialized)
struct PaneShortSplitTests {
    /// The home indicator's zone on the iPad mini; a test window that has
    /// less (a window larger than an iPhone's screen) gets it added.
    static let homeIndicator: CGFloat = 20

    /// A window of `width` × 1133 with a Split Down whose lower pane is
    /// dragged down to its minimum.
    private func shortSplit(width: CGFloat = 744) throws -> (host: PaneTestHost, lower: PaneID, inset: CGFloat) {
        let host = PaneTestHost(width: width, height: 1133, inNavigation: true)
        let missing = max(0, Self.homeIndicator - host.panes.view.safeAreaInsets.bottom)
        host.act { host.panes.additionalSafeAreaInsets.bottom = missing }
        host.act { host.panes.split(axis: .column) }
        let lower = try #require(host.scenePanes.splitLeaves.first?.id)
        let divider = try #require(host.panes.view.subviews.lazy.compactMap { $0 as? PaneSplitDividerView }.first)
        for _ in 0..<40 { host.act { divider.accessibilityIncrement() } }
        return (host, lower, host.panes.view.safeAreaInsets.bottom)
    }

    private func leafView(_ host: PaneTestHost, _ id: PaneID) -> UIView? {
        host.panes.view.subviews.first { $0.accessibilityIdentifier == "pane.leaf.\(id.raw)" }
    }

    private func navigation(_ host: PaneTestHost, _ id: PaneID) -> UINavigationController? {
        host.panes.children.first { $0.view === leafView(host, id) } as? UINavigationController
    }

    private func descendants<T: UIView>(of view: UIView, as type: T.Type) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, as: type) }
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Minimum height and strip

    @Test func aSplitDownsLowerPaneKeepsItsMinimumAboveTheHomeIndicator() throws {
        let (host, lower, inset) = try shortSplit()
        defer { host.hide() }
        let leaf = try #require(leafView(host, lower))
        #expect(leaf.frame.maxY == 1133)
        #expect(leaf.frame.height - inset == PaneMinimumSize.list.height,
                "the launcher keeps its 280 pt above the home indicator: \(leaf.frame), inset \(inset)")
    }

    @Test func aLowerPaneDraggedToTheBottomCollapsesAboveTheHomeIndicator() throws {
        let (host, lower, inset) = try shortSplit()
        defer { host.hide() }
        let divider = try #require(host.panes.view.subviews.lazy.compactMap { $0 as? PaneSplitDividerView }.first)
        divider.onBegan?()
        divider.onChanged?(2000)
        host.act { divider.onEnded?() }
        let strip = try #require(
            host.panes.view.subviews.lazy.compactMap { $0 as? PaneStripView }.first,
            "dragged past half its minimum, the pane collapsed"
        )
        #expect(strip.accessibilityIdentifier == "pane.strip.\(lower.raw)")
        // A tap on the strip's 20 pt, just above the home indicator, expands it;
        // a touch in the home indicator's zone is never the strip's.
        let onStrip = CGPoint(x: 372, y: 1133 - inset - PanePresentation.collapsedThickness / 2)
        #expect(host.panes.view.hitTest(onStrip, with: nil) === strip, "the strip sits above the home indicator")
        let inZone = CGPoint(x: 372, y: 1133 - inset / 2)
        #expect(host.panes.view.hitTest(inZone, with: nil) !== strip, "the swipe-up zone is not the strip's")
    }

    // MARK: Launcher

    /// The owner's report: in a short lower pane the choices drew over each
    /// other. Wide, they go two by two; narrow, one column that scrolls.
    @Test(arguments: [744, 420] as [CGFloat])
    func aShortLaunchersChoicesNeverOverlap(width: CGFloat) throws {
        let (host, lower, _) = try shortSplit(width: width)
        defer { host.hide() }
        let launcher = try #require(navigation(host, lower)?.topViewController as? PaneLauncherViewController)
        launcher.view.layoutIfNeeded()
        let buttons = descendants(of: launcher.view, as: UIButton.self)
            .filter { $0.accessibilityIdentifier?.hasPrefix("pane.launcher.") == true }
        #expect(buttons.count == 4)
        let frames = buttons.map { $0.convert($0.bounds, to: launcher.view) }
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                #expect(!frame.intersects(other), "\(frame) overlaps \(other)")
            }
        }
        for button in buttons {
            let fitting = button.systemLayoutSizeFitting(
                CGSize(width: button.bounds.width, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            )
            #expect(button.bounds.height >= fitting.height - 0.5, "\(button.accessibilityIdentifier ?? "") is squeezed")
        }
        // Every choice can be reached: inside the content the pane scrolls.
        let scroll = try #require(descendants(of: launcher.view, as: UIScrollView.self).first)
        for button in buttons {
            #expect(button.convert(button.bounds, to: scroll).maxY <= scroll.contentSize.height + 0.5)
        }
    }

    // MARK: Web Page

    /// Web Page opens the browser in the pane, in place of the launcher and
    /// with no alert, its address field in the pane's bar. Go loads the
    /// address in place: the leaf's entry becomes the page and the field
    /// shows its host. The field takes the keyboard in `viewDidAppear`,
    /// which a unit-test window never delivers (not even to a plain root
    /// view controller); `BrowserPaneUITests` checks the focus in the app.
    @Test func webPageOpensTheBrowserWithItsAddressFieldUp() throws {
        let (host, lower, _) = try shortSplit()
        defer { host.hide() }
        let stack = try #require(navigation(host, lower))
        let launcher = try #require(stack.topViewController as? PaneLauncherViewController)
        let web = try #require(descendants(of: launcher.view, as: UIButton.self).first { $0.accessibilityIdentifier == "pane.launcher.web" })
        host.act { web.sendActions(for: .primaryActionTriggered) }
        spin()
        #expect(host.panes.presentedViewController == nil, "no address alert")
        let browser = try #require(stack.topViewController as? BrowserPaneViewController, "Web Page opened the browser")
        let field = try #require(descendants(of: stack.view, as: UITextField.self).first { $0.accessibilityIdentifier == "browser.address" })
        #expect(field.isDescendant(of: stack.navigationBar), "in the pane's bar, as Safari's")

        host.act { _ = field.becomeFirstResponder() }
        defer { field.resignFirstResponder() }
        field.text = "pane-browser.invalid/flow"
        host.act { _ = field.delegate?.textFieldShouldReturn?(field) }
        let url = try #require(URL(string: "https://pane-browser.invalid/flow"))
        #expect(host.scenePanes.topEntry(of: lower).route == .browser(url))
        #expect(stack.topViewController === browser, "the pane kept its browser")
        #expect(!field.isFirstResponder)
        #expect(field.text == "pane-browser.invalid", "at rest the field shows the host")
    }

    /// §1.3's keyboard rule: the keyboard would cover the short lower pane
    /// whole, so while it is up that pane takes its column and its field
    /// sits above the keyboard; the chat comes back as it falls.
    @Test func theKeyboardLiftsAShortLowerPanesFieldIntoView() throws {
        let (host, lower, inset) = try shortSplit()
        defer { host.hide() }
        let stack = try #require(navigation(host, lower))
        let leaf = try #require(leafView(host, lower))
        // A page's minimum is 320 pt, over the launcher's 280, above the home indicator.
        let restingTop = 1133 - PaneMinimumSize.browser.height - inset
        let web = try #require(descendants(of: stack.view, as: UIButton.self).first { $0.accessibilityIdentifier == "pane.launcher.web" })
        host.act { web.sendActions(for: .primaryActionTriggered) }
        spin()
        let field = try #require(descendants(of: stack.view, as: UITextField.self).first { $0.accessibilityIdentifier == "browser.address" })
        host.act { _ = field.becomeFirstResponder() }
        defer { field.resignFirstResponder() }
        try #require(field.isFirstResponder, "\(focusState(field, host))")

        let keyboard = CGRect(x: 0, y: 1133 - 340, width: 744, height: 340)
        host.act { postKeyboard(keyboard) }
        #expect(leaf.frame == CGRect(x: 0, y: 0, width: 744, height: 1133), "the field's pane takes its column")
        #expect(host.panes.primary.view.isHidden, "the chat waits under it")
        #expect(field.convert(field.bounds, to: nil).maxY <= keyboard.minY, "the field is above the keyboard")

        host.act { postKeyboard(CGRect(x: 0, y: 1133, width: 744, height: 340)) }
        #expect(leaf.frame.minY == restingTop)
        #expect(!host.panes.primary.view.isHidden)
    }

    /// Why a field might not have the keyboard, for a failure message.
    private func focusState(_ field: UITextField, _ host: PaneTestHost) -> String {
        let holder = PaneHostController.firstResponder(in: host.window).map { String(describing: type(of: $0)) } ?? "none"
        return "window \(field.window != nil), bounds \(field.bounds), key \(host.window.isKeyWindow), "
            + "presented \(String(describing: host.panes.presentedViewController)), first responder \(holder)"
    }

    private func postKeyboard(_ frame: CGRect) {
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: frame,
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
        ])
    }
}
