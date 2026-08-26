import Foundation

/// Parser + command simulator for Mermaid `gitGraph`.
///
/// Spec: https://mermaid.js.org/syntax/gitgraph.html
///
/// Walks official commands in order (`commit`, `branch`, `checkout`/`switch`,
/// `merge`, `cherry-pick`) and produces a resolved commit graph. Cherry-pick
/// rules match the official docs: existing id, other branch, current branch
/// has a commit, merge needs an immediate parent.
enum MermaidGitGraphParser {

    nonisolated static func parse(
        lines: [String],
        options: GitGraphOptions = GitGraphOptions()
    ) -> GitGraphDiagram {
        var orientation = GitGraphOrientation.lr
        var error: String?

        var commits: [String: GitGraphCommit] = [:]
        var commitOrder: [String] = []
        var branchHeads: [String: String?] = [options.mainBranchName: nil]
        var branchConfig: [String: Int?] = [options.mainBranchName: options.mainBranchOrder]
        var branchAppearance: [String] = [options.mainBranchName]
        var currentBranch = options.mainBranchName
        var headId: String?
        var seq = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("%%") { continue }

            if let remainder = consumingKeyword(line, "gitGraph")
                ?? consumingKeyword(line, "gitgraph") {
                orientation = parseOrientation(remainder)
                continue
            }

            if error != nil { continue }

            if let remainder = consumingKeyword(line, "commit") {
                if let typeError = parseCommit(
                    remainder,
                    currentBranch: currentBranch,
                    headId: headId,
                    seq: &seq,
                    commits: &commits,
                    commitOrder: &commitOrder,
                    branchHeads: &branchHeads
                ) {
                    error = typeError
                } else {
                    headId = branchHeads[currentBranch] ?? nil
                }
                continue
            }

            if let remainder = consumingKeyword(line, "branch") {
                error = parseBranch(
                    remainder,
                    headId: headId,
                    branchHeads: &branchHeads,
                    branchConfig: &branchConfig,
                    branchAppearance: &branchAppearance,
                    currentBranch: &currentBranch
                )
                continue
            }

            if let remainder = consumingKeyword(line, "checkout")
                ?? consumingKeyword(line, "switch") {
                error = parseCheckout(
                    remainder,
                    branchHeads: branchHeads,
                    currentBranch: &currentBranch,
                    headId: &headId
                )
                continue
            }

            if let remainder = consumingKeyword(line, "merge") {
                error = parseMerge(
                    remainder,
                    currentBranch: currentBranch,
                    headId: &headId,
                    seq: &seq,
                    commits: &commits,
                    commitOrder: &commitOrder,
                    branchHeads: &branchHeads
                )
                continue
            }

            if let remainder = consumingKeyword(line, "cherry-pick") {
                error = parseCherryPick(
                    remainder,
                    currentBranch: currentBranch,
                    headId: &headId,
                    seq: &seq,
                    commits: &commits,
                    commitOrder: &commitOrder,
                    branchHeads: &branchHeads
                )
                continue
            }
        }

