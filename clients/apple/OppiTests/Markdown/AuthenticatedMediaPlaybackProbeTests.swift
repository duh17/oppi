import AVKit
import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Authenticated media DEBUG playback probe identity", .serialized)
@MainActor
struct AuthenticatedMediaPlaybackProbeTests {
    @Test("probe reports the receiving controller player, not another model's player")
    func probeReportsReceivingControllerPlayerNotForeignModel() {
        AuthenticatedMediaE2EPlaybackProbe.testingForceEnabled = true
        defer { AuthenticatedMediaE2EPlaybackProbe.testingForceEnabled = false }

        let host = hostTwoPlayers()
        defer { host.window.isHidden = true }

        AuthenticatedMediaE2EPlaybackProbe.install(on: host.controllerA, model: host.modelB)
        let value = tryRequireProbe(host.controllerA)
        let pidA = playerID(host.playerA)
        let pidB = playerID(host.playerB)
        let midB = modelID(host.modelB)

        #expect(value.contains("pid=\(pidA)"), "probe=\(value)")
        #expect(!value.contains("pid=\(pidB)"), "stamped foreign pid. probe=\(value)")
        #expect(!value.contains("mid=\(midB)"), "stamped foreign model. probe=\(value)")
        #expect(value.contains("mid=none"), "probe=\(value)")
    }

    @Test("bindPresentedFullscreen does not stamp the initiating model onto an unrelated controller")
    func bindPresentedFullscreenDoesNotStampUnrelatedController() {
        AuthenticatedMediaE2EPlaybackProbe.testingForceEnabled = true
        defer { AuthenticatedMediaE2EPlaybackProbe.testingForceEnabled = false }

        let host = hostTwoPlayers()
        defer { host.window.isHidden = true }

        AuthenticatedMediaE2EPlaybackProbe.install(on: host.controllerA, model: host.modelA)
        AuthenticatedMediaE2EPlaybackProbe.install(on: host.controllerB, model: host.modelB)

        let pidA = playerID(host.playerA)
        let pidB = playerID(host.playerB)
        let midA = modelID(host.modelA)

        AuthenticatedMediaE2EPlaybackProbe.bindPresentedFullscreen(
            from: host.controllerA,
            destination: host.controllerB
        )

        let valueA = tryRequireProbe(host.controllerA)
        let valueB = tryRequireProbe(host.controllerB)
        #expect(valueA.contains("pid=\(pidA)"), "probeA=\(valueA)")
        #expect(valueB.contains("pid=\(pidB)"), "probeB=\(valueB)")
        #expect(!valueB.contains("pid=\(pidA)"), "root-tree misattribution. probeB=\(valueB)")
        #expect(!valueB.contains("mid=\(midA)"), "initiating model stamped on B. probeB=\(valueB)")
        #expect(valueA.contains("fs=0"), "inline controller inferred fullscreen. probeA=\(valueA)")
        #expect(valueB.contains("fs=0"), "unrelated controller inferred fullscreen. probeB=\(valueB)")
    }

    @Test("overlay fs comes from the receiving controller, not the model's ownership flag")
    func overlayFullscreenIsNotCopiedFromModelOwnership() {
        AuthenticatedMediaE2EPlaybackProbe.testingForceEnabled = true
        defer { AuthenticatedMediaE2EPlaybackProbe.testingForceEnabled = false }

        let host = hostTwoPlayers()
        defer { host.window.isHidden = true }

        AuthenticatedMediaE2EPlaybackProbe.install(on: host.controllerA, model: host.modelA)
        host.modelA.setFullScreen(true)
        AuthenticatedMediaE2EPlaybackProbe.install(on: host.controllerA, model: host.modelA)

        let overlay = tryRequireProbe(host.controllerA)
        #expect(overlay.contains("fs=0"), "copied model fs onto inline controller. probe=\(overlay)")
        #expect(host.modelA.debugPlaybackProbeForTesting.contains("fs=1"))
        #expect(overlay.contains("pid=\(playerID(host.playerA))"), "probe=\(overlay)")

        // Merely naming a destination must not report fullscreen. The player's
        // own overlay has to move there, as it does during AVKit's transition.
        AuthenticatedMediaE2EPlaybackProbe.bindPresentedFullscreen(
            from: host.controllerA,
            destination: host.controllerB
        )
        #expect(tryRequireProbe(host.controllerA).contains("fs=0"))
        guard let contentOverlay = host.controllerA.contentOverlayView,
              let inlineHost = contentOverlay.superview else {
            Issue.record("Missing AVKit content overlay")
            return
        }
        host.controllerB.view.addSubview(contentOverlay)
        let presented = tryRequireProbe(host.controllerA)
        #expect(presented.contains("fs=1"), "moved overlay must report fs=1. probe=\(presented)")
        #expect(presented.contains("pid=\(playerID(host.playerA))"), "probe=\(presented)")
        inlineHost.addSubview(contentOverlay)
        #expect(tryRequireProbe(host.controllerA).contains("fs=0"), "dismiss must clear fullscreen")
    }

