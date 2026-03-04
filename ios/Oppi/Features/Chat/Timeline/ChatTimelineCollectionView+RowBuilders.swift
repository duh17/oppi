import UIKit

// MARK: - Row Configuration Builders

extension ChatTimelineCollectionHost.Controller {
    func assistantRowConfiguration(itemID: String, item: ChatItem) -> AssistantTimelineRowConfiguration? {
        guard case .assistantMessage(_, let text, _) = item else { return nil }

        let isStreaming = itemID == streamingAssistantID

        // Unified native markdown renderer — handles all content (plain
        // text, rich markdown, code blocks, tables) via
        // AssistantMarkdownContentView.
        return AssistantTimelineRowConfiguration(
            text: text,
            isStreaming: isStreaming,
            canFork: false,
            onFork: nil,
            themeID: currentThemeID
        )
    }

    func userRowConfiguration(itemID: String, item: ChatItem) -> UserTimelineRowConfiguration? {
        guard case .userMessage(_, let text, let images, _) = item else { return nil }

        let canFork = UUID(uuidString: itemID) == nil && onFork != nil
        let forkAction: (() -> Void)?
        if canFork {
            forkAction = { [weak self] in
                self?.onFork?(itemID)
            }
        } else {
            forkAction = nil
        }

        // Unified native user row — handles both text-only and image messages.
        return UserTimelineRowConfiguration(
            text: text,
            images: images,
            canFork: canFork,
            onFork: forkAction,
            themeID: currentThemeID
        )
    }

    func thinkingRowConfiguration(itemID: String, item: ChatItem) -> ThinkingTimelineRowConfiguration? {
        guard case .thinking(_, let preview, _, let isDone) = item else { return nil }

        return ThinkingTimelineRowConfiguration(
            isDone: isDone,
            previewText: preview,
            fullText: toolOutputStore?.fullOutput(for: itemID),
            themeID: currentThemeID
        )
    }

    func audioRowConfiguration(item: ChatItem) -> AudioClipTimelineRowConfiguration? {
        guard case .audioClip(let id, let title, let fileURL, _) = item,
              let audioPlayer else {
            return nil
        }

        return AudioClipTimelineRowConfiguration(
            id: id,
            title: title,
            fileURL: fileURL,
            audioPlayer: audioPlayer,
            themeID: currentThemeID
        )
    }

    func permissionRowConfiguration(item: ChatItem) -> PermissionTimelineRowConfiguration? {
        switch item {
        case .permission(let request):
            return PermissionTimelineRowConfiguration(
                outcome: .expired,
                tool: request.tool,
                summary: request.displaySummary,
                themeID: currentThemeID
            )

        case .permissionResolved(_, let outcome, let tool, let summary):
            return PermissionTimelineRowConfiguration(
                outcome: outcome,
                tool: tool,
                summary: summary,
                themeID: currentThemeID
            )

        default:
            return nil
        }
    }

    func systemEventRowConfiguration(itemID: String, item: ChatItem) -> (any UIContentConfiguration)? {
        guard case .systemEvent(_, let message) = item else { return nil }

        if let compaction = Self.compactionPresentation(from: message) {
            let isExpanded = reducer?.expandedItemIDs.contains(itemID) == true
            let onToggleExpand: (() -> Void)?
            if compaction.canExpand {
                onToggleExpand = { [weak self] in
                    self?.toggleCompactionExpansion(itemID: itemID)
                }
            } else {
                onToggleExpand = nil
            }

            return CompactionTimelineRowConfiguration(
                presentation: compaction,
                isExpanded: isExpanded,
                themeID: currentThemeID,
                onToggleExpand: onToggleExpand
            )
        }

        return SystemTimelineRowConfiguration(message: message, themeID: currentThemeID)
    }

    func errorRowConfiguration(item: ChatItem) -> ErrorTimelineRowConfiguration? {
        guard case .error(_, let message) = item else { return nil }
        return ErrorTimelineRowConfiguration(message: message, themeID: currentThemeID)
    }

