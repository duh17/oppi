import Testing
@testable import Oppi

@Suite("BackgroundConnectionPlan")
struct BackgroundConnectionPlanTests {
    /// The Mac keeps running while hidden or behind another app: working agents,
    /// live audio, or nothing at all, its connections stay open and no
    /// background task holds up a quit.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func appThatKeepsRunningKeepsItsConnections(hasActiveAgent: Bool, hasLiveAudio: Bool) {
        #expect(BackgroundConnectionPlan.resolve(
            suspendsInBackground: false,
            hasActiveAgent: hasActiveAgent,
            hasLiveAudio: hasLiveAudio
        ) == .keepOpen)
    }

    @Test func suspendingAppHoldsSocketsWhileAgentsWork() {
        #expect(BackgroundConnectionPlan.resolve(
            suspendsInBackground: true, hasActiveAgent: true, hasLiveAudio: true
        ) == .keepAliveForAgents)
    }

    @Test func suspendingAppDrainsLiveAudioWhenNoAgentWorks() {
        #expect(BackgroundConnectionPlan.resolve(
            suspendsInBackground: true, hasActiveAgent: false, hasLiveAudio: true
        ) == .drainLiveAudio)
    }

    @Test func idleSuspendingAppClosesAfterGrace() {
        #expect(BackgroundConnectionPlan.resolve(
            suspendsInBackground: true, hasActiveAgent: false, hasLiveAudio: false
        ) == .closeAfterGrace)
    }
}