    @Test("uninstall and removeFromSuperview invalidate the display link")
    func uninstallAndRemoveFromSuperviewInvalidateDisplayLink() {
        AuthenticatedMediaE2EPlaybackProbe.testingForceEnabled = true
        defer { AuthenticatedMediaE2EPlaybackProbe.testingForceEnabled = false }

        let host = hostTwoPlayers()
        defer { host.window.isHidden = true }

        AuthenticatedMediaE2EPlaybackProbe.install(on: host.controllerA, model: host.modelA)
        #expect(AuthenticatedMediaE2EPlaybackProbe.debugHasProbeView(on: host.controllerA))
        #expect(AuthenticatedMediaE2EPlaybackProbe.debugIsDisplayLinkActive(on: host.controllerA))

        AuthenticatedMediaE2EPlaybackProbe.uninstall(from: host.controllerA)
        #expect(!AuthenticatedMediaE2EPlaybackProbe.debugHasProbeView(on: host.controllerA))
        #expect(!AuthenticatedMediaE2EPlaybackProbe.debugIsDisplayLinkActive(on: host.controllerA))

        AuthenticatedMediaE2EPlaybackProbe.install(on: host.controllerB, model: host.modelB)
        #expect(AuthenticatedMediaE2EPlaybackProbe.debugIsDisplayLinkActive(on: host.controllerB))
        host.controllerB.contentOverlayView?.subviews.forEach { $0.removeFromSuperview() }
        #expect(!AuthenticatedMediaE2EPlaybackProbe.debugIsDisplayLinkActive(on: host.controllerB))
        #expect(!AuthenticatedMediaE2EPlaybackProbe.debugHasProbeView(on: host.controllerB))
    }
}

@MainActor
private struct HostedProbePair {
    let window: UIWindow
    let modelA: AuthenticatedMediaPlayerModel
    let modelB: AuthenticatedMediaPlayerModel
    let playerA: AVPlayer
    let playerB: AVPlayer
    let controllerA: AVPlayerViewController
    let controllerB: AVPlayerViewController
}

@MainActor
private func hostTwoPlayers() -> HostedProbePair {
    let parent = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = parent
    window.makeKeyAndVisible()

    let modelA = AuthenticatedMediaPlayerModel()
    let playerA = modelA.debugInstallStandalonePlayerForTesting()
    let controllerA = AVPlayerViewController()
    controllerA.player = playerA

    let modelB = AuthenticatedMediaPlayerModel()
    let playerB = modelB.debugInstallStandalonePlayerForTesting()
    let controllerB = AVPlayerViewController()
    controllerB.player = playerB

    embed(controllerA, in: parent, origin: CGPoint(x: 0, y: 40))
    embed(controllerB, in: parent, origin: CGPoint(x: 0, y: 280))
    parent.view.layoutIfNeeded()
    return HostedProbePair(
        window: window,
        modelA: modelA,
        modelB: modelB,
        playerA: playerA,
        playerB: playerB,
        controllerA: controllerA,
        controllerB: controllerB
    )
}

@MainActor
private func embed(_ controller: AVPlayerViewController, in parent: UIViewController, origin: CGPoint) {
    parent.addChild(controller)
    controller.view.frame = CGRect(origin: origin, size: CGSize(width: 360, height: 200))
    parent.view.addSubview(controller.view)
    controller.didMove(toParent: parent)
    controller.view.layoutIfNeeded()
}

@MainActor
private func tryRequireProbe(_ controller: AVPlayerViewController) -> String {
    AuthenticatedMediaE2EPlaybackProbe.debugProbeValue(on: controller) ?? "missing"
}

private func playerID(_ player: AVPlayer) -> String {
    String(UInt(bitPattern: ObjectIdentifier(player)), radix: 16)
}

private func modelID(_ model: AuthenticatedMediaPlayerModel) -> String {
    String(UInt(bitPattern: ObjectIdentifier(model)), radix: 16)
}
