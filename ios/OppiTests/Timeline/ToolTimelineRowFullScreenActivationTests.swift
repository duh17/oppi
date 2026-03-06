import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Tool timeline row full-screen activation")
struct ToolTimelineRowFullScreenActivationTests {
    private struct HostHarness {
        let window: UIWindow
        let host: UIViewController
    }

    @Test("bash output activation opens full screen instead of copying")
    func bashOutputActivationOpensFullScreen() throws {
        let harness = makeHostHarness()
        let host = harness.host
        let view = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .bash(command: "echo hi", output: "hi", unwrapped: true),
            copyCommandText: "echo hi",
            copyOutputText: "hi",
            isExpanded: true
        ))

        host.view.addSubview(view)
        view.frame = host.view.bounds
        host.view.layoutIfNeeded()

        view.performOutputActivation()

        let presented = try #require(host.presentedViewController as? FullScreenCodeViewController)
        #expect(presented.modalPresentationStyle == .pageSheet)

        host.dismiss(animated: false)
        harness.window.isHidden = true
    }

    @Test("expanded code activation opens full screen")
    func expandedCodeActivationOpensFullScreen() throws {
        let harness = makeHostHarness()
        let host = harness.host
        let view = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .code(text: "struct App {}", language: .swift, startLine: 1, filePath: "App.swift"),
            copyCommandText: "read App.swift",
            copyOutputText: "struct App {}",
            toolNamePrefix: "read",
            isExpanded: true
        ))

        host.view.addSubview(view)
        view.frame = host.view.bounds
        host.view.layoutIfNeeded()

        view.performExpandedActivation()

        let presented = try #require(host.presentedViewController as? FullScreenCodeViewController)
        #expect(presented.modalPresentationStyle == .pageSheet)

        host.dismiss(animated: false)
        harness.window.isHidden = true
    }

    private func makeHostHarness() -> HostHarness {
        let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            fatalError("Missing UIWindowScene for ToolTimelineRowFullScreenActivationTests")
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.loadViewIfNeeded()
        return HostHarness(window: window, host: host)
    }
}
