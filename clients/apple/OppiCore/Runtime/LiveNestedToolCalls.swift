import Foundation

/// Live projection of Pi child executions into the parent's recorded Calls.
/// Canonical parent results replace this projection in ToolDetailsStore. Output
/// stays on the parent result: child output must never create a timeline row.
struct LiveNestedToolCalls {
    private var parents: [String: String] = [:]
    private var started: [String: Date] = [:]
    private var completedParents: Set<String> = []
    private var droppedParents: Set<String> = []

    func recordedAllCalls(for parent: String) -> Bool { !droppedParents.contains(parent) }

    mutating func reduce(_ event: AgentEvent, current: (String) -> NestedToolCalls?) -> (parent: String, calls: NestedToolCalls)? {
        let id: String
        let declaredParent: String?
        var name: String?
        var args: [String: JSONValue]?
        var display: ToolDisplay?
        var status: String?
        var isStart = false
        switch event {
        case .toolStart(_, let child, let tool, let arguments, _, _, let label, _, let parent):
            id = child; declaredParent = parent; name = tool; args = arguments; display = label; isStart = true
        case .toolUpdate(_, let child, let tool, let arguments, _, _, let label, _, let parent):
            id = child; declaredParent = parent; name = tool; args = arguments; display = label
        case .toolOutput(let payload):
            id = payload.toolEventId; declaredParent = payload.parentToolCallId
        case .toolEnd(_, let child, _, let isError, _, _, _, _, let parent, _):
            if parent == nil, parents[child] == nil {
                completedParents.insert(child)
                return nil
            }
            id = child; declaredParent = parent; status = isError ? "error" : "ok"
        default: return nil
        }
        guard let direct = declaredParent ?? parents[id], direct != id else { return nil }
        parents[id] = direct
        var parent = direct
        var visited: Set<String> = [id]
        while let ancestor = parents[parent], visited.insert(parent).inserted { parent = ancestor }
        guard !visited.contains(parent) else { return nil }
        var nested = current(parent) ?? .init(calls: [], complete: false)
        // Durable completion wins over replayed child updates, including starts.
        guard !nested.complete, !completedParents.contains(parent) else { return (parent, nested) }
        // A grandchild can finish before its intermediate parent's start.
        // Once that parent gets a root, move its stored projection with it.
        if id != parent, let descendants = current(id) {
            for descendant in descendants.calls where !nested.calls.contains(where: { $0.id == descendant.id }) {
                if nested.calls.count < 256 { nested.calls.append(descendant) }
                else { droppedParents.insert(parent) }
            }
            if droppedParents.remove(id) != nil { droppedParents.insert(parent) }
        }
        if isStart, started[id] == nil { started[id] = Date() }
        let index = nested.calls.firstIndex { $0.id == id }
        var call = index.map { nested.calls[$0] } ?? .init(id: id, name: name ?? "", status: "running")
        if let name { call.name = name }
        if let args, !args.isEmpty { call.arguments = args }
        if let display { call.display = display }
        if call.status != "ok" && call.status != "error" {
            if let status { call.status = status }
            if let start = started[id] { call.durationMs = max(0, Date().timeIntervalSince(start) * 1000) }
        }
        if let index { nested.calls[index] = call }
        else if nested.calls.count < 256 { nested.calls.append(call) }
        else { droppedParents.insert(parent) }
        return (parent, nested)
    }
}
