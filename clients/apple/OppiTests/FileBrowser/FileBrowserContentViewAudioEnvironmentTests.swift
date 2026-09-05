import SwiftUI
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("File browser audio environment")
struct FileBrowserAudioEnvironmentTests {
    @Test func hostingWithoutAudioPlayerServiceDoesNotCrash() {
        let view = FileBrowserContentView(
            workspaceId: "ws-1",
            filePath: "AGENTS.md",
            fileName: "AGENTS.md",
            sessionId: "session-1"
        )
        let host = UIHostingController(rootView: view)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        #expect(host.view.window === window)
        #expect(host.view.bounds.width == 390)
        #expect(host.view.bounds.height == 844)
    }
}
