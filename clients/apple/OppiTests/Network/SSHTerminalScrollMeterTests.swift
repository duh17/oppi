import Testing
@testable import Oppi

/// One terminal scroll gesture becomes one measurement: frames and hitches
/// counted from the display link's own timestamps, reported once the gesture
/// ends, tagged with what the terminal runs and where the scroll went.
@Suite("Terminal scroll meter")
@MainActor
struct SSHTerminalScrollMeterTests {
    private let frame = 1.0 / 120

    /// Ticks `count` 120 Hz frames from `start`, one of them (`lateIndex`) arriving `late` seconds late.
    private func drive(
        _ meter: SSHTerminalScrollMeter, from start: Double, count: Int, lateIndex: Int? = nil, late: Double = 0,
        scrolling: Bool = true, heldBytes: Int = 0, mode: TelemetryTag.TerminalMode = .shell
    ) -> (end: Double, gesture: AppTerminalScrollGesture?) {
        var time = start
        var gesture: AppTerminalScrollGesture?
        for index in 0..<count {
            time += frame + (index == lateIndex ? late : 0)
            gesture = meter.tick(
                timestamp: time, targetTimestamp: time + frame, scrolling: scrolling, heldBytes: heldBytes,
                mode: mode, path: .history
            ) ?? gesture
        }
        return (time, gesture)
    }

    @Test func aGestureIsReportedOnceWhenItEnds() throws {
        let meter = SSHTerminalScrollMeter()
        let during = drive(meter, from: 10, count: 30)
        #expect(during.gesture == nil, "Nothing is reported while the finger or the coasting continues")
        let end = try #require(drive(meter, from: during.end, count: 1, scrolling: false).gesture)
        // The first frame only starts the clock.
        #expect(end.frames == 29)
        #expect(end.hitches == 0)
        #expect(end.hitchRatio == 0)
        #expect(abs(end.durationMs - 29 * frame * 1_000) < 0.01)
        #expect(drive(meter, from: during.end, count: 3, scrolling: false).gesture == nil, "One event per gesture")
    }

    @Test func aLateFrameIsAHitchAndItsLatenessIsTheRatio() throws {
        let meter = SSHTerminalScrollMeter()
        let during = drive(meter, from: 10, count: 61, lateIndex: 30, late: 0.025)
        let end = try #require(drive(meter, from: during.end, count: 1, scrolling: false).gesture)
        #expect(end.hitches == 1)
        #expect(abs(end.worstFrameMs - (frame + 0.025) * 1_000) < 0.01)
        let expectedRatio = 0.025 * 1_000 / end.durationMs
        #expect(abs(end.hitchRatio - expectedRatio) < 0.001)
    }

    @Test func aSlightlyLateFrameIsNotAHitch() throws {
        let meter = SSHTerminalScrollMeter()
        let during = drive(meter, from: 10, count: 30, lateIndex: 10, late: frame * 0.4)
        let end = try #require(drive(meter, from: during.end, count: 1, scrolling: false).gesture)
        #expect(end.hitches == 0)
    }

    @Test func eachGestureStartsFresh() throws {
        let meter = SSHTerminalScrollMeter()
        let first = drive(meter, from: 10, count: 20, lateIndex: 5, late: 0.05)
        _ = try #require(drive(meter, from: first.end, count: 1, scrolling: false).gesture)
        // The link was off between gestures: the second starts its own clock.
        let second = drive(meter, from: 500, count: 20)
        let end = try #require(drive(meter, from: second.end, count: 1, scrolling: false).gesture)
        #expect(end.frames == 19)
        #expect(end.hitches == 0)
    }

    @Test func heldBytesAreWhatTheGestureKeptOffItsFrames() throws {
        let meter = SSHTerminalScrollMeter()
        _ = drive(meter, from: 10, count: 5, heldBytes: 1_000)
        let during = drive(meter, from: 10.1, count: 5, heldBytes: 5_000)
        let end = try #require(drive(meter, from: during.end, count: 1, scrolling: false, heldBytes: 9_000).gesture)
        #expect(end.deferredBytes == 8_000)
    }

    @Test func theModeNamesWhatTheTerminalRuns() {
        #expect(SSHTerminalScrollMeter.mode(isRex: true, command: "herdr") == .rex)
        #expect(SSHTerminalScrollMeter.mode(isRex: false, command: "/opt/bin/herdr --attach") == .herdr)
        #expect(SSHTerminalScrollMeter.mode(isRex: false, command: "tmux new -A -s main") == .tmux)
        #expect(SSHTerminalScrollMeter.mode(isRex: false, command: nil) == .shell)
        #expect(SSHTerminalScrollMeter.mode(isRex: false, command: "htop") == .shell)
        #expect(SSHTerminalScrollMeter.path(.history) == .history)
        #expect(SSHTerminalScrollMeter.path(.mouseWheel) == .wheel)
        #expect(SSHTerminalScrollMeter.path(.alternateKeys) == .keys)
    }
}
