import QuartzCore

/// Counts the chat timeline's frames and hitches while it is on screen and the
/// user scrolls it (finger down through coasting) or an agent turn puts new
/// content on it. A visit's totals go out once, as one `app.chat_frame_visit`
/// event per activity, when the timeline leaves the screen, the app goes
/// inactive, or the timeline changes session. Each event carries hitch time and
/// duration, so hitch time per second pools over visits instead of averaging
/// their ratios.
///
/// The display link runs only while there is something to measure, so a long
/// agent run that changes nothing on screen costs no frames:
/// - a drag, or a turn's content landing (`contentChanged`), starts it;
/// - scrolling counts every frame until the scroll ends;
/// - a turn counts the frames within `activeWindow` of its latest content and
///   skips the rest, so the idle gaps between updates never pad the visit;
/// - `idleTimeout` after the latest content, with nothing scrolling, the link
///   stops until the next change.
/// Scrolling already drives the display at its full rate, so the link asks for
/// nothing more; during a turn it caps itself at 60 Hz.
@MainActor
final class ChatTimelineFrameMeter {
    typealias Activity = TelemetryTag.TimelineActivity

    /// Content lands about every 33 ms while a turn streams (the delta
    /// coalescer's window); a frame further than this from the latest change
    /// shows nothing new.
    static let activeWindow: CFTimeInterval = 0.1
    /// How long the link outlives the latest content before it stops.
    static let idleTimeout: CFTimeInterval = 0.5
    private static let streamRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

    /// What the timeline does now, read on every tick: `.scroll` while it
    /// scrolls, `.stream` while a turn runs, nil when it is off screen, the app
    /// is inactive, or neither.
    var currentActivity: () -> Activity? = { nil }

    private var counters: [Activity: FrameHitchCounter] = [:]
    /// The activity the last tick saw; a tick that finds another one starts
    /// that activity's clock instead of counting the gap.
    private var current: Activity?
    private var lastContentChange = -CFTimeInterval.infinity
    private var link: CADisplayLink?
    private var linkRateActivity: Activity?

    isolated deinit {
        link?.invalidate()
    }

    /// The timeline applied new content at `time` (the display link's clock).
    func contentChanged(at time: CFTimeInterval = CACurrentMediaTime()) {
        lastContentChange = time
        activityMayHaveStarted()
    }

    /// A drag began, content changed, or the timeline came back on screen.
    func activityMayHaveStarted() {
        guard link == nil, let activity = currentActivity() else { return }
        guard activity == .scroll || CACurrentMediaTime() - lastContentChange < Self.idleTimeout else { return }
        let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        linkRateActivity = nil
        current = nil
    }

    /// Counts the frame that landed at `timestamp` toward `activity`; nil counts
    /// nothing. Returns whether the link should keep running.
    @discardableResult
    func tick(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval, activity: Activity?) -> Bool {
        if activity != current {
            if let activity { counters[activity, default: FrameHitchCounter()].forgetLastFrame() }
            current = activity
        }
        guard let activity else { return false }
        if activity == .stream {
            let sinceContent = timestamp - lastContentChange
            guard sinceContent <= Self.activeWindow else {
                // Keep the clock at this frame, so the frame that brings the next
                // content is measured from here, slow apply included.
                counters[.stream]?.skipFrame(at: timestamp)
                return sinceContent < Self.idleTimeout
            }
        }
        counters[activity, default: FrameHitchCounter()].tick(timestamp: timestamp, targetTimestamp: targetTimestamp)
        return true
    }

    /// The visit's totals, one event per activity, and a fresh visit. The link
    /// stops; the next scroll or content starts the next visit.
    func takeVisit(items: Int) -> [AppChatFrameVisit] {
        defer {
            counters = [:]
            current = nil
            link?.invalidate()
            link = nil
        }
        return Activity.allCases.compactMap { activity in
            guard let counter = counters[activity] else { return nil }
            return AppChatFrameVisit(
                durationMs: counter.elapsedMilliseconds,
                frames: counter.frames,
                hitches: counter.hitches,
                hitchMs: counter.hitchMilliseconds,
                worstFrameMs: counter.worstFrameMilliseconds,
                items: items,
                timelineActivity: activity
            )
        }
    }

    private func linkTicked(_ link: CADisplayLink) {
        let activity = currentActivity()
        if activity != linkRateActivity {
            link.preferredFrameRateRange = activity == .stream ? Self.streamRate : .default
            linkRateActivity = activity
        }
        guard !tick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp, activity: activity) else { return }
        link.invalidate()
        self.link = nil
    }

    /// The link retains its target; the meter must not be kept alive by it.
    private final class LinkTarget: NSObject {
        weak var meter: ChatTimelineFrameMeter?

        init(_ meter: ChatTimelineFrameMeter) {
            self.meter = meter
        }

        @MainActor @objc func tick(_ link: CADisplayLink) {
            guard let meter else {
                link.invalidate()
                return
            }
            meter.linkTicked(link)
        }
    }
}
