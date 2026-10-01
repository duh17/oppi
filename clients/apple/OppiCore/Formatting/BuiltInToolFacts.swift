import Foundation

/// The sole client tool-identity exception: older servers omit inspection facts.
/// Never mix inferred roles with producer facts, and never normalize tool names.
/// Keep these five declarations aligned with server/src/mobile-renderer-facts.ts.
enum BuiltInToolFacts {
    static func resolve(tool: String, context: ToolContentDescriptorBuilder.Context) -> ToolContentDescriptorBuilder.Context {
        guard context.inputPresentation == nil, context.outputPresentation == nil else { return context }
        var resolved = context
        switch tool {
        case "bash":
            resolved.inputPresentation = .init(fields: ["command": .init(role: "command", language: "shell")])
            resolved.outputPresentation = .init(kind: "terminal")
        case "read":
            resolved.inputPresentation = .init(fields: [
                "path": .init(role: "filePath"), "offset": .init(role: "lineOffset"), "limit": .init(role: "lineLimit")
            ])
            resolved.outputPresentation = .init(kind: "fileContent", provenance: "result")
        case "write":
            resolved.inputPresentation = .init(fields: ["path": .init(role: "filePath"), "content": .init(role: "fileContent")])
            resolved.outputPresentation = .init(kind: "fileContent", provenance: "requested")
        case "edit":
            resolved.inputPresentation = .init(fields: ["path": .init(role: "filePath"), "edits": .init(role: "edits")])
            resolved.outputPresentation = .init(kind: "diffOfEdits", provenance: "result")
        case "ask":
            resolved.outputPresentation = .init(kind: "interactive")
        default:
            break
        }
        return resolved
    }
}
