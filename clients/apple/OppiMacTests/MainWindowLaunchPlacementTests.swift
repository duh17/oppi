import CoreGraphics
import Testing
@testable import Oppi

@Suite("MainWindowLaunchPlacement")
struct MainWindowLaunchPlacementTests {
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let secondary = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    @Test func leavesFrameOnActiveDisplayAlone() {
        let frame = CGRect(x: 100, y: 80, width: 1180, height: 870)
        #expect(!MainWindowLaunchPlacement.shouldCenter(frame: frame, visibleFrames: [main]))
    }

    @Test func leavesFrameOnSecondaryDisplayAlone() {
        let frame = CGRect(x: 1600, y: 100, width: 1180, height: 870)
        #expect(!MainWindowLaunchPlacement.shouldCenter(
            frame: frame,
            visibleFrames: [main, secondary]
        ))
    }

    @Test func centersWhenRestoredFrameIsOffEveryDisplay() {
        let frame = CGRect(x: -3600, y: 0, width: 3440, height: 1440)
        #expect(MainWindowLaunchPlacement.shouldCenter(frame: frame, visibleFrames: [main]))
    }

    @Test func centersWhenNoDisplaysAreConnected() {
        let frame = CGRect(x: 100, y: 80, width: 1180, height: 870)
        #expect(MainWindowLaunchPlacement.shouldCenter(frame: frame, visibleFrames: []))
    }
}
