import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Full-screen viewer presentation policy")
struct FullScreenViewerPresentationPolicyTests {
    @Test("presented FullScreenCodeViewController is selected for dismiss")
    func presentedFullScreenCodeViewControllerIsSelectedForDismiss() throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let overlay = makeViewer()
        harness.root.present(overlay, animated: false)

        let selected = FullScreenViewerPresentationPolicy.coveringPresentedDocumentOverlay(
            from: harness.root
        )
        #expect(selected === overlay)
    }

    @Test("presented hosting parent that contains a viewer is selected for dismiss")
    func presentedHostingParentThatContainsViewerIsSelectedForDismiss() throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let host = UIViewController()
        let viewer = makeViewer()
        embed(viewer, in: host)
        harness.root.present(host, animated: false)

        let selected = FullScreenViewerPresentationPolicy.coveringPresentedDocumentOverlay(
            from: harness.root
        )
        #expect(selected === host)
        #expect(selected !== viewer)
    }

    @Test("nested hosting parent that contains a viewer is selected for dismiss")
    func nestedHostingParentThatContainsViewerIsSelectedForDismiss() throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let host = UIViewController()
        let wrapper = UIViewController()
        embed(wrapper, in: host)
        let viewer = makeViewer()
        embed(viewer, in: wrapper)
        harness.root.present(host, animated: false)

        let selected = FullScreenViewerPresentationPolicy.coveringPresentedDocumentOverlay(
            from: harness.root
        )
        #expect(selected === host)
    }

    @Test("presented navigation stack that contains a viewer is selected for dismiss")
    func presentedNavigationStackThatContainsViewerIsSelectedForDismiss() throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let viewer = makeViewer()
        let navigation = UINavigationController(rootViewController: viewer)
        harness.root.present(navigation, animated: false)

        let selected = FullScreenViewerPresentationPolicy.coveringPresentedDocumentOverlay(
            from: harness.root
        )
        #expect(selected === navigation)
    }

    @Test("non-presented embedded viewer is not selected for dismiss")
    func nonPresentedEmbeddedViewerIsNotSelectedForDismiss() throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let viewer = makeViewer(presentationMode: .embedded(onDismiss: {}))
        embed(viewer, in: harness.root)

        let selected = FullScreenViewerPresentationPolicy.coveringPresentedDocumentOverlay(
            from: harness.root
        )
        #expect(selected == nil)
    }

    @Test("viewer pushed on the root navigation stack is not selected for dismiss")
    func viewerPushedOnRootNavigationStackIsNotSelectedForDismiss() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let chat = UIViewController()
        let navigation = UINavigationController(rootViewController: chat)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let viewer = makeViewer(presentationMode: .embedded(onDismiss: {}))
        navigation.pushViewController(viewer, animated: false)

        let selected = FullScreenViewerPresentationPolicy.coveringPresentedDocumentOverlay(
            from: navigation
        )
        #expect(selected == nil)
    }

    @Test("presented composer, browser, or media stand-in is not selected for dismiss")
    func presentedNonDocumentOverlayIsNotSelectedForDismiss() throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let composer = UIViewController()
        harness.root.present(composer, animated: false)

        let selected = FullScreenViewerPresentationPolicy.coveringPresentedDocumentOverlay(
            from: harness.root
        )
        #expect(selected == nil)
    }

    @Test("first covering overlay is selected when another controller is presented above it")
    func firstCoveringOverlayIsSelectedWhenAnotherControllerIsPresentedAboveIt() throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let overlay = makeViewer()
        harness.root.present(overlay, animated: false)
        let above = UIViewController()
        overlay.present(above, animated: false)

        let selected = FullScreenViewerPresentationPolicy.coveringPresentedDocumentOverlay(
            from: harness.root
        )
        #expect(selected === overlay)
        #expect(selected !== above)
    }

    @Test("covering presented viewer is dismissed then navigation runs")
    func coveringPresentedViewerIsDismissedThenNavigationRuns() async throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let overlay = makeViewer()
        harness.root.present(overlay, animated: false)
        #expect(harness.root.presentedViewController === overlay)

        var navigated = false
        await FullScreenViewerPresentationPolicy.dismissCoveringOverlayThenNavigate(
            from: harness.root,
            animated: false
        ) {
            navigated = true
        }

        #expect(harness.root.presentedViewController == nil)
        #expect(navigated)
    }

    @Test("embedded viewer is left in place and navigation still runs")
    func embeddedViewerIsLeftInPlaceAndNavigationStillRuns() async throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let viewer = makeViewer(presentationMode: .embedded(onDismiss: {}))
        embed(viewer, in: harness.root)

        var navigated = false
        await FullScreenViewerPresentationPolicy.dismissCoveringOverlayThenNavigate(
            from: harness.root,
            animated: false
        ) {
            navigated = true
        }

        #expect(viewer.parent === harness.root)
        #expect(navigated)
    }

    @Test("stale token after dismiss does not navigate")
    func staleTokenAfterDismissDoesNotNavigate() async throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let overlay = makeViewer()
        harness.root.present(overlay, animated: false)

        var navigated = false
        await FullScreenViewerPresentationPolicy.dismissCoveringOverlayThenNavigate(
            from: harness.root,
            animated: false,
            shouldNavigate: { false }
        ) {
            navigated = true
        }

        #expect(harness.root.presentedViewController == nil)
        #expect(!navigated)
    }

    @Test("session and file resource opens share the dismiss-then-navigate seam")
    func sessionAndFileResourceOpensShareTheDismissThenNavigateSeam() async throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        var opened: [String] = []
        func openResource(_ kind: String) async {
            await FullScreenViewerPresentationPolicy.dismissCoveringOverlayThenNavigate(
                from: harness.root,
                animated: false
            ) {
                opened.append(kind)
            }
        }

        harness.root.present(makeViewer(), animated: false)
        await openResource("session")
        #expect(harness.root.presentedViewController == nil)

        harness.root.present(makeViewer(), animated: false)
        await openResource("file")
        #expect(harness.root.presentedViewController == nil)

        #expect(opened == ["session", "file"])
    }

    @Test("non-document presented overlay is left in place when navigating")
    func nonDocumentPresentedOverlayIsLeftInPlaceWhenNavigating() async throws {
        let harness = OverlayHarness.make()
        defer { harness.teardown() }

        let composer = UIViewController()
        harness.root.present(composer, animated: false)

        var navigated = false
        await FullScreenViewerPresentationPolicy.dismissCoveringOverlayThenNavigate(
            from: harness.root,
            animated: false
        ) {
            navigated = true
        }

        #expect(harness.root.presentedViewController === composer)
        #expect(navigated)
    }
}

@MainActor
private struct OverlayHarness {
    let window: UIWindow
    let root: UIViewController

    static func make() -> OverlayHarness {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            fatalError("Missing UIWindowScene for FullScreenViewerPresentationPolicyTests")
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
        return OverlayHarness(window: window, root: root)
    }

    func teardown() {
        root.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private func makeViewer(
    presentationMode: FullScreenCodeViewController.PresentationMode = .sheet
) -> FullScreenCodeViewController {
    FullScreenCodeViewController(
        content: .plainText(content: "note", filePath: "note.txt"),
        presentationMode: presentationMode
    )
}

@MainActor
private func embed(_ child: UIViewController, in parent: UIViewController) {
    parent.addChild(child)
    parent.view.addSubview(child.view)
    child.view.frame = parent.view.bounds
    child.didMove(toParent: parent)
}