        let branches = orderedBranches(
            appearance: branchAppearance,
            config: branchConfig,
            mainName: options.mainBranchName,
            mainOrder: options.mainBranchOrder
        )
        let orderedCommits = commitOrder.compactMap { commits[$0] }
        return GitGraphDiagram(
            orientation: orientation,
            options: options,
            branches: branches,
            commits: orderedCommits,
            error: error
        )
    }

    // MARK: - Orientation

    /// Official tokens are only `LR:` / `TB:` / `BT:` after `gitGraph`.
    private static func parseOrientation(_ remainder: String) -> GitGraphOrientation {
        let trimmed = remainder.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .lr }
        let token = trimmed.split(whereSeparator: \.isWhitespace).map(String.init).first ?? trimmed
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        switch cleaned.uppercased() {
        case "LR":
            return leftover(after: cleaned, in: trimmed) ? .unsupported(trimmed) : .lr
        case "TB":
            return leftover(after: cleaned, in: trimmed) ? .unsupported(trimmed) : .tb
        case "BT":
            return leftover(after: cleaned, in: trimmed) ? .unsupported(trimmed) : .bt
        default:
            return .unsupported(cleaned)
        }
    }

    private static func leftover(after token: String, in trimmed: String) -> Bool {
        let rest = trimmed.drop(while: { $0.isWhitespace })
        return rest.lowercased().hasPrefix(token.lowercased())
            && rest.dropFirst(token.count).contains(where: { !$0.isWhitespace && $0 != ":" })
    }

    // MARK: - Commands

    private static func parseCommit(
        _ remainder: String,
        currentBranch: String,
        headId: String?,
        seq: inout Int,
        commits: inout [String: GitGraphCommit],
        commitOrder: inout [String],
        branchHeads: inout [String: String?]
    ) -> String? {
        let attrs = parseAttrs(remainder)
        if let typeText = attrs["type"], parseStyle(typeText) == nil {
            return "Unknown gitGraph commit type: \(typeText)"
        }
        let style = attrs["type"].flatMap(parseStyle) ?? .normal
        let id = attrs["id"] ?? "c\(seq)"
        if commits[id] != nil {
            return "Commit with id:\(id) already exists"
        }
        let commit = GitGraphCommit(
            id: id,
            style: style,
            tag: attrs["tag"],
            branch: currentBranch,
            parents: headId.map { [$0] } ?? [],
            seq: seq
        )
        seq += 1
        commits[id] = commit
        commitOrder.append(id)
        branchHeads[currentBranch] = id
        return nil
    }

    private static func parseBranch(
        _ remainder: String,
        headId: String?,
        branchHeads: inout [String: String?],
        branchConfig: inout [String: Int?],
        branchAppearance: inout [String],
        currentBranch: inout String
    ) -> String? {
        let (name, rest) = parseName(remainder)
        guard let name, !name.isEmpty else {
            return "branch requires a name"
        }
        if branchHeads[name] != nil {
            return "Trying to create an existing branch. (Help: Either use a new name if you want create a new branch or try using \"checkout \(name)\")"
        }
        let attrs = parseAttrs(rest)
        let order = attrs["order"].flatMap { Int($0) }
        branchHeads[name] = headId
        branchConfig[name] = order
        branchAppearance.append(name)
        currentBranch = name
        return nil
    }

    private static func parseCheckout(
        _ remainder: String,
        branchHeads: [String: String?],
        currentBranch: inout String,
        headId: inout String?
    ) -> String? {
        let (name, _) = parseName(remainder)
        guard let name, !name.isEmpty else {
            return "checkout requires a branch name"
        }
        guard branchHeads.keys.contains(name) else {
            return "Trying to checkout branch which is not yet created. (Help try using \"branch \(name)\")"
        }
        currentBranch = name
        if let id = branchHeads[name] ?? nil {
            headId = id
        } else {
            headId = nil
        }
        return nil
    }

    private static func parseMerge(
        _ remainder: String,
        currentBranch: String,
        headId: inout String?,
        seq: inout Int,
        commits: inout [String: GitGraphCommit],
        commitOrder: inout [String],
        branchHeads: inout [String: String?]
    ) -> String? {
        let (name, rest) = parseName(remainder)
        guard let other = name, !other.isEmpty else {
            return "merge requires a branch name"
        }
        if currentBranch == other {
            return "Incorrect usage of \"merge\". Cannot merge a branch to itself"
        }
        guard let currentId = headId else {
            return "Incorrect usage of \"merge\". Current branch (\(currentBranch))has no commits"
        }
        guard branchHeads.keys.contains(other) else {
            return "Incorrect usage of \"merge\". Branch to be merged (\(other)) does not exist"
        }
        guard let otherId = branchHeads[other] ?? nil else {
            return "Incorrect usage of \"merge\". Branch to be merged (\(other)) has no commits"
        }
        if currentId == otherId {
            return "Incorrect usage of \"merge\". Both branches have same head"
        }
        let attrs = parseAttrs(rest)
        if let typeText = attrs["type"], parseStyle(typeText) == nil {
            return "Unknown gitGraph commit type: \(typeText)"
        }
        let override = attrs["type"].flatMap(parseStyle)
        let customId = attrs["id"]
        if let customId, commits[customId] != nil {
            return "Incorrect usage of \"merge\". Commit with id:\(customId) already exists, use different custom id"
        }
        let id = customId ?? "c\(seq)"
        let style = override ?? .merge
        let commit = GitGraphCommit(
            id: id,
            style: style == .normal ? .merge : style,
            tag: attrs["tag"],
            branch: currentBranch,
            parents: [currentId, otherId],
            seq: seq,
            isMerge: true
        )
        seq += 1
        commits[id] = commit
        commitOrder.append(id)
        branchHeads[currentBranch] = id
        headId = id
        return nil
    }

    private static func parseCherryPick(
        _ remainder: String,
        currentBranch: String,
        headId: inout String?,
        seq: inout Int,
        commits: inout [String: GitGraphCommit],
        commitOrder: inout [String],
        branchHeads: inout [String: String?]
    ) -> String? {
        let attrs = parseAttrs(remainder)
        guard let sourceId = attrs["id"], !sourceId.isEmpty else {
            return "Incorrect usage of \"cherryPick\". Source commit id should exist and provided"
        }
        guard let source = commits[sourceId] else {
            return "Incorrect usage of \"cherryPick\". Source commit id should exist and provided"
        }
        let parentId = attrs["parent"]
        if let parentId, !source.parents.contains(parentId) {
            return "Invalid operation: The specified parent commit is not an immediate parent of the cherry-picked commit."
        }
        if source.isMerge && parentId == nil {
            return "Incorrect usage of cherry-pick: If the source commit is a merge commit, an immediate parent commit must be specified."
        }
        if source.branch == currentBranch {
            return "Incorrect usage of \"cherryPick\". Source commit is already on current branch"
        }
        guard let currentId = headId else {
            return "Incorrect usage of \"cherry-pick\". Current branch (\(currentBranch))has no commits"
        }
        let tag = attrs["tag"] ?? "cherry-pick:\(sourceId)"
        let id = "c\(seq)"
        let commit = GitGraphCommit(
            id: id,
            style: .cherryPick,
            tag: tag,
            branch: currentBranch,
            parents: [currentId, sourceId],
            seq: seq,
            cherrySourceId: sourceId,
            cherryParentId: parentId
        )
        seq += 1
        commits[id] = commit
        commitOrder.append(id)
        branchHeads[currentBranch] = id
        headId = id
        return nil
    }

    // MARK: - Branch order

    /// Official precedence: main (mainBranchOrder, default 0), then
    /// unordered branches in appearance order, then ordered branches.
    private static func orderedBranches(
        appearance: [String],
        config: [String: Int?],
        mainName: String,
        mainOrder: Int
    ) -> [GitGraphBranch] {
        var result: [(GitGraphBranch, Double)] = []
        for (index, name) in appearance.enumerated() {
            let declared = (name == mainName) ? (config[name] ?? mainOrder) : config[name] ?? nil
            let sort: Double
            if let declared {
                sort = Double(declared)
            } else if name == mainName {
                sort = Double(mainOrder)
            } else {
                sort = Double(index) / 1000
            }
            result.append((GitGraphBranch(name: name, order: declared ?? (name == mainName ? mainOrder : nil)), sort))
        }
        result.sort { $0.1 < $1.1 }
        return result.map(\.0)
    }

    // MARK: - Tokens

    private static func parseStyle(_ raw: String) -> GitGraphCommitStyle? {
        switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
        case "NORMAL": return .normal
        case "REVERSE": return .reverse
        case "HIGHLIGHT": return .highlight
        default: return nil
        }
    }

    /// First token as a name (`develop` or `"cherry-pick"`), leftover attrs.
    private static func parseName(_ remainder: String) -> (String?, String) {
        let trimmed = remainder.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, "") }
        if let (quoted, leftover) = parseQuotedPrefix(trimmed) {
            return (quoted, leftover)
        }
        let chars = Array(trimmed)
        var end = 0
        while end < chars.count, !chars[end].isWhitespace, chars[end] != ":" {
            end += 1
        }
        // Don't swallow `order:` as the name.
        if end == 0 { return (nil, trimmed) }
        let name = String(chars[0..<end])
        let leftover = String(chars[end...]).trimmingCharacters(in: .whitespaces)
        return (name, leftover)
    }

    /// `id: "x" type: HIGHLIGHT tag: "v1"` — values may be quoted.
    private static func parseAttrs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var rest = text.trimmingCharacters(in: .whitespaces)
        while !rest.isEmpty {
            guard let colon = rest.firstIndex(of: ":") else { break }
            let key = String(rest[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            rest = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { break }
            if let (quoted, leftover) = parseQuotedPrefix(rest) {
                result[key] = quoted
                rest = leftover
                continue
            }
            let token = rest.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? rest
            result[key] = token
            if token.count < rest.count {
                rest = String(rest.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
            } else {
                rest = ""
            }
        }
        return result
    }

    private static func parseQuotedPrefix(_ text: String) -> (String, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else { return nil }
        var index = trimmed.index(after: trimmed.startIndex)
        var escaped = false
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<index])
                let leftover = String(trimmed[trimmed.index(after: index)...])
                    .trimmingCharacters(in: .whitespaces)
                return (MermaidTextUtils.normalizeLabel(inner), leftover)
            }
            index = trimmed.index(after: index)
        }
        return nil
    }

    private static func consumingKeyword(_ text: String, _ keyword: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let key = keyword.lowercased()
        guard trimmed.lowercased().hasPrefix(key) else { return nil }
        if trimmed.count == key.count { return "" }
        let nextIndex = trimmed.index(trimmed.startIndex, offsetBy: key.count)
        let next = trimmed[nextIndex]
        if next.isWhitespace || next == ":" || next == "\"" || next == "'" {
            return String(trimmed[nextIndex...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
