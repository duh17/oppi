import Testing
import UIKit
@testable import Oppi

/// The chat timeline's frames are counted while it scrolls or a turn puts new
/// content on it, split by activity, and reported once per visit with hitch time
/// and duration, so hitch time per second pools over visits. A turn that changes
/// nothing stops the display link.
@Suite("Chat timeline frame meter")
@MainActor
struct ChatTimelineFrameMeterTests {
    private let frame = 1.0 / 120

    /// Ticks `count` 120 Hz frames from `start` toward `activity`, one of them
    /// (`lateIndex`) arriving `late` seconds late. With `content`, each frame
    /// brings new timeline content. Returns the last tick's time.
    @discardableResult
    private func drive(
        _ meter: ChatTimelineFrameMeter, from start: Double, count: Int,
        activity: TelemetryTag.TimelineActivity?, lateIndex: Int? = nil, late: Double = 0,
        content: Bool = true
    ) -> Double {
        var time = start
        for index in 0..<count {
            time += frame + (index == lateIndex ? late : 0)
            if content { meter.contentChanged(at: time) }
            meter.tick(timestamp: time, targetTimestamp: time + frame, activity: activity)
        }
        return time
    }

    @Test func aVisitReportsHitchTimeAndDurationPerActivity() throws {
        let meter = ChatTimelineFrameMeter()
        let scrolled = drive(meter, from: 10, count: 61, activity: .scroll, lateIndex: 30, late: 0.025)
        drive(meter, from: scrolled, count: 31, activity: .stream)

        let events = meter.takeVisit(items: 812)
        #expect(events.map(\.timelineActivity) == [.scroll, .stream])
        let scroll = try #require(events.first)
        // The first frame of each activity only starts its clock.
        #expect(scroll.frames == 60)
        #expect(scroll.hitches == 1)
        #expect(abs(scroll.hitchMs - 25) < 0.01)
        #expect(abs(scroll.worstFrameMs - (frame + 0.025) * 1_000) < 0.01)
        #expect(abs(scroll.durationMs - (60 * frame + 0.025) * 1_000) < 0.01)
        #expect(scroll.items == 812)
        let stream = try #require(events.last)
        #expect(stream.frames == 30 && stream.hitches == 0 && stream.hitchMs == 0)
        #expect(meter.takeVisit(items: 812).isEmpty, "A visit is reported once")
    }

    @Test func timeWithNothingToMeasureIsNotAFrame() throws {
        let meter = ChatTimelineFrameMeter()
        let first = drive(meter, from: 10, count: 11, activity: .stream)
        // Idle in between: the next streaming frame starts the clock again.
        let idle = drive(meter, from: first, count: 5, activity: nil)
        drive(meter, from: idle + 30, count: 11, activity: .stream)

        let stream = try #require(meter.takeVisit(items: 1).first)
        #expect(stream.frames == 20)
        #expect(stream.hitches == 0)
        #expect(stream.worstFrameMs < 10)
    }

    @Test func switchingActivityDoesNotCountTheGapTowardEither() throws {
        let meter = ChatTimelineFrameMeter()
        let streamed = drive(meter, from: 10, count: 11, activity: .stream)
        let scrolled = drive(meter, from: streamed, count: 11, activity: .scroll)
        // Back to streaming after a long scroll: the scroll time is not a stream frame.
        drive(meter, from: scrolled + 2, count: 11, activity: .stream)

        let events = meter.takeVisit(items: 1)
        let stream = try #require(events.first { $0.timelineActivity == .stream })
        #expect(stream.frames == 20)
        #expect(stream.hitches == 0)
    }

    @Test func aTurnThatStopsChangingStopsTheLinkAndCountsOnlyItsActiveSpan() throws {
        let meter = ChatTimelineFrameMeter()
        let lastContent = drive(meter, from: 10, count: 21, activity: .stream)

        // The turn runs on (a long tool call) but nothing new lands.
        var time = lastContent
        var running = true
        while running {
            time += frame
            running = meter.tick(timestamp: time, targetTimestamp: time + frame, activity: .stream)
        }
        #expect(time - lastContent >= ChatTimelineFrameMeter.idleTimeout, "The link outlives the content by the idle timeout")
        #expect(time - lastContent < ChatTimelineFrameMeter.idleTimeout + frame * 1.5, "and then stops")

        let stream = try #require(meter.takeVisit(items: 1).first)
        // 20 frames while content landed, then only those within the active window.
        let activeFrames = 20 + Int((ChatTimelineFrameMeter.activeWindow / frame).rounded(.down))
        #expect(stream.frames >= 20 && stream.frames <= activeFrames + 1)
        #expect(stream.durationMs <= (Double(activeFrames + 1) * frame) * 1_000 + 0.01)
        #expect(stream.hitches == 0)
    }

    @Test func contentAfterAPauseIsMeasuredFromTheFrameBeforeIt() throws {
        let meter = ChatTimelineFrameMeter()
        let lastContent = drive(meter, from: 10, count: 11, activity: .stream)
        let paused = drive(meter, from: lastContent, count: 36, activity: .stream, content: false)
        // The apply that brings the next content holds the main thread for 50 ms.
        drive(meter, from: paused, count: 1, activity: .stream, lateIndex: 0, late: 0.05)

        let stream = try #require(meter.takeVisit(items: 1).first)
        #expect(stream.hitches == 1)
        #expect(abs(stream.worstFrameMs - (frame + 0.05) * 1_000) < 0.01)
        #expect(stream.durationMs < 300, "The paused frames are not in the visit")
    }

    /// The visit ends when the timeline leaves the screen; its events carry the
    /// timeline's session and size, and nothing is counted off screen.
    @Test func leavingTheWindowRecordsTheVisit() throws {
        let windowed = makeWindowedTimelineHarness(sessionId: "frame-meter")
        // The meter counts only in a foreground scene, so host the timeline in one.
        let window = makeSceneWindow()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let collectionView = try #require(windowed.collectionView as? AnchoredCollectionView)
        window.addSubview(collectionView)
        windowed.applyItems([.userMessage(id: "u1", text: "hi", timestamp: Date())], isBusy: true)
        let controller = windowed.coordinator

        #expect(controller.currentFrameActivity() == .stream)
        collectionView.testIsTracking = true
        #expect(controller.currentFrameActivity() == .scroll)
        collectionView.testIsTracking = false

        drive(controller.frameMeter, from: 10, count: 11, activity: controller.currentFrameActivity())
        let capture = TelemetryCapture()
        capture.runSync { collectionView.removeFromSuperview() }

        let event = try #require(capture.events(named: "app.chat_frame_visit").first)
        #expect(capture.events(named: "app.chat_frame_visit").count == 1)
        #expect(event.sessionId == "frame-meter")
        #expect(event.tags?["timeline_activity"] == "stream")
        #expect(event.fields["frames"] == 10)
        #expect(event.fields["items"] == Double(controller.currentIDs.count))
        #expect(controller.currentFrameActivity() == nil, "Off screen counts nothing")
    }
}
