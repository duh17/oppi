import Foundation
@testable import Oppi

/// Producer-authored test fixtures for the additive file-facts contract.
/// This is not a fallback in the product. Missing-facts tests bypass it.
enum ToolFileFactsFixture {
    static let readInput = ToolInputPresentation(fields: ["path": .init(role: "filePath"), "offset": .init(role: "lineOffset"), "limit": .init(role: "lineLimit")])
    static let writeInput = ToolInputPresentation(fields: ["path": .init(role: "filePath"), "content": .init(role: "fileContent")])
    static let editInput = ToolInputPresentation(fields: ["path": .init(role: "filePath"), "edits": .init(role: "edits")])
    static func facts(_ operation: String) -> (ToolInputPresentation, ToolOutputPresentation)? {
        switch operation {
        case "read": return (readInput, .init(kind: "fileContent", provenance: "result"))
        case "write": return (writeInput, .init(kind: "fileContent", provenance: "requested"))
        case "edit": return (editInput, .init(kind: "diffOfEdits", provenance: "result"))
        default: return nil
        }
    }
    static func callSegments(args: [String: JSONValue]?, operation: String?) -> [StyledSegment]? {
        guard let operation, let args, let path = args["path"]?.stringValue else { return nil }
        var title = path.shortenedPath
        if operation == "read" {
            let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            if parts.last == "SKILL.md", parts.count > 1 { title = "[skill] \(parts[parts.count - 2])" }
            let offset = args["offset"]?.numberValue.map(Int.init)
            let limit = args["limit"]?.numberValue.map(Int.init)
            if offset != nil || limit != nil {
                let start = offset ?? 1
                title += ":\(start)\(limit.map { "-\(start + $0 - 1)" } ?? "")"
            }
        }
        return [.init(text: operation + " ", style: .bold), .init(text: title, style: .accent)]
    }
}
