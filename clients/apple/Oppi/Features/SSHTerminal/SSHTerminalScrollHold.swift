import Foundation

/// Rex output the channel holds back while a scroll gesture runs, so the main
/// actor spends the gesture's frames on the pane being scrolled: output of
/// panes that are not on screen, and every pane's history download (its
/// `snapshotRecords`), wait here and are applied, oldest first, once the
/// gesture ends.
///
/// Order is the contract. Items of one pane apply in the order they arrived,
/// so once a pane has an item held, everything after it for that pane is held
/// too, whether or not a gesture is running; an item that is not a pane's
/// (the connection ending, a status event) is a barrier and holds everything
/// behind it. Nothing is dropped: past `capBytes` the oldest items are handed
/// back (`popFirst`) to be applied in small slices even though the gesture is
/// still running, so a long scroll never grows this without bound.
struct SSHTerminalScrollHold {
    typealias Item = SSHTerminalEventQueue.Item

    /// Where an item applies: one pane's terminal, or the whole channel.
    private enum Lane: Hashable {
        case pane(String?)
        case channel
    }

    /// Most bytes held at once. The queue's own limit (4 MiB) is the stuck-consumer
    /// backstop; held items have left it, so this is the only bound on them.
    static let defaultCapBytes = 1024 * 1024

    let capBytes: Int
    private var items: [Item] = []
    private var head = 0
    private var lanes: [Lane: Int] = [:]
    private(set) var bytes = 0
    /// Bytes ever held, so a gesture can say how much it kept off its frames.
    private(set) var totalHeldBytes = 0

    init(capBytes: Int = Self.defaultCapBytes) {
        self.capBytes = capBytes
    }

    var isEmpty: Bool { head == items.count }
    var isOverCap: Bool { bytes > capBytes }

    /// Whether `item` waits. `presented` is the pane on screen; `scrolling` is
    /// whether a gesture is running now.
    func shouldHold(_ item: Item, presented: String?, scrolling: Bool) -> Bool {
        if lanes[.channel] != nil { return true }
        let lane = Self.lane(of: item)
        if lane == .channel { return !isEmpty }
        if lanes[lane] != nil { return true }
        guard scrolling else { return false }
        switch item {
        case .data(_, let block): return block != presented
        case .snapshotRecords: return true
        default: return false
        }
    }

    mutating func hold(_ item: Item) {
        items.append(item)
        lanes[Self.lane(of: item), default: 0] += 1
        let size = Self.size(of: item)
        bytes += size
        totalHeldBytes += size
    }

    /// The oldest held item, which the caller applies at once.
    mutating func popFirst() -> Item? {
        guard head < items.count else { return nil }
        let item = items[head]
        head += 1
        let lane = Self.lane(of: item)
        if let count = lanes[lane], count > 1 { lanes[lane] = count - 1 } else { lanes[lane] = nil }
        bytes -= Self.size(of: item)
        // Compact once the consumed prefix outweighs the rest, so popping stays O(1).
        if head == items.count {
            items.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 64, head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        return item
    }

    private static func lane(of item: Item) -> Lane {
        switch item {
        case .data(_, let block): .pane(block)
        case .snapshot(_, let block), .snapshotRecords(_, let block): .pane(block)
        case .event(.data): .pane(nil)
        case .event, .overflow, .ended: .channel
        }
    }

    private static func size(of item: Item) -> Int {
        switch item {
        case .data(let data, _), .snapshot(let data, _), .snapshotRecords(let data, _), .event(.data(let data)): data.count
        case .event, .overflow, .ended: 0
        }
    }
}
