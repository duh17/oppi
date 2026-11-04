import Foundation

/// A change to a surface the client already holds, as the publisher applied it before sending.
///
/// The server validates a patch like a full surface, so the client's job is the same dotted-path
/// merge: `sections.0.phase` names a field, a numeric segment indexes a list, and `null` removes a
/// field (a subtitle, a sort). A patch that does not apply whole is dropped whole — a surface that
/// half-changed would draw a card the server never published.
enum ExtensionSurfacePatchApplier {
    /// The surface at `revision` after `patch`, or nil when the patch does not apply.
    static func apply(
        _ patch: [String: JSONValue],
        to surface: ExtensionUISurface,
        revision: Int
    ) -> ExtensionUISurface? {
        guard !patch.isEmpty,
              let encoded = try? JSONEncoder().encode(surface),
              var document = try? JSONDecoder().decode(JSONValue.self, from: encoded),
              case .object = document else {
            return nil
        }
        // Deterministic order, and no overlapping paths: the server applies the frame's own key
        // order, so `sections.0` with `sections.0.phase` could land differently on each side. A
        // patch that names one path inside another is malformed either way, and the same frame
        // must land the same way twice.
        let paths = patch.keys.sorted()
        for (index, path) in paths.enumerated() {
            for other in paths[(index + 1)...] where other.hasPrefix(path + ".") {
                return nil
            }
        }
        for path in paths {
            guard let value = patch[path], write(value, at: path, in: &document) else { return nil }
        }
        // The revision is server-owned: a patch carries data, not the next version number.
        guard var fields = document.objectValue else { return nil }
        fields["revision"] = .number(Double(revision))
        document = .object(fields)
        guard let merged = try? JSONEncoder().encode(document),
              let surface = try? JSONDecoder().decode(ExtensionUISurface.self, from: merged) else {
            return nil
        }
        return surface
    }

    /// `id` and `version` are the surface's identity: a patch never rewrites them.
    private static let immutableRoots: Set<String> = ["id", "version"]
    private static let forbiddenSegments: Set<String> = ["__proto__", "constructor", "prototype"]

    private static func write(_ value: JSONValue, at path: String, in root: inout JSONValue) -> Bool {
        guard !path.isEmpty else { return false }
        let segments = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !segments.contains(where: { $0.isEmpty || forbiddenSegments.contains($0) }),
              let first = segments.first, !immutableRoots.contains(first) else {
            return false
        }
        return write(value, segments: segments[...], in: &root)
    }

    private static func write(_ value: JSONValue, segments: ArraySlice<String>, in node: inout JSONValue) -> Bool {
        guard let segment = segments.first else { return false }
        let rest = segments.dropFirst()
        switch node {
        case .object(var fields):
            guard let child = fields[segment] else {
                // A path may name a field the surface does not carry yet; the rest of the path
                // must then build objects, never cross a value.
                guard !rest.isEmpty else {
                    fields[segment] = value
                    node = .object(fields)
                    return true
                }
                var created = JSONValue.object([:])
                guard write(value, segments: rest, in: &created) else { return false }
                fields[segment] = created
                node = .object(fields)
                return true
            }
            guard !rest.isEmpty else {
                // A `null` deletes the field, so a patch can remove an optional value.
                if value == .null {
                    fields.removeValue(forKey: segment)
                } else {
                    fields[segment] = value
                }
                node = .object(fields)
                return true
            }
            var next = child
            guard write(value, segments: rest, in: &next) else { return false }
            fields[segment] = next
            node = .object(fields)
            return true

        case .array(var items):
            guard let index = arrayIndex(segment, in: items) else { return false }
            guard !rest.isEmpty else {
                // A list entry can be replaced but never removed: the host draws the list it was
                // given, and a hole in it would be a card the publisher never wrote.
                guard value != .null else { return false }
                items[index] = value
                node = .array(items)
                return true
            }
            var next = items[index]
            guard write(value, segments: rest, in: &next) else { return false }
            items[index] = next
            node = .array(items)
            return true

        default:
            return false
        }
    }

    /// A list entry by index, or by its `id` with `#id`: a body node keeps its address when a
    /// sibling is inserted. A path never invents an entry.
    private static func arrayIndex(_ segment: String, in items: [JSONValue]) -> Int? {
        if segment.hasPrefix("#") {
            let id = String(segment.dropFirst())
            guard !id.isEmpty else { return nil }
            return items.firstIndex { entry in
                guard case .object(let fields) = entry, case .string(let entryId)? = fields["id"]
                else { return false }
                return entryId == id
            }
        }
        guard !segment.isEmpty, segment.allSatisfy(\.isNumber), let index = Int(segment),
              index < items.count else {
            return nil
        }
        return index
    }
}
