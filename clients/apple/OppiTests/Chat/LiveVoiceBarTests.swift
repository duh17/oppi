import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("LiveVoiceBar")
@MainActor
struct LiveVoiceBarTests {
    @Test("Mute, state, and End keep stable identifiers")
    func exposesStableIdentifiers() {
        #expect(LiveVoiceBar.muteIdentifier == "chat.liveVoice.mute")
        #expect(LiveVoiceBar.endIdentifier == "chat.liveVoice.end")
        #expect(LiveVoiceBar.stateIdentifier == "chat.liveVoice.state")
    }

    @Test("Center state prefers an approval challenge summary")
    func presentsApprovalSummary() {
        #expect(LiveVoiceBar.statusText(approvalSummary: "Allow the test command?") == "Allow the test command?")
        #expect(LiveVoiceBar.statusText(approvalSummary: "   ") == "Listening")
        #expect(LiveVoiceBar.statusText(approvalSummary: nil) == "Listening")
    }

    @Test("Footer keeps the composer until a live call is active")
    func footerChoosesComposerUntilLive() {
        #expect(!ChatView.showsLiveVoiceBar(isLive: false, isStopped: false))
        #expect(ChatView.showsLiveVoiceBar(isLive: true, isStopped: false))
        #expect(!ChatView.showsLiveVoiceBar(isLive: false, isStopped: true))
        #expect(!ChatView.showsLiveVoiceBar(isLive: false, isStopped: false, lastError: nil))
    }

    @Test("Footer keeps the Live Voice bar when start failed closed with an error")
    func footerKeepsBarForStartErrorUntilEnd() {
        #expect(ChatView.showsLiveVoiceBar(
            isLive: false,
            isStopped: false,
            lastError: "Create session HTTP 500: boom"
        ))
        #expect(ChatView.showsLiveVoiceBar(
            isLive: false,
            isStopped: true,
            lastError: "Live Voice ASR is unavailable"
        ))
    }

    @Test("Stopped focused session still keeps the Live Voice End affordance")
    func stoppedSessionKeepsLiveVoiceEnd() {
        #expect(ChatView.showsLiveVoiceBar(isLive: true, isStopped: true))
    }

    @Test("Hosted bar mounts Mute, center state, and End")
    func hostedBarMounts() {
        var muted = false
        var ended = false
        let controller = UIHostingController(
            rootView: LiveVoiceBar(
                statusText: "Listening",
                isMuted: false,
                onMute: { muted = true },
                onEnd: { ended = true }
            )
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 180)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(controller.view.bounds.width == 390)
        #expect(!muted)
        #expect(!ended)

        window.isHidden = true
        window.rootViewController = nil
    }
}
