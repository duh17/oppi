import Foundation

struct MacMessageQueueMutationRequest: Equatable, Sendable {
    let baseVersion: Int
    let steering: [MessageQueueDraftItem]
    let followUp: [MessageQueueDraftItem]
}

struct MacMessageQueueEditorState: Equatable, Sendable {
    private(set) var serverQueue: MessageQueueState
    private(set) var displayedQueue: MessageQueueState
    private(set) var isDraftMode: Bool

    init(queue: MessageQueueState) {
        serverQueue = queue
        displayedQueue = queue
        isDraftMode = false
    }

    var isEmpty: Bool {
        displayedQueue.steering.isEmpty && displayedQueue.followUp.isEmpty
    }

    mutating func receiveServerQueue(_ latest: MessageQueueState) {
        serverQueue = latest
        if !isDraftMode {
            displayedQueue = latest
        }
    }

    @discardableResult
    mutating func updateMessage(kind: MessageQueueKind, index: Int, message: String) -> Bool {
        var next = displayedQueue
        switch kind {
        case .steer:
            guard next.steering.indices.contains(index) else { return false }
            next.steering[index].message = message
        case .followUp:
            guard next.followUp.indices.contains(index) else { return false }
            next.followUp[index].message = message
        }
        guard next != displayedQueue else { return false }
        displayedQueue = next
        isDraftMode = true
        return true
    }

    mutating func moveItem(kind: MessageQueueKind, from index: Int, direction: Int) -> MacMessageQueueMutationRequest? {
        applyStructuralMutation { queue in
            let target = index + direction
            switch kind {
            case .steer:
                guard queue.steering.indices.contains(index), queue.steering.indices.contains(target) else { return false }
                queue.steering.swapAt(index, target)
            case .followUp:
                guard queue.followUp.indices.contains(index), queue.followUp.indices.contains(target) else { return false }
                queue.followUp.swapAt(index, target)
            }
            return true
        }
    }

    mutating func moveBetweenQueues(kind: MessageQueueKind, index: Int) -> MacMessageQueueMutationRequest? {
        applyStructuralMutation { queue in
            switch kind {
            case .steer:
                guard queue.steering.indices.contains(index) else { return false }
                queue.followUp.append(queue.steering.remove(at: index))
            case .followUp:
                guard queue.followUp.indices.contains(index) else { return false }
                queue.steering.append(queue.followUp.remove(at: index))
            }
            return true
        }
    }

    mutating func deleteItem(kind: MessageQueueKind, index: Int) -> MacMessageQueueMutationRequest? {
        applyStructuralMutation { queue in
            switch kind {
            case .steer:
                guard queue.steering.indices.contains(index) else { return false }
                queue.steering.remove(at: index)
            case .followUp:
                guard queue.followUp.indices.contains(index) else { return false }
                queue.followUp.remove(at: index)
            }
            return true
        }
    }

    mutating func discardDraft() {
        displayedQueue = serverQueue
        isDraftMode = false
    }

    func draftRequest() -> MacMessageQueueMutationRequest? {
        guard isDraftMode else { return nil }
        return Self.makeMutationRequest(baseVersion: serverQueue.version, queue: displayedQueue)
    }

    private mutating func applyStructuralMutation(
        _ mutate: (inout MessageQueueState) -> Bool
    ) -> MacMessageQueueMutationRequest? {
        var next = displayedQueue
        guard mutate(&next) else { return nil }
        displayedQueue = next

        if isDraftMode {
            return nil
        }
        return Self.makeMutationRequest(baseVersion: serverQueue.version, queue: next)
    }

    private static func makeMutationRequest(
        baseVersion: Int,
        queue: MessageQueueState
    ) -> MacMessageQueueMutationRequest {
        MacMessageQueueMutationRequest(
            baseVersion: baseVersion,
            steering: queue.steering.map(makeDraftItem),
            followUp: queue.followUp.map(makeDraftItem)
        )
    }

    private static func makeDraftItem(_ item: MessageQueueItem) -> MessageQueueDraftItem {
        MessageQueueDraftItem(
            id: item.id,
            message: item.message,
            attachments: item.attachments,
            createdAt: item.createdAt
        )
    }
}
