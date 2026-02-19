import Foundation

/// Stores pre-rendered styled segments for tool calls, keyed by tool event ID.
///
/// Segments are pre-rendered by the server's MobileRendererRegistry and sent
/// as `callSegments` (in tool_start) and `resultSegments` (in tool_end).
/// Used by ToolPresentationBuilder for rich collapsed display.
@MainActor @Observable
final class ToolSegmentStore {
    private var callStore: [String: [StyledSegment]] = [:]
    private var resultStore: [String: [StyledSegment]] = [:]

    func setCallSegments(_ segments: [StyledSegment], for id: String) {
        callStore[id] = segments
    }

    func setResultSegments(_ segments: [StyledSegment], for id: String) {
        resultStore[id] = segments
    }

    func callSegments(for id: String) -> [StyledSegment]? {
        callStore[id]
    }

    func resultSegments(for id: String) -> [StyledSegment]? {
        resultStore[id]
    }

    func clear(itemIDs: Set<String>) {
        guard !itemIDs.isEmpty else { return }
        for id in itemIDs {
            callStore.removeValue(forKey: id)
            resultStore.removeValue(forKey: id)
        }
    }

    func clearAll() {
        callStore.removeAll()
        resultStore.removeAll()
    }
}