    func toolRowConfiguration(itemID: String, item: ChatItem) -> ToolTimelineRowConfiguration? {
        guard case .toolCall(_, let tool, let argsSummary, let outputPreview, _, let isError, let isDone) = item else {
            return nil
        }

        let context = ToolPresentationBuilder.Context(
            args: toolArgsStore?.args(for: itemID),
            details: toolDetailsStore?.details(for: itemID),
            expandedItemIDs: reducer?.expandedItemIDs ?? [],
            fullOutput: toolOutputStore?.fullOutput(for: itemID) ?? "",
            isLoadingOutput: toolOutputLoader.isLoading(itemID),
            callSegments: toolSegmentStore?.callSegments(for: itemID),
            resultSegments: toolSegmentStore?.resultSegments(for: itemID)
        )

        return ToolPresentationBuilder.build(
            itemID: itemID,
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            context: context
        )
    }
}

// MARK: - Compaction Parsing

extension ChatTimelineCollectionHost.Controller {
    struct CompactionPresentation: Equatable {
        enum Phase: Equatable {
            case inProgress
            case completed
            case retrying
            case cancelled
        }

        let phase: Phase
        let detail: String?
        let tokensBefore: Int?

        var canExpand: Bool {
            guard let detail else { return false }
            let cleaned = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return false }
            return cleaned.count > 140 || cleaned.contains("\n")
        }
    }

    static func compactionPresentation(from rawMessage: String) -> CompactionPresentation? {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }

        if message.hasPrefix("Context overflow \u{2014} compacting")
            || message.hasPrefix("Compacting context") {
            return CompactionPresentation(phase: .inProgress, detail: nil, tokensBefore: nil)
        }

        if message.hasPrefix("Compaction cancelled") {
            return CompactionPresentation(phase: .cancelled, detail: nil, tokensBefore: nil)
        }

        if message.hasPrefix("Context compacted \u{2014} retrying") {
            return CompactionPresentation(phase: .retrying, detail: nil, tokensBefore: nil)
        }

        guard message.hasPrefix("Context compacted") else {
            return nil
        }

        let detail = compactionDetail(from: message)
        let tokensBefore = compactionTokensBefore(from: message)

        return CompactionPresentation(
            phase: .completed,
            detail: detail,
            tokensBefore: tokensBefore
        )
    }

    // MARK: - Compaction Expansion Toggle

    private func toggleCompactionExpansion(itemID: String) {
        guard let reducer,
              let collectionView,
              let item = currentItemByID[itemID],
              case .systemEvent(_, let message) = item,
              let compaction = Self.compactionPresentation(from: message),
              compaction.canExpand else {
            return
        }

        if reducer.expandedItemIDs.contains(itemID) {
            reducer.expandedItemIDs.remove(itemID)
        } else {
            reducer.expandedItemIDs.insert(itemID)
        }

        reconfigureItems([itemID], in: collectionView)
    }

    private static func compactionDetail(from message: String) -> String? {
        guard let separator = message.firstIndex(of: ":") else {
            return nil
        }

        let start = message.index(after: separator)
        let detail = message[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? nil : detail
    }

    private static func compactionTokensBefore(from message: String) -> Int? {
        guard let compactedRange = message.range(of: "Context compacted") else {
            return nil
        }

        let suffix = message[compactedRange.upperBound...]
        guard let openParen = suffix.firstIndex(of: "("),
              let closeParen = suffix[openParen...].firstIndex(of: ")") else {
            return nil
        }

        let inside = suffix[suffix.index(after: openParen)..<closeParen]
        guard String(inside).localizedCaseInsensitiveContains("token") else {
            return nil
        }

        let digits = inside.filter { $0.isNumber }
        guard !digits.isEmpty else {
            return nil
        }

        return Int(String(digits))
    }
}
