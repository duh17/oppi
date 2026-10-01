import SwiftUI
import UIKit

private extension UIView {
    func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

// MARK: - Row Configuration Builders

extension ChatTimelineCollectionHost.Controller {
    func assistantRowConfiguration(itemID: String, item: ChatItem) -> AssistantTimelineRowConfiguration? {
        guard var rowConfiguration = assistantBaseRowConfiguration(itemID: itemID, item: item) else {
            return nil
        }
        let preparationRequest = makeTimelinePreparationRequest(
            itemID: itemID,
            text: rowConfiguration.renderedMarkdownSource,
            isStreaming: rowConfiguration.isStreaming,
            rowConfiguration: rowConfiguration
        )
        _ = preparationRunway.request(preparationRequest, demand: .visible)
        rowConfiguration.preparedBlocks = preparationRunway.preparedBlocks(
            for: preparationRequest
        )
        rowConfiguration.preparationRevision = preparationRunway.presentationRevision(
            for: preparationRequest
        )
        rowConfiguration.imagePreparationContext = preparationRunway.imagePreparationContext(
            for: preparationRequest
        )
        return rowConfiguration
    }

    func assistantBaseRowConfiguration(itemID: String, item: ChatItem) -> AssistantTimelineRowConfiguration? {
        guard case .assistantMessage(_, let text, _) = item else { return nil }

        let isStreaming = isAssistantStreamingPresentationActive
            && itemID == streamingAssistantID

        // Unified native markdown renderer — handles all content (plain
        // text, rich markdown, code blocks, tables) via
        // AssistantMarkdownContentView.
        return AssistantTimelineRowConfiguration(
            text: text,
            isStreaming: isStreaming,
            canFork: false,
            onFork: nil,
            itemID: itemID,
            sessionId: sessionId,
            agentId: agentId,
            agentIcon: agentIcon,
            iconAssetCache: iconAssetCache,
            interactionContext: interactionContext,
            resourceAccess: markdownResourceAccess(includesInlineMedia: true),
            resourcePressure: resourcePressure
        )
    }

    /// Tool-output capabilities for this timeline's session, resolved when asked. Nil while
    /// the content owner has no API client or the timeline has no route scope. Requests are
    /// built by the content adapter; the timeline only decides when to use them.
    var toolOutputAccess: SessionToolOutputAccess? {
        sessionContent?.toolOutputAccess(sessionId: sessionId, routeScope: routeScope)
    }

    /// The Markdown resource access for this timeline's own source. Identity is always the
    /// timeline's bound scope; providers come from the content adapter, which owns routing,
    /// readiness, and origin policy. Rows never build those closures.
    private func markdownResourceAccess(includesInlineMedia: Bool) -> MarkdownResourceAccess {
        guard let sessionContent else {
            return MarkdownResourceAccess(
                identity: MarkdownResourceAccess.Identity(
                    serverID: serverId,
                    workspaceID: workspaceId,
                    sessionID: sessionId
                )
            )
        }
        return sessionContent.markdownResourceAccess(
            serverID: serverId,
            workspaceID: workspaceId,
            sessionID: sessionId,
            audioPlayer: audioPlayer,
            includesInlineMedia: includesInlineMedia
        )
    }

    func userRowConfiguration(itemID: String, item: ChatItem) -> UserTimelineRowConfiguration? {
        guard case .userMessage(_, let text, let images, _) = item else { return nil }

        // Fork/branch actions now live in Session Timeline sheet so review-comment
        // selection in row bubbles is never blocked by context-menu competition.
        // Keep row-level copy + review-comment selection only.
        let canFork = false
        let forkAction: (() -> Void)? = nil

        // Unified native user row — handles both text-only and image messages.
        return UserTimelineRowConfiguration(
            text: text,
            images: images,
            fetchWorkspaceFileData: sessionContent?.sessionFileReader(
                workspaceId: workspaceId,
                sessionId: sessionId
            ),
            onOpenPathPill: { [weak self] pill, sourceView in
                self?.openUserMessagePathPill(pill, from: sourceView)
            },
            canFork: canFork,
            onFork: forkAction,
            itemID: itemID,
            interactionContext: interactionContext
        )
    }

