import Foundation
import Testing
import UIKit
@testable import Oppi

/// The outline a chat opens switches between its timeline and its tree on
/// either engine: a classic session's tree is its Pi session's, a durable
/// session's is its branches.
@Suite("Chat outline per engine")
@MainActor
struct ChatOutlineEngineTests {
    @Test("A chat's outline offers Timeline and Tree on either engine",
          arguments: [SessionEngine.classic, .durable])
    func theOutlineOffersTheTree(engine: SessionEngine) async throws {
        let sessionId = "outline-\(engine)"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        connection.setAPIClientForTesting(nil)
        var session = makeTestSession(id: sessionId, workspaceId: "ws-outline", status: .ready)
        session.engine = engine
        connection.sessionStore.upsert(session)
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: SceneNavigation())

        let outline = chat.makeOutlineController()
        let window = makeSceneWindow()
        window.rootViewController = UINavigationController(rootViewController: outline)
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }
        outline.view.layoutIfNeeded()

        let switcher = Self.segmentedControls(in: outline.view).first { Self.titles(of: $0) == ["Timeline", "Tree"] }
        #expect(switcher.map { Self.isDrawn($0, in: outline.view) } == true)
        #expect(switcher?.selectedSegmentIndex == 0, "the outline opens on the timeline")
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
