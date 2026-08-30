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

    func item(kind: MessageQueueKind, id: String) -> MessageQueueItem? {
        guard let index = itemIndex(kind: kind, id: id) else { return nil }
        return items(for: kind)[index]
    }

    func canMove(kind: MessageQueueKind, id: String, direction: Int) -> Bool {
        guard let index = itemIndex(kind: kind, id: id) else { return false }
        return items(for: kind).indices.contains(index + direction)
    }

    mutating func receiveServerQueue(_ latest: MessageQueueState) {
        serverQueue = latest
        if !isDraftMode {
            displayedQueue = latest
        }
    }

    @discardableResult
    mutating func updateMessage(kind: MessageQueueKind, id: String, message: String) -> Bool {
        guard let index = itemIndex(kind: kind, id: id) else { return false }
        return updateMessage(kind: kind, index: index, message: message)
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

    mutating func moveItem(
        kind: MessageQueueKind,
        id: String,
        direction: Int
    ) -> MacMessageQueueMutationRequest? {
        guard let index = itemIndex(kind: kind, id: id) else { return nil }
        return moveItem(kind: kind, from: index, direction: direction)
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

    mutating func moveBetweenQueues(
        kind: MessageQueueKind,
        id: String
    ) -> MacMessageQueueMutationRequest? {
        guard let index = itemIndex(kind: kind, id: id) else { return nil }
        return moveBetweenQueues(kind: kind, index: index)
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

    mutating func deleteItem(
        kind: MessageQueueKind,
        id: String
    ) -> MacMessageQueueMutationRequest? {
        guard let index = itemIndex(kind: kind, id: id) else { return nil }
        return deleteItem(kind: kind, index: index)
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

    /// Commit only the draft snapshot the server accepted. If the user typed
    /// again while the request was awaiting its acknowledgement, the newer
    /// local draft remains editable and can be saved separately.
    mutating func acceptDraft(_ accepted: MacMessageQueueMutationRequest) {
        guard isDraftMode else { return }
        let current = Self.makeMutationRequest(
            baseVersion: accepted.baseVersion,
            queue: displayedQueue
        )
        guard current == accepted else { return }

        isDraftMode = false
        if serverQueue.version != accepted.baseVersion {
            displayedQueue = serverQueue
        }
    }

    /// Immediate queue actions paint optimistically. Restore the last
    /// server-confirmed snapshot when the corresponding command is rejected.
    mutating func rollbackRejectedImmediateMutation() {
        discardDraft()
    }

    func draftRequest() -> MacMessageQueueMutationRequest? {
        guard isDraftMode else { return nil }
        return Self.makeMutationRequest(baseVersion: serverQueue.version, queue: displayedQueue)
    }

    private func items(for kind: MessageQueueKind) -> [MessageQueueItem] {
        switch kind {
        case .steer: displayedQueue.steering
        case .followUp: displayedQueue.followUp
        }
    }

    private func itemIndex(kind: MessageQueueKind, id: String) -> Int? {
        items(for: kind).firstIndex { $0.id == id }
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
