import Foundation

enum MessageQueueEditorConflict: Equatable, Sendable {
    case queueChanged
    case queuedMessageStarted
    case queueCleared

    var title: String {
        switch self {
        case .queueChanged, .queuedMessageStarted, .queueCleared:
            return "Queue changed while you were editing"
        }
    }

    var message: String {
        switch self {
        case .queueChanged:
            return "Your draft is still here, but it is based on an older queue."
        case .queuedMessageStarted:
            return "A queued message started, so your draft is now based on an older queue."
        case .queueCleared:
            return "The queue was cleared, but your draft is still available."
        }
    }

    var reviewActionTitle: String {
        switch self {
        case .queueCleared:
            return "Review empty queue"
        case .queueChanged, .queuedMessageStarted:
            return "Review latest"
        }
    }

    var applyActionTitle: String {
        switch self {
        case .queueCleared:
            return "Restore my draft"
        case .queueChanged, .queuedMessageStarted:
            return "Use my draft"
        }
    }
}

struct MessageQueueMutationRequest: Equatable, Sendable {
    let baseVersion: Int
    let steering: [MessageQueueDraftItem]
    let followUp: [MessageQueueDraftItem]
}

struct MessageQueueEditorState: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case live
        case draft
    }

    private(set) var serverQueue: MessageQueueState
    private(set) var displayedQueue: MessageQueueState
    private(set) var mode: Mode
    private(set) var conflict: MessageQueueEditorConflict?
    private(set) var stashedDraft: MessageQueueState?

    init(queue: MessageQueueState) {
        serverQueue = queue
        displayedQueue = queue
        mode = .live
        conflict = nil
        stashedDraft = nil
    }

    var isDraftMode: Bool {
        mode == .draft
    }

    var hasStashedDraft: Bool {
        stashedDraft != nil && mode == .live
    }

    mutating func receiveServerQueue(_ latest: MessageQueueState, isExpanded: Bool) {
        let previousServerQueue = serverQueue
        serverQueue = latest

        if !isExpanded, mode == .draft {
            guard latest != previousServerQueue else { return }
            conflict = Self.makeConflict(previous: previousServerQueue, latest: latest)
            return
        }

        switch mode {
        case .live:
            displayedQueue = latest
            conflict = nil
        case .draft:
            guard latest != previousServerQueue else { return }
            conflict = Self.makeConflict(previous: previousServerQueue, latest: latest)
        }
    }

    @discardableResult
    mutating func updateMessage(kind: MessageQueueKind, index: Int, message: String) -> Bool {
        var next = displayedQueue
        guard updateMessage(in: &next, kind: kind, index: index, message: message) else {
            return false
        }
        guard next != displayedQueue else {
            return false
        }

        displayedQueue = next
        mode = .draft
        conflict = nil
        stashedDraft = nil
        return true
    }

    mutating func moveItem(kind: MessageQueueKind, from index: Int, direction: Int) -> MessageQueueMutationRequest? {
        applyStructuralMutation { queue in
            let items = Self.items(for: queue, kind: kind)
            let target = index + direction
            guard items.indices.contains(index), items.indices.contains(target) else { return false }
            switch kind {
            case .steer:
                queue.steering.swapAt(index, target)
            case .followUp:
                queue.followUp.swapAt(index, target)
            }
            return true
        }
    }

    mutating func moveBetweenQueues(kind: MessageQueueKind, index: Int) -> MessageQueueMutationRequest? {
        applyStructuralMutation { queue in
            switch kind {
            case .steer:
                guard queue.steering.indices.contains(index) else { return false }
                let item = queue.steering.remove(at: index)
                queue.followUp.append(item)
            case .followUp:
                guard queue.followUp.indices.contains(index) else { return false }
                let item = queue.followUp.remove(at: index)
                queue.steering.append(item)
            }
            return true
        }
    }

    mutating func deleteItem(kind: MessageQueueKind, index: Int) -> MessageQueueMutationRequest? {
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
        mode = .live
        conflict = nil
        stashedDraft = nil
    }

    mutating func reviewLatest() {
        guard mode == .draft else { return }
        stashedDraft = displayedQueue
        displayedQueue = serverQueue
        mode = .live
        conflict = nil
    }

    mutating func restoreDraft() {
        guard let stashedDraft else { return }
        displayedQueue = stashedDraft
        self.stashedDraft = nil
        mode = .draft
        conflict = nil
    }

    mutating func revertLiveQueueToServer() {
        guard mode == .live else { return }
        displayedQueue = serverQueue
        conflict = nil
    }

    func draftRequest() -> MessageQueueMutationRequest? {
        guard mode == .draft else { return nil }
        return Self.makeMutationRequest(baseVersion: serverQueue.version, queue: displayedQueue)
    }

    private mutating func applyStructuralMutation(
        _ mutate: (inout MessageQueueState) -> Bool
    ) -> MessageQueueMutationRequest? {
        var next = displayedQueue
        guard mutate(&next) else {
            return nil
        }

        displayedQueue = next
        conflict = nil

        switch mode {
        case .live:
            stashedDraft = nil
            return Self.makeMutationRequest(baseVersion: serverQueue.version, queue: next)
        case .draft:
            return nil
        }
    }

    private static func makeMutationRequest(
        baseVersion: Int,
        queue: MessageQueueState
    ) -> MessageQueueMutationRequest {
        MessageQueueMutationRequest(
            baseVersion: baseVersion,
            steering: queue.steering.map(Self.makeDraftItem),
            followUp: queue.followUp.map(Self.makeDraftItem)
        )
    }

    private static func makeDraftItem(_ item: MessageQueueItem) -> MessageQueueDraftItem {
        MessageQueueDraftItem(
            id: item.id,
            message: item.message,
            images: item.images,
            createdAt: item.createdAt
        )
    }

    private static func makeConflict(
        previous: MessageQueueState,
        latest: MessageQueueState
    ) -> MessageQueueEditorConflict {
        let previousCount = previous.steering.count + previous.followUp.count
        let latestCount = latest.steering.count + latest.followUp.count

        if previousCount > 0, latestCount == 0 {
            return .queueCleared
        }
        if latestCount < previousCount {
            return .queuedMessageStarted
        }
        return .queueChanged
    }

    private static func items(for queue: MessageQueueState, kind: MessageQueueKind) -> [MessageQueueItem] {
        switch kind {
        case .steer:
            return queue.steering
        case .followUp:
            return queue.followUp
        }
    }

    private func updateMessage(
        in queue: inout MessageQueueState,
        kind: MessageQueueKind,
        index: Int,
        message: String
    ) -> Bool {
        switch kind {
        case .steer:
            guard queue.steering.indices.contains(index) else { return false }
            queue.steering[index].message = message
        case .followUp:
            guard queue.followUp.indices.contains(index) else { return false }
            queue.followUp[index].message = message
        }
        return true
    }
}
