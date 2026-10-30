import Testing
import UIKit
@testable import Oppi

@Suite("Application notices", .serialized)
@MainActor
struct ContentViewNoticeTests {
    /// The root's owner of the notice: `AppRootModals`, driven from `updateProperties()`.
    private final class RootHost: UIViewController {
        private let root: AppRootEnvironment
        private lazy var modals = AppRootModals(root: root, anchor: self)

        init(root: AppRootEnvironment) {
            self.root = root
            super.init(nibName: nil, bundle: nil)
            traitOverrides.appRootEnvironment = root
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            modals.anchorDidAppear()
        }

        override func updateProperties() {
            super.updateProperties()
            modals.update()
        }
    }

    @Test("file resolution notices have a neutral title")
    func fileResolutionNoticeUsesNeutralTitle() async throws {
        let root = makeTestAppRoot()
        let connection = root.coordinator.activeConnection
        let host = RootHost(root: root)
        // A window on the test host's scene: a scene-less window never runs `updateProperties`.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            connection.extensionToast = nil
            window.isHidden = true
        }
        host.view.layoutIfNeeded()
        await Task.yield()
        let message = "Could not resolve [[missing.mp4]]"
        connection.extensionToast = message
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if labelTexts(in: window).contains("Extension") || labelTexts(in: window).contains("Notice") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let labels = labelTexts(in: window)
        try #require(host.presentedViewController != nil, "The app root did not present its notice")
        #expect(labels.contains("Notice"), "File-resolution sheet has no neutral title: \(labels)")
        #expect(labels.contains(message), "The notice must show its message: \(labels)")
        #expect(!labels.contains("Extension"))
    }

    private func labelTexts(in view: UIView) -> [String] {
        let ownText = (view as? UILabel).flatMap(\.text).map { [$0] } ?? []
        return ownText + view.subviews.flatMap { labelTexts(in: $0) }
    }
}
