import Foundation

/// The client's copy of one durable conversation: entries by id in display order, the
/// head, and the client-visible documents, advanced by conversation stream frames.
///
/// - `snapshot` replaces everything.
/// - `update` upserts entries by id (an id not held goes in id order after the head entry)
///   and applies each document's Chord ops; `nil` ops remove the document.
/// - `older` prepends a page of history.
///
/// A frame that does not apply (another conversation, an op on a path the replica lacks)
/// throws, and the replica is no longer a faithful copy: re-attach without a cursor for a
/// snapshot. Frames apply in place so streamed text grows without copying documents.
struct ConversationReplica: Equatable, Sendable {
    private(set) var conversationId: Int?
    /// Held entries in display order, hidden ones included (they carry no content).
    private(set) var entries: [ConversationEntryView] = []
    /// Id of the head entry (reset or compaction), or 0.
    private(set) var head = 0
    /// Entries exist before the oldest one held.
    private(set) var hasOlder = false
    private(set) var docs: [String: JSONValue] = [:]
    /// Resume cursor for `attach { afterEntryId }`: the newest entry id held.
    private(set) var resumeCursor: Int?
    /// `older { beforeEntryId }`: the smallest entry id held.
    private(set) var oldestEntryId: Int?
    private var positions: [Int: Int] = [:]

    enum ApplyError: Error, Equatable {
        case conversationMismatch(expected: Int, received: Int)
        case unresolvablePath([ConversationDocPathKey])
    }

    mutating func apply(_ message: ConversationStreamServerMessage) throws {
        switch message {
        case .snapshot(let snapshot):
            conversationId = snapshot.conversationId
            entries = snapshot.entries
            head = snapshot.head
            hasOlder = snapshot.hasOlder
            docs = snapshot.docs
            reindex()
        case .update(let update):
            try claim(update.conversationId)
            for entry in update.entries ?? [] { upsert(entry) }
            for (kind, ops) in update.docs ?? [:] {
                // Taken out so the ops edit the only copy.
                var document = docs.removeValue(forKey: kind)
                guard let ops else { continue }
                try ChordDelta.apply(ops, to: &document)
                docs[kind] = document
            }
        case .older(let page):
            try claim(page.conversationId)
            let held = Set(positions.keys)
            entries = page.entries.filter { !held.contains($0.id) } + entries
            hasOlder = page.hasOlder
            reindex()
        }
    }

    private mutating func claim(_ id: Int) throws {
        if let conversationId, conversationId != id {
            throw ApplyError.conversationMismatch(expected: conversationId, received: id)
        }
        conversationId = id
    }

    private mutating func upsert(_ entry: ConversationEntryView) {
        if let position = positions[entry.id] {
            entries[position] = entry
            return
        }
        // Newer than everything held, as almost every update entry is: append.
        if entry.id > (resumeCursor ?? Int.min) {
            positions[entry.id] = entries.count
            entries.append(entry)
            resumeCursor = entry.id
            oldestEntryId = min(oldestEntryId ?? entry.id, entry.id)
            return
        }
        let start = entries.first?.id == head && head != 0 ? 1 : 0
        let index = entries[start...].firstIndex { $0.id > entry.id } ?? entries.count
        entries.insert(entry, at: index)
        reindex()
    }

    private mutating func reindex() {
        positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        resumeCursor = entries.lazy.map(\.id).max()
        oldestEntryId = entries.lazy.map(\.id).min()
    }
}

/// Applies Chord delta ops (`@earendil-works/chord/delta` `apply`) to a JSON document.
enum ChordDelta {
    /// Applies `ops` in order. `document` is `nil` when absent; only `r` can create it.
    static func apply(_ ops: [ConversationDocOp], to document: inout JSONValue?) throws {
        for op in ops {
            if case .replace(let value) = op {
                document = value
                continue
            }
            guard var value = document else {
                throw ConversationReplica.ApplyError.unresolvablePath(path(of: op))
            }
            document = nil
            defer { document = value }
            try apply(op, to: &value)
        }
    }

    private static func path(of op: ConversationDocOp) -> [ConversationDocPathKey] {
        switch op {
        case .replace: []
        case .set(let path, _), .delete(let path), .append(let path, _), .truncate(let path, _),
             .splice(let path, _, _, _), .move(let path, _):
            path
        }
    }

