import Foundation

/// Active autocomplete mode for the composer at the current cursor position.
enum ComposerAutocompleteContext: Equatable {
    case none
    case slash(query: String)
    case atFile(query: String)
}

enum ComposerAutocomplete {
    static let maxSuggestions = 8

    /// Parse autocomplete context from the trailing token in the composer text.
    ///
    /// Phase 1 slash contract:
    /// - Slash commands only trigger when the token starts at message start.
    /// - Suggestions close after whitespace (command token is complete).
    static func context(for text: String) -> ComposerAutocompleteContext {
        guard let tokenRange = activeTokenRange(in: text) else {
            return .none
        }

        let token = text[tokenRange]
        if token.hasPrefix("/") {
            guard tokenRange.lowerBound == text.startIndex else {
                return .none
            }
            return .slash(query: String(token.dropFirst()))
        }

        if token.hasPrefix("@") {
            return .atFile(query: String(token.dropFirst()))
        }

        return .none
    }

    static func slashSuggestions(
        query: String,
        commands: [SlashCommand],
        limit: Int = maxSuggestions
    ) -> [SlashCommand] {
        guard !commands.isEmpty else { return [] }

        let normalized = query.lowercased()
        var deduped: [String: SlashCommand] = [:]

        for command in commands {
            let key = command.name.lowercased()
            if deduped[key] == nil {
                deduped[key] = command
            }
        }

        let filtered: [SlashCommand]
        if normalized.isEmpty {
            filtered = Array(deduped.values)
        } else {
            filtered = deduped.values.filter { command in
                command.name.lowercased().contains(normalized)
            }
        }

        let sorted = filtered.sorted { lhs, rhs in
            let lhsName = lhs.name.lowercased()
            let rhsName = rhs.name.lowercased()
            let lhsPrefix = lhsName.hasPrefix(normalized)
            let rhsPrefix = rhsName.hasPrefix(normalized)

            if lhsPrefix != rhsPrefix {
                return lhsPrefix && !rhsPrefix
            }

            if lhsName == rhsName {
                return lhs.source.sortRank < rhs.source.sortRank
            }

            return lhsName < rhsName
        }

        return Array(sorted.prefix(max(0, limit)))
    }

    static func insertSlashCommand(_ command: SlashCommand, into text: String) -> String {
        insertSlashCommand(named: command.name, into: text)
    }

    static func insertSlashCommand(named commandName: String, into text: String) -> String {
        guard let tokenRange = activeTokenRange(in: text),
              case .slash = context(for: text) else {
            return text
        }

        var updated = text
        updated.replaceSubrange(tokenRange, with: "/\(commandName) ")
        return updated
    }

    static func insertFileSuggestion(_ suggestion: FileSuggestion, into text: String) -> String {
        guard let tokenRange = activeTokenRange(in: text) else {
            return text
        }

        let token = text[tokenRange]
        guard token.hasPrefix("@") else {
            return text
        }

        var updated = text
        let suffix = suggestion.isDirectory ? "" : " "
        updated.replaceSubrange(tokenRange, with: "@\(suggestion.path)\(suffix)")
        return updated
    }

    /// Returns the range of the active `@` token in the text, if any.
    /// Used by the pill system to strip the `@query` when converting to a pill.
    static func activeAtTokenRange(in text: String) -> Range<String.Index>? {
        guard let range = activeTokenRange(in: text) else { return nil }
        let token = text[range]
        guard token.hasPrefix("@") else { return nil }
        return range
    }

    // MARK: - Internals

    private static func activeTokenRange(in text: String) -> Range<String.Index>? {
        guard let last = text.last, !last.isWhitespace else {
            return nil
        }

        var start = text.endIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace {
                break
            }
            start = previous
        }

        return start..<text.endIndex
    }
}
