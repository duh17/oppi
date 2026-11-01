import Foundation
import Testing
import UIKit
@testable import Oppi

/// The outline a chat opens: a classic session switches between its timeline
/// and its tree; a durable conversation has no in-place tree (the server
/// refuses it), so its outline is the timeline alone, with no switch to a tree
/// that could only fail.
@Suite("Chat outline per engine")
@MainActor
struct ChatOutlineEngineTests {
    @Test("A classic chat's outline offers Timeline and Tree; a durable chat's outline is the timeline with no switch",
          arguments: [(SessionEngine.classic, true), (.durable, false)])
    func theTreeSwitchFollowsTheEngine(engine: SessionEngine, offersTree: Bool) throws {
        let sessionId = "outline-\(engine)"
        let (connection, _) = makeTestConnection(sessionId: sessionId)
        connection.setAPIClientForTesting(nil)
        var session = makeTestSession(id: sessionId, workspaceId: "ws-outline", status: .ready)
        session.engine = engine
        connection.sessionStore.upsert(session)
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: AppNavigation())

        let outline = chat.makeOutlineController()
        let window = makeSceneWindow()
        window.rootViewController = UINavigationController(rootViewController: outline)
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }
        outline.view.layoutIfNeeded()

        // A switch the outline draws, if any: a durable outline may hide it or never build it.
        let switcher = Self.segmentedControls(in: outline.view).first { Self.titles(of: $0) == ["Timeline", "Tree"] }
        #expect((switcher.map { Self.isDrawn($0, in: outline.view) } ?? false) == offersTree)
        if offersTree {
            #expect(switcher?.selectedSegmentIndex == 0, "the outline opens on the timeline")
        }
    }

    private static func segmentedControls(in view: UIView) -> [UISegmentedControl] {
        let own = (view as? UISegmentedControl).map { [$0] } ?? []
        return own + view.subviews.flatMap(segmentedControls)
    }

    private static func titles(of control: UISegmentedControl) -> [String?] {
        (0..<control.numberOfSegments).map(control.titleForSegment)
    }

    /// Shown on screen: neither the view nor anything between it and `root` is hidden.
    private static func isDrawn(_ view: UIView, in root: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current, candidate !== root {
            if candidate.isHidden || candidate.alpha == 0 { return false }
            current = candidate.superview
        }
        return current === root
    }
}
