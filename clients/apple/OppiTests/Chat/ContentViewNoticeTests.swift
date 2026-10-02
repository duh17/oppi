import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Application notices", .serialized)
@MainActor
struct ContentViewNoticeTests {
    @Test("file resolution notices have a neutral title")
    func fileResolutionNoticeUsesNeutralTitle() async throws {
        let connection = ServerConnection()
        let coordinator = ConnectionCoordinator(
            serverStore: ServerStore(), lanDiscovery: LANDiscovery(browsesBonjour: false)
        )
        let navigation = AppNavigation()
        let host = UIHostingController(rootView: ContentView()
            .environment(connection).environment(coordinator).environment(navigation))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
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
        try #require(host.presentedViewController != nil, "ContentView did not present its notice")
        #expect(labels.contains("Notice"), "File-resolution sheet has no neutral title: \(labels)")
        #expect(!labels.contains("Extension"))
    }

    private func labelTexts(in view: UIView) -> [String] {
        let ownText = (view as? UILabel).flatMap(\.text).map { [$0] } ?? []
        return ownText + view.subviews.flatMap { labelTexts(in: $0) }
    }
}
