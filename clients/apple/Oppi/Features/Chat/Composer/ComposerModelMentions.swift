import Foundation

/// `@` mentions of models. The composer suggests catalog models next to files
/// and inserts the model's canonical `provider/model-id` as plain text, so the
/// agent reads the exact id its tools accept; nothing is sent beyond the text.
///
/// Files stay the main `@` result, so models are kept from crowding them out:
/// at most `maxSuggestions` rows, only literal matches once the query is
/// non-empty (a path query never literally matches a model, so it offers none).
enum ComposerModelMentions {
    /// Models offered beside the file rows; the panel scrolls past five rows,
    /// so a few models leave the first files visible.
    static let maxSuggestions = 3

    /// How a model's fields match the query; a lower tier always ranks first.
    private enum MatchTier: Int, Comparable {
        /// The query starts a display name, canonical id, or provider.
        case prefix
        /// The query starts a word inside one (`son` in "Claude Sonnet").
        case wordStart
        /// The query appears inside a word.
        case substring

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The catalog models matching what follows `@`, best first, at most `maxSuggestions`.
    ///
    /// An empty query lists recent models, then the catalog. A non-empty query
    /// keeps only literal matches of display name, canonical id, or provider
    /// (the picker's fields), ranked prefix, then word start, then substring;
    /// within a tier the `FuzzyMatch` score decides, then recent picks, then
    /// the catalog's order. Fuzzy-only matches are dropped. A repeated
    /// canonical id shows once.
    static func suggestions(query: String, catalog: [ModelInfo], recentIDs: [String]) -> [ModelInfo] {
        var seen = Set<String>()
        let unique = catalog.filter { seen.insert(ModelSwitchPolicy.fullModelID(for: $0)).inserted }
        let recency = Dictionary(recentIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func recentRank(_ model: ModelInfo) -> Int {
            recency[ModelSwitchPolicy.fullModelID(for: model)] ?? Int.max
        }

        struct Candidate {
            let model: ModelInfo
            let tier: MatchTier
            let score: Int
            let order: Int
        }
        var candidates: [Candidate] = []
        if let fuzzy = FuzzyMatch.Query(query) {
            let literal = query.trimmingCharacters(in: .whitespacesAndNewlines)
            for (order, model) in unique.enumerated() {
                let fields = [model.name, ModelSwitchPolicy.fullModelID(for: model), model.provider]
                guard let tier = fields.compactMap({ literalTier(of: literal, in: $0) }).min() else { continue }
                let score = FuzzyMatch.bestScore(fuzzy, fields: fields) ?? 0
                candidates.append(Candidate(model: model, tier: tier, score: score, order: order))
            }
        } else {
            candidates = unique.enumerated().map { Candidate(model: $1, tier: .prefix, score: 0, order: $0) }
        }
        candidates.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let (l, r) = (recentRank(lhs.model), recentRank(rhs.model))
            if l != r { return l < r }
            return lhs.order < rhs.order
        }
        return candidates.prefix(maxSuggestions).map(\.model)
    }

    /// The best literal tier `query` reaches in `field`, or nil when it is
    /// not a contiguous run there.
    private static func literalTier(of query: String, in field: String) -> MatchTier? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var best: MatchTier?
        var searchRange = field.startIndex..<field.endIndex
        while let hit = field.range(of: query, options: options, range: searchRange) {
            if hit.lowerBound == field.startIndex { return .prefix }
            let previous = field[field.index(before: hit.lowerBound)]
            if !previous.isLetter, !previous.isNumber {
                best = .wordStart
            } else if best == nil {
                best = .substring
            }
            searchRange = field.index(after: hit.lowerBound)..<field.endIndex
        }
        return best
    }

    /// The panel's rows for an `@` mention: matching models, then the file
    /// suggestions the server returned. Empty outside an `@` token.
    @MainActor
    static func panelContent(
        for context: ComposerAutocompleteContext,
        catalog: [ModelInfo],
        files: [FileSuggestion]
    ) -> ComposerSuggestionPanelView.Content {
        guard case .atFile(let query) = context else { return .empty }
        let models = cache.suggestions(query: query, catalog: catalog, recentIDs: AppPreferences.RecentModels.load())
        return .mentions(models: models, files: files)
    }

    /// The last result, like `slashSuggestionCache`: a chrome refresh with the
    /// same query, catalog, and recents does not match again.
    @MainActor private static let cache = SuggestionCache()

    @MainActor
    private final class SuggestionCache {
        private var query: String?
        private var catalog: [ModelInfo] = []
        private var recentIDs: [String] = []
        private var result: [ModelInfo] = []

        func suggestions(query: String, catalog: [ModelInfo], recentIDs: [String]) -> [ModelInfo] {
            if self.query == query, self.catalog == catalog, self.recentIDs == recentIDs { return result }
            result = ComposerModelMentions.suggestions(query: query, catalog: catalog, recentIDs: recentIDs)
            self.query = query
            self.catalog = catalog
            self.recentIDs = recentIDs
            return result
        }
    }

    /// Replaces the active `@query` token with the model's canonical id and a
    /// trailing space; text without an active `@` token is unchanged.
    static func insert(_ model: ModelInfo, into text: String) -> String {
        guard let range = ComposerAutocomplete.activeAtTokenRange(in: text) else { return text }
        var updated = text
        updated.replaceSubrange(range, with: "\(ModelSwitchPolicy.fullModelID(for: model)) ")
        return updated
    }
}
