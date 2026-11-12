import UIKit

// MARK: - Frame meter (app.chat_frame_visit)

/// What starts and ends the timeline's frame-meter visits: every `apply`
/// is new content (a turn's projection re-applies on every reducer change),
/// and a drag starts a scroll; leaving the window, the app going inactive,
/// `dismantle`, or a new session scope end the visit.
extension ChatTimelineController {
    /// Selector observers need no removal: NotificationCenter drops them with the controller.
    func installFrameMeter() {
        frameMeter.currentActivity = { [weak self] in self?.currentFrameActivity() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameMeterAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameMeterAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// What the timeline does now: scrolling under the user's finger or
    /// coasting, else an agent turn running (the meter counts it only near new
    /// content), else nothing. Nothing while the
    /// timeline is out of the window or its scene is not in the foreground, so
    /// a covered or suspended chat counts no frames.
    func currentFrameActivity() -> TelemetryTag.TimelineActivity? {
        guard let collectionView,
              collectionView.window?.windowScene?.activationState == .foregroundActive else {
            return nil
        }
        if collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating {
            return .scroll
        }
        return isTimelineBusy ? .stream : nil
    }

    /// The visit's frame totals go out under the session they were counted in.
    func endFrameVisit() {
        for event in frameMeter.takeVisit(items: currentIDs.count) {
            Telemetry.record(event, sessionId: sessionId, workspaceId: workspaceId)
        }
    }

    @objc private func handleFrameMeterAppWillResignActive() {
        endFrameVisit()
    }

    @objc private func handleFrameMeterAppDidBecomeActive() {
        frameMeter.activityMayHaveStarted()
    }
}
