import Foundation

/// Built-in slash commands supported in Oppi RPC mode.
enum SlashBuiltinCommand: Equatable {
    case compact(customInstructions: String?)
    case newSession
    case setSessionName(name: String?)
    case modelPicker

    static func parse(_ text: String) -> SlashBuiltinCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return nil
        }

        let withoutSlash = String(trimmed.dropFirst())
        guard !withoutSlash.isEmpty else {
            return nil
        }

        let parts = withoutSlash.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
        guard let rawCommand = parts.first, !rawCommand.isEmpty else {
            return nil
        }

        let command = rawCommand.lowercased()
        let argument = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        switch command {
        case "compact":
            return .compact(customInstructions: argument.isEmpty ? nil : argument)

        case "new":
            return .newSession

        case "name":
            return .setSessionName(name: argument.isEmpty ? nil : argument)

        case "model":
            return .modelPicker

        default:
            return nil
        }
    }
}
