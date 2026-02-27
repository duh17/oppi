import Foundation

@MainActor
enum TimelineHistoryLoadPlanner {
    enum LoadMode: Equatable {
        case noOp
        case incremental(appendStart: Int)
        case fullRebuild
    }

    static func loadMode(
        timelineMatchesTrace: Bool,
        loadedTraceEventIDs: [String],
        events: [TraceEvent]
    ) -> LoadMode {
        guard timelineMatchesTrace else { return .fullRebuild }
        guard !loadedTraceEventIDs.isEmpty else { return .fullRebuild }
        guard events.count >= loadedTraceEventIDs.count else { return .fullRebuild }

        for (index, loadedID) in loadedTraceEventIDs.enumerated() {
            guard events[index].id == loadedID else { return .fullRebuild }
        }

        let appendStart = loadedTraceEventIDs.count
        if appendStart == events.count {
            return .noOp
        }

        return .incremental(appendStart: appendStart)
    }
}
