import Foundation

@MainActor
final class TimelineItemIndex {
    private var indexByID: [String: Int] = [:]

    func clear(keepingCapacity: Bool = true) {
        indexByID.removeAll(keepingCapacity: keepingCapacity)
    }

    func remove(id: String) {
        indexByID.removeValue(forKey: id)
    }

    func indexForID(_ id: String, items: [ChatItem]) -> Int? {
        if let idx = indexByID[id], idx < items.count, items[idx].id == id {
            return idx
        }

        if let idx = items.firstIndex(where: { $0.id == id }) {
            indexByID[id] = idx
            return idx
        }

        return nil
    }

    func rebuildIndex(_ items: [ChatItem]) {
        indexByID.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            indexByID[item.id] = index
        }
    }

    func indexAppend(_ item: ChatItem, itemCount: Int) {
        indexByID[item.id] = itemCount - 1
    }
}
