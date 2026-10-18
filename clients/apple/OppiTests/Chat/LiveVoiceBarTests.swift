import Testing
import UIKit
@testable import Oppi

@Suite("LiveVoiceBar")
@MainActor
struct LiveVoiceBarTests {
    @Test("Center state prefers an approval challenge summary")
    func presentsApprovalSummary() {
        #expect(LiveVoiceBarView.statusText(approvalSummary: "Allow the test command?") == "Allow the test command?")
        #expect(LiveVoiceBarView.statusText(approvalSummary: "   ") == "Listening")
        #expect(LiveVoiceBarView.statusText(approvalSummary: nil) == "Listening")
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

    @Test("Mute and End reach their owner actions, and the state reads as its text")
    func controlsReachOwnerActions() throws {
        let bar = LiveVoiceBarView(frame: CGRect(x: 0, y: 0, width: 390, height: 96))
        var mutes = 0
        var ends = 0
        bar.onMute = { mutes += 1 }
        bar.onEnd = { ends += 1 }
        bar.apply(statusText: "Pi says the tests passed", isMuted: true)
        bar.layoutIfNeeded()

        let mute = try #require(control(LiveVoiceBarView.muteIdentifier, in: bar) as? UIButton)
        let end = try #require(control(LiveVoiceBarView.endIdentifier, in: bar) as? UIButton)
        #expect(mute.accessibilityLabel == "Unmute")
        mute.sendActions(for: .touchUpInside)
        end.sendActions(for: .touchUpInside)
        #expect(mutes == 1)
        #expect(ends == 1)

        let state = try #require(control(LiveVoiceBarView.stateIdentifier, in: bar))
        #expect(state.isAccessibilityElement)
        #expect(state.accessibilityLabel == "Pi says the tests passed")
    }

    private func control(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews {
            if let match = control(identifier, in: child) { return match }
        }
        return nil
    }
}
