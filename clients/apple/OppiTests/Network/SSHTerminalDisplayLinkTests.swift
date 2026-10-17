import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal display link", .serialized)
@MainActor
struct SSHTerminalDisplayLinkTests {
    @Test func policyRunsOnlyWhileThereIsWorkAndRaisesRateWhileScrolling() {
        let idle = SSHTerminalDisplayLinkPolicy.resolve(
            hasWindow: true, sceneActive: true,
            needsFullPaint: false, pictureChanged: false, renderHeld: false, scrolling: false
        )
        #expect(!idle.running)
        #expect(!idle.highFrameRate)

        let output = SSHTerminalDisplayLinkPolicy.resolve(
            hasWindow: true, sceneActive: true,
            needsFullPaint: false, pictureChanged: true, renderHeld: false, scrolling: false
        )
        #expect(output.running)
        #expect(!output.highFrameRate)

        let held = SSHTerminalDisplayLinkPolicy.resolve(
            hasWindow: true, sceneActive: true,
            needsFullPaint: false, pictureChanged: false, renderHeld: true, scrolling: false
        )
        #expect(held.running)

        let scrolling = SSHTerminalDisplayLinkPolicy.resolve(
            hasWindow: true, sceneActive: true,
            needsFullPaint: false, pictureChanged: false, renderHeld: false, scrolling: true
        )
        #expect(scrolling.running)
        #expect(scrolling.highFrameRate)

        let background = SSHTerminalDisplayLinkPolicy.resolve(
            hasWindow: true, sceneActive: false,
            needsFullPaint: true, pictureChanged: true, renderHeld: true, scrolling: true
        )
        #expect(!background.running)

        let detached = SSHTerminalDisplayLinkPolicy.resolve(
            hasWindow: false, sceneActive: true,
            needsFullPaint: true, pictureChanged: true, renderHeld: true, scrolling: true
        )
        #expect(!detached.running)
    }

    @Test func ptyOutputMarksTheGridDirtySoTheDisplayLinkCanWake() throws {
        let channel = try SSHTerminalChannel()
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedDisplayGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        grid.needsPaint = false
        channel.engine.receive(Data("x".utf8))
        #expect(grid.needsPaint, "PTY bytes must dirty the grid so an idle-paused display link restarts")
    }
}

@MainActor
private final class MountedDisplayGrid {
    let window: UIWindow
    let grid: SSHTerminalGridView

    init(_ grid: SSHTerminalGridView) throws {
        self.grid = grid
        let host = UIViewController()
        grid.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: host.view.topAnchor),
            grid.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
    }

    func dismiss() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
