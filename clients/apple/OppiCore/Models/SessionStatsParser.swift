import Foundation

/// Decode `get_session_stats` command_result data once. Platform views paint.
enum SessionStatsParser {
    static func parse(_ data: JSONValue?) -> SessionStatsSnapshot? {
        guard let root = data?.objectValue,
              let tokenObject = root["tokens"]?.objectValue else {
            return nil
        }

        let input = parseInt(tokenObject["input"]) ?? 0
        let output = parseInt(tokenObject["output"]) ?? 0
        let cacheRead = parseInt(tokenObject["cacheRead"]) ?? 0
        let cacheWrite = parseInt(tokenObject["cacheWrite"]) ?? 0
        let total = parseInt(tokenObject["total"]) ?? (input + output + cacheRead + cacheWrite)
        let cost = parseDouble(root["cost"]) ?? 0

        return SessionStatsSnapshot(
            tokens: SessionTokenStats(
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                total: total
            ),
            cost: cost,
            cacheWaste: parseCacheWaste(root["cacheWaste"]),
            modelBreakdown: parseModelBreakdown(root["modelBreakdown"]),
            contextComposition: parseContextComposition(root["contextComposition"]),
            loadedResources: parseLoadedResources(root["loadedResources"])
        )
    }

    private static func parseCacheWaste(_ value: JSONValue?) -> SessionCacheWasteSnapshot? {
        guard let object = value?.objectValue else { return nil }
        return SessionCacheWasteSnapshot(
            missedTokens: parseInt(object["missedTokens"]) ?? 0,
            missedCost: parseDouble(object["missedCost"]) ?? 0,
            missCount: parseInt(object["missCount"]) ?? 0
        )
    }

    private static func parseModelBreakdown(_ value: JSONValue?) -> [SessionModelUsageSnapshot] {
        value?.arrayValue?.compactMap { item in
            guard let object = item.objectValue,
                  let model = object["model"]?.stringValue else {
                return nil
            }
            return SessionModelUsageSnapshot(
                provider: object["provider"]?.stringValue,
                model: model,
                tokens: parseInt(object["tokens"]) ?? 0,
                cost: parseDouble(object["cost"]) ?? 0
            )
        } ?? []
    }

    private static func parseLoadedResources(_ value: JSONValue?) -> SessionLoadedResourcesSnapshot? {
        guard let object = value?.objectValue else { return nil }
        return SessionLoadedResourcesSnapshot(
            skills: parseResourceList(object["skills"]),
            extensions: parseResourceList(object["extensions"])
        )
    }

    private static func parseResourceList(_ value: JSONValue?) -> [SessionResourceSnapshot] {
        value?.arrayValue?.compactMap { item in
            guard let object = item.objectValue,
                  let name = object["name"]?.stringValue else { return nil }
            return SessionResourceSnapshot(
                name: name,
                description: object["description"]?.stringValue,
                path: object["path"]?.stringValue ?? ""
            )
        } ?? []
    }

    private static func parseContextComposition(_ value: JSONValue?) -> SessionContextCompositionSnapshot? {
        guard let object = value?.objectValue else {
            return nil
        }

        let piSystemPromptChars = parseInt(object["piSystemPromptChars"]) ?? 0
        let piSystemPromptTokens = parseInt(object["piSystemPromptTokens"]) ?? 0
        let agentsChars = parseInt(object["agentsChars"]) ?? 0
        let agentsTokens = parseInt(object["agentsTokens"]) ?? 0

        let agentsFiles: [ContextFileTokenSnapshot] = object["agentsFiles"]?.arrayValue?.compactMap { item in
            guard let file = item.objectValue,
                  let path = file["path"]?.stringValue else {
                return nil
            }

            return ContextFileTokenSnapshot(
                path: path,
                chars: parseInt(file["chars"]) ?? 0,
                tokens: parseInt(file["tokens"]) ?? 0
            )
        } ?? []

        let skillsListingChars = parseInt(object["skillsListingChars"]) ?? 0
        let skillsListingTokens = parseInt(object["skillsListingTokens"]) ?? 0

        return SessionContextCompositionSnapshot(
            piSystemPromptChars: piSystemPromptChars,
            piSystemPromptTokens: piSystemPromptTokens,
            agentsChars: agentsChars,
            agentsTokens: agentsTokens,
            agentsFiles: agentsFiles,
            skillsListingChars: skillsListingChars,
            skillsListingTokens: skillsListingTokens
        )
    }

    private static func parseInt(_ value: JSONValue?) -> Int? {
        if let number = value?.numberValue {
            return Int(number)
        }
        if let string = value?.stringValue {
            return Int(string)
        }
        return nil
    }

    private static func parseDouble(_ value: JSONValue?) -> Double? {
        if let number = value?.numberValue {
            return number
        }
        if let string = value?.stringValue {
            return Double(string)
        }
        return nil
    }
}