    /// Maps a pill tap to a typed destination request. Building and presenting the destination
    /// belongs to chat composition (`openDestination`); the timeline supplies source identity,
    /// review-comment scope, and the view/presenter it was tapped from.
    func openUserMessagePathPill(_ pill: UserMessagePathPill, from sourceView: UIView) {
        guard let destination = pill.timelineDestination,
              let workspaceId, !workspaceId.isEmpty,
              let presenter = sourceView.nearestViewController(),
              let openDestination else {
            return
        }

        let target: ChatTimelineDestination
        switch destination {
        case .commitDetail:
            target = .commitDetail(sha: pill.path)
        case .workspaceFileBrowser:
            target = .workspaceFile(pill)
        }
        openDestination(
            ChatTimelineDestinationRequest(
                destination: target,
                serverId: serverId,
                workspaceId: workspaceId,
                sessionId: sessionId,
                reviewCommentSelectionScope: interactionContext.reviewCommentSelectionRouter
                    .map(ReviewCommentSelectionScope.activeSession),
                sourceView: sourceView,
                presenter: presenter
            )
        )
    }

    func thinkingRowConfiguration(itemID: String, item: ChatItem) -> ThinkingTimelineRowConfiguration? {
        guard case .thinking(_, let preview, _, let isDone) = item else { return nil }

        let maxBubbleHeight = ThinkingRowHeightPolicy.defaultMaxBubbleHeight

        var configuration = ThinkingTimelineRowConfiguration(
            isDone: isDone,
            previewText: preview,
            fullText: toolOutputStore?.fullOutput(for: itemID),
            maxBubbleHeight: maxBubbleHeight,
            itemID: itemID,
            sourceLabel: currentExtensionHiddenThinkingLabel,
            interactionContext: interactionContext
        )
        configuration.openFullScreen = onOpenChatReader
        return configuration
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
            audioPlayer: audioPlayer
        )
    }