    private static func apply(_ op: ConversationDocOp, to root: inout JSONValue) throws {
        let path = path(of: op)
        let unresolvable = ConversationReplica.ApplyError.unresolvablePath(path)
        switch op {
        case .replace:
            return
        case .splice(_, let index, let deleteCount, let items):
            try mutate(&root, at: path[...], path: path) { target in
                guard case .array(var array) = target else { throw unresolvable }
                target = .null
                // Array.prototype.splice clamps its start and delete count.
                let start = min(index, array.count)
                let end = min(start + deleteCount, array.count)
                array.replaceSubrange(start..<end, with: items)
                target = .array(array)
            }
        case .move(_, let permutation):
            try mutate(&root, at: path[...], path: path) { target in
                guard case .array(let array) = target, array.count == permutation.count,
                      permutation.allSatisfy({ array.indices.contains($0) }) else { throw unresolvable }
                target = .array(permutation.map { array[$0] })
            }
        case .set(_, let value):
            try mutateMember(&root, path: path) { parent, key in
                switch (parent, key) {
                case (.object(var object), _):
                    parent = .null
                    object[key.objectKey] = value
                    parent = .object(object)
                case (.array(var array), .index(let index)) where index <= array.count:
                    parent = .null
                    if index == array.count { array.append(value) } else { array[index] = value }
                    parent = .array(array)
                default:
                    throw unresolvable
                }
            }
        case .delete:
            try mutateMember(&root, path: path) { parent, key in
                switch (parent, key) {
                case (.object(var object), _):
                    parent = .null
                    object.removeValue(forKey: key.objectKey)
                    parent = .object(object)
                case (.array(var array), .index(let index)) where array.indices.contains(index):
                    parent = .null
                    array.remove(at: index)
                    parent = .array(array)
                default:
                    throw unresolvable
                }
            }
        case .append(_, let text):
            try mutateString(&root, path: path) { $0 += text }
        case .truncate(_, let count):
            // JavaScript `slice(n)`: drops UTF-16 code units, clamped to the length.
            try mutateString(&root, path: path) { string in
                let units = string.utf16
                let start = units.index(units.startIndex, offsetBy: count, limitedBy: units.endIndex) ?? units.endIndex
                string = String(decoding: units[start...], as: UTF16.self)
            }
        }
    }

    /// Runs `body` on the value at `remaining`, which must exist. Containers along the way are
    /// taken out of their parents first, so the edit does not copy them.
    private static func mutate(
        _ value: inout JSONValue,
        at remaining: ArraySlice<ConversationDocPathKey>,
        path: [ConversationDocPathKey],
        body: (inout JSONValue) throws -> Void
    ) throws {
        guard let key = remaining.first else {
            try body(&value)
            return
        }
        let rest = remaining.dropFirst()
        switch value {
        case .object(var object):
            value = .null
            defer { value = .object(object) }
            guard var child = object.removeValue(forKey: key.objectKey) else {
                throw ConversationReplica.ApplyError.unresolvablePath(path)
            }
            defer { object[key.objectKey] = child }
            try mutate(&child, at: rest, path: path, body: body)
        case .array(var array):
            guard case .index(let index) = key, array.indices.contains(index) else {
                throw ConversationReplica.ApplyError.unresolvablePath(path)
            }
            value = .null
            defer { value = .array(array) }
            var child = array[index]
            array[index] = .null
            defer { array[index] = child }
            try mutate(&child, at: rest, path: path, body: body)
        default:
            throw ConversationReplica.ApplyError.unresolvablePath(path)
        }
    }

    private static func mutateMember(
        _ root: inout JSONValue,
        path: [ConversationDocPathKey],
        body: (inout JSONValue, ConversationDocPathKey) throws -> Void
    ) throws {
        guard let key = path.last else { throw ConversationReplica.ApplyError.unresolvablePath(path) }
        try mutate(&root, at: path.dropLast(), path: path) { parent in try body(&parent, key) }
    }

    private static func mutateString(
        _ root: inout JSONValue,
        path: [ConversationDocPathKey],
        body: (inout String) -> Void
    ) throws {
        try mutate(&root, at: path[...], path: path) { target in
            guard case .string(var string) = target else {
                throw ConversationReplica.ApplyError.unresolvablePath(path)
            }
            target = .null
            body(&string)
            target = .string(string)
        }
    }
}

private extension ConversationDocPathKey {
    /// JavaScript property keys are strings; a numeric segment names the same key.
    var objectKey: String {
        switch self {
        case .key(let key): key
        case .index(let index): String(index)
        }
    }
}
