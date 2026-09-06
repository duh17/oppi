import Foundation

/// Pretty-prints JSON objects and arrays for display. Returns `nil` when the
/// source is over budget, invalid, or not a JSON object/array.
enum JSONPrettyPrinter: Sendable {
    static let utf8Budget = 64 * 1024

    static func prettyPrinted(_ source: String) -> String? {
        guard source.utf8.count <= utf8Budget else { return nil }
        guard let data = source.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data),
              json is [String: Any] || json is [Any],
              JSONSerialization.isValidJSONObject(json),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: json,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }
        return pretty
    }
}
