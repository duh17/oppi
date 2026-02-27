import Foundation

@MainActor
enum TimelineHistoryLoadPlanner {
    static func incrementalAppendStartIndex(
        timelineMatchesTrace: Bool,
        loadedTraceEventIDs: [String],
        events: [TraceEvent]
    ) -> Int? {
        guard timelineMatchesTrace else { return nil }
        guard !loadedTraceEventIDs.isEmpty else { return nil }
        guard events.count >= loadedTraceEventIDs.count else { return nil }

        for (index, loadedID) in loadedTraceEventIDs.enumerated() {
            guard events[index].id == loadedID else { return nil }
        }

        return loadedTraceEventIDs.count
    }
}