    func systemEventRowConfiguration(itemID: String, item: ChatItem) -> (any UIContentConfiguration)? {
        if case .customEvent(_, let message, let presentation) = item {
            // The collection cell has 16pt side insets and the card has 12pt
            // inner padding on each side; measure the preview at its actual width.
            let bodyWidth = max(1, (collectionView?.bounds.width ?? 375) - 56)
            return CustomTimelineRowConfiguration(
                message: message,
                presentation: presentation,
                isExpanded: reducer?.expandedItemIDs.contains(itemID) == true,
                bodyWidth: bodyWidth,
                openFullScreen: onOpenChatReader,
                onToggleExpand: { [weak self] in
                    guard let self, let collectionView = self.collectionView,
                          let index = self.currentIDs.firstIndex(of: itemID) else { return }
                    self.collectionView(
                        collectionView,
                        didSelectItemAt: IndexPath(item: index, section: 0)
                    )
                }
            )
        }

        if case .cacheMiss(_, let message) = item {
            return SystemTimelineRowConfiguration(message: message, style: .warning)
        }

        if case .notice(_, let message) = item {
            return SystemTimelineRowConfiguration(message: message, style: .warning)
        }

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
                onToggleExpand: onToggleExpand,
                interactionContext: interactionContext,
                itemID: itemID,
                resourcePressure: resourcePressure
            )
        }

        return SystemTimelineRowConfiguration(message: message)
    }

    func errorRowConfiguration(item: ChatItem) -> ErrorTimelineRowConfiguration? {
        guard case .error(_, let message) = item else { return nil }
        return ErrorTimelineRowConfiguration(message: message)
    }

    func toolRowConfiguration(itemID: String, item: ChatItem) -> (any UIContentConfiguration)? {
        guard case .toolCall(_, let tool, let argsSummary, let outputPreview, _, let isError, let isDone) = item else {
            return nil
        }

        let details = toolDetailsStore?.details(for: itemID)
        let isExpanded = reducer?.expandedItemIDs.contains(itemID) == true
        let hasCanonicalAudioDetails = ToolPresentationBuilder.toolAudioPresentationDetails(from: details) != nil
        let hasLifecycleVoicePresentation = audioLifecycleCoordinator.map {
            $0.presentation.timelinePresentation(for: itemID) != .hidden
        } ?? false

        // Ordinary collapsed tools paint chrome only. Branch before full-output
        // lookup, expanded descriptors, media adapters, and fetcher closures.
        // Voice-while-collapsed stays full when serialized audio details exist
        // or the lifecycle coordinator already has a non-hidden presentation.
        if !isExpanded && !hasCanonicalAudioDetails && !hasLifecycleVoicePresentation {
            return makeCollapsedToolRowConfiguration(
                itemID: itemID,
                tool: tool,
                argsSummary: argsSummary,
                outputPreview: outputPreview,
                isError: isError,
                isDone: isDone,
                details: details
            )
        }

        return makeFullToolRowConfiguration(
            itemID: itemID,
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            details: details
        )
    }

    private func makeCollapsedToolRowConfiguration(
        itemID: String,
        tool: String,
        argsSummary: String,
        outputPreview: String,
        isError: Bool,
        isDone: Bool,
        details: JSONValue?
    ) -> CollapsedToolTimelineRowConfiguration {
        var context = ToolPresentationBuilder.Context(
            args: toolArgsStore?.args(for: itemID),
            details: details,
            expandedItemIDs: [],
            fullOutput: "",
            isLoadingOutput: false,
            callSegments: toolSegmentStore?.callSegments(for: itemID),
            resultSegments: toolSegmentStore?.resultSegments(for: itemID),
            startedAt: reducer?.toolStartTime(for: itemID),
            elapsedSeconds: reducer?.toolElapsed(for: itemID)
        )
        context.display = toolArgsStore?.display(for: itemID)
        let chrome = ToolPresentationBuilder.build(
            itemID: itemID,
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            isInterrupted: reducer?.isToolInterrupted(itemID) == true,
            context: context
        )
        return CollapsedToolTimelineRowConfiguration(chrome: chrome)
    }

    private func makeFullToolRowConfiguration(
        itemID: String,
        tool: String,
        argsSummary: String,
        outputPreview: String,
        isError: Bool,
        isDone: Bool,
        details: JSONValue?
    ) -> ToolTimelineRowConfiguration {
        var context = ToolPresentationBuilder.Context(
            args: toolArgsStore?.args(for: itemID),
            details: details,
            expandedItemIDs: reducer?.expandedItemIDs ?? [],
            fullOutput: toolOutputStore?.fullOutput(for: itemID) ?? "",
            isLoadingOutput: toolOutputLoader.isLoading(itemID),
            callSegments: toolSegmentStore?.callSegments(for: itemID),
            resultSegments: toolSegmentStore?.resultSegments(for: itemID),
            startedAt: reducer?.toolStartTime(for: itemID),
            elapsedSeconds: reducer?.toolElapsed(for: itemID)
        )

        context.previewOnly = toolOutputStore?.hasCompleteOutput(for: itemID) != true
        let outputBytes = toolOutputStore?.outputByteCount(for: itemID) ?? 0
        context.totalBytes = outputBytes > 0 ? outputBytes : nil
        context.display = toolArgsStore?.display(for: itemID)
        context.inputPresentation = toolArgsStore?.inputPresentation(for: itemID)
        context.nestedCalls = toolDetailsStore?.nestedCalls(for: itemID)
        let interactionCtx = self.interactionContext
        let sessionContent = self.sessionContent
        // Stored tool attachments belong to the session, not its workspace path.
        // Keep their fetchers available while workspace metadata is still resolving.
        let attachmentFetcher: ((String) async throws -> Data)? = sessionContent.map { content in
            { [sessionId, routeScope] attachmentId in
                try await content.fetchSessionAttachment(
                    sessionId: sessionId,
                    attachmentId: attachmentId,
                    routeScope: routeScope
                )
            }
        }
        let attachmentMediaSourceProvider: ((String, String?, String?) async throws -> AuthenticatedMediaSource)? = sessionContent.map { content in
            { [sessionId, routeScope] attachmentId, mimeType, sourceFileExtension in
                try await content.makeSessionAttachmentMediaSource(
                    sessionId: sessionId,
                    attachmentId: attachmentId,
                    contentTypeHint: mimeType,
                    sourceFileExtension: sourceFileExtension,
                    routeScope: routeScope
                )
            }
        }
        // Session-file rows can be created from cached trace data before the API client or
        // session workspace metadata is ready. Resolve both when the row actually fetches.
        let sessionFileDataFetcher: ((String) async throws -> Data)? = sessionContent.map { content in
            { [sessionId, workspaceId] path in
                try await content.fetchSessionFileData(
                    workspaceId: workspaceId,
                    sessionId: sessionId,
                    path: path
                )
            }
        }
        let sessionFileMediaSourceProvider: ((String) async throws -> AuthenticatedMediaSource)? = sessionContent.map { content in
            { [sessionId, workspaceId] path in
                let pathExtension = (path as NSString).pathExtension
                return try await content.makeSessionFileMediaSource(
                    workspaceId: workspaceId,
                    sessionId: sessionId,
                    path: path,
                    contentTypeHint: MediaMimeType.videoMimeType(forPathExtension: pathExtension),
                    sourceFileExtension: pathExtension
                )
            }
        }
        var configuration = ToolPresentationBuilder.build(
            itemID: itemID,
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            isInterrupted: reducer?.isToolInterrupted(itemID) == true,
            context: context
        )
        configuration.expandedContent = AudioTimelinePresentationAdapter.expandedContent(
            from: audioLifecycleCoordinator?.presentation.timelinePresentation(for: itemID),
            fallback: configuration.expandedContent
        )
        configuration.resourcePressure = resourcePressure
        if let intent = configuration.currentFileOpenIntent,
           let onOpenCurrentFile {
            configuration.openCurrentFile = {
                onOpenCurrentFile(intent.path)
            }
        }
        if let onOpenChatReader {
            configuration.openFullScreen = onOpenChatReader
        }
        // Tool Markdown hosts file reads only; inline media stays unavailable there.
        configuration.resourceAccess = markdownResourceAccess(includesInlineMedia: false)
        if case .markdown(_, let filePath) = configuration.expandedContent {
            let trimmed = filePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                configuration.sourceFilePath = trimmed
            }
        }
        if let access = toolOutputAccess {
            configuration.toolOutputSidecarSource = access.sidecarSource(toolCallId: itemID)
            configuration.fetchCompleteToolOutput = access.completeOutputFetch(
                tool: tool,
                toolCallId: itemID,
                store: toolOutputStore
            )
        }
        return configuration
            .withReviewCommentSelection(router: interactionCtx.reviewCommentSelectionRouter, sessionId: interactionCtx.sessionId)
            .withAudioPlayer(audioPlayer)
            .withSessionAttachmentFetcher(attachmentFetcher)
            .withSessionAttachmentMediaSourceProvider(attachmentMediaSourceProvider)
            .withSessionFileDataFetcher(sessionFileDataFetcher)
            .withSessionFileMediaSourceProvider(sessionFileMediaSourceProvider)
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
            case failed
            case branchSummary
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

        if message.hasPrefix("Branch context:") {
            let detail = detailAfterFirstColon(from: message)
            return CompactionPresentation(phase: .branchSummary, detail: detail, tokensBefore: nil)
        }

        if message.hasPrefix("Context overflow \u{2014} compacting")
            || message.hasPrefix("Compacting context") {
            return CompactionPresentation(phase: .inProgress, detail: nil, tokensBefore: nil)
        }

        if message.hasPrefix("Compaction cancelled") {
            return CompactionPresentation(phase: .cancelled, detail: nil, tokensBefore: nil)
        }

        if message.hasPrefix("Compaction failed") {
            return CompactionPresentation(
                phase: .failed,
                detail: detailAfterFirstColon(from: message),
                tokensBefore: nil
            )
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

        // Anchor the compaction row so expand/collapse doesn't shift it.
        let anchoredCV = collectionView as? AnchoredCollectionView
        var expandGeneration: UInt64?
        if let idx = currentIDs.firstIndex(of: itemID) {
            expandGeneration = anchoredCV?.setExpandCollapseAnchor(
                indexPath: IndexPath(item: idx, section: 0)
            )
        }

        reconfigureItems([itemID], in: collectionView)

        // Clear after async layout passes settle.
        DispatchQueue.main.async { [weak anchoredCV, expandGeneration] in
            DispatchQueue.main.async { [weak anchoredCV, expandGeneration] in
                if let expandGeneration {
                    anchoredCV?.clearExpandCollapseAnchor(generation: expandGeneration)
                }
            }
        }
    }

    private static func compactionDetail(from message: String) -> String? {
        detailAfterFirstColon(from: message)
    }

    private static func detailAfterFirstColon(from message: String) -> String? {
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
