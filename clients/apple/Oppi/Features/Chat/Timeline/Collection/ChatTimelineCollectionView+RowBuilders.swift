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
        let sourceSession = connection?.sessionStore.session(id: sessionId)
        let sourceWorkspaceRuntime: WorkspaceRuntime? = {
            guard let connection, let workspaceId else { return nil }
            if let serverId {
                return connection.workspaceStore.workspacesByServer[serverId]?
                    .first(where: { $0.id == workspaceId })?.runtime
            }
            return connection.workspaceStore.workspaces.first(where: { $0.id == workspaceId })?.runtime
        }()
        let sourceSessionResolved = sourceSession?.workspaceId == workspaceId
        let firstCheckout = WorkspaceWikiLinkFileLookupPolicy.firstCheckout(
            sourceSessionResolved: sourceSessionResolved,
            sourceSessionWorktreeID: sourceSessionResolved ? sourceSession?.worktreeId : nil
        )
        return AssistantTimelineRowConfiguration(
            text: text,
            isStreaming: isStreaming,
            canFork: false,
            onFork: nil,
            itemID: itemID,
            sessionId: sessionId,
            agentId: agentId,
            agentIcon: agentIcon,
            iconAssetCache: connection?.iconAssetCache,
            interactionContext: interactionContext,
            serverID: serverId,
            workspaceID: workspaceId,
            worktreeId: firstCheckout,
            serverBaseURL: connection?.apiClient?.baseURL,
            fetchWorkspaceFile: connection?.apiClient.map { client in
                return { [sourceSession] workspaceID, path in
                    // Missing or foreign source session lists main (nil),
                    // matching WorkspaceWikiLinkFileLookupPolicy.
                    let sourceSessionResolved = sourceSession?.workspaceId == workspaceID
                    return try await WorkspaceMarkdownImageFileLookup.fetch(
                        workspaceID: workspaceID,
                        path: path,
                        sourceSessionResolved: sourceSessionResolved,
                        sourceSessionWorktreeID: sourceSessionResolved ? sourceSession?.worktreeId : nil,
                        fetchWorkspaceFile: { @Sendable workspaceID, path, worktreeId in
                            try await client.fetchWorkspaceFile(
                                workspaceID: workspaceID,
                                path: path,
                                worktreeId: worktreeId
                            )
                        }
                    )
                }
            },
            fetchSessionFile: nil,
            fetchHostFile: connection.map { connection in
                return { [workspaceId, sessionId, firstCheckout, sourceWorkspaceRuntime] path in
                    try await connection.fetchHostFileWhenReady(
                        path: path,
                        workspaceId: workspaceId,
                        sessionId: sessionId,
                        worktreeId: firstCheckout,
                        workspaceRuntime: sourceWorkspaceRuntime
                    )
                }
            },
            makeMarkdownVideoSource: connection.map { connection in
                { [workspaceId, sessionId, firstCheckout, sourceWorkspaceRuntime] embed in
                    try await connection.makeMarkdownVideoMediaSourceWhenReady(
                        embed: embed,
                        workspaceId: workspaceId,
                        sessionId: sessionId,
                        worktreeId: firstCheckout,
                        workspaceRuntime: sourceWorkspaceRuntime
                    )
                }
            },
            makeMarkdownAudioSource: connection.map { connection in
                { [workspaceId, sessionId, firstCheckout, sourceWorkspaceRuntime] embed in
                    try await connection.makeMarkdownAudioMediaSourceWhenReady(
                        embed: embed,
                        workspaceId: workspaceId,
                        sessionId: sessionId,
                        worktreeId: firstCheckout,
                        workspaceRuntime: sourceWorkspaceRuntime
                    )
                }
            },
            makeTimedTextSidecar: connection.map { connection in
                { [workspaceId, sessionId, firstCheckout, sourceWorkspaceRuntime] mediaPath, kind, reference in
                    await connection.loadTimedTextSidecarWhenReady(
                        mediaPath: mediaPath,
                        kind: kind,
                        reference: reference,
                        workspaceId: workspaceId,
                        sessionId: sessionId,
                        worktreeId: firstCheckout,
                        workspaceRuntime: sourceWorkspaceRuntime
                    )
                }
            },
            audioPlayer: audioPlayer
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
            fetchWorkspaceFileData: connection?.apiClient.flatMap { client in
                guard let workspaceId else { return nil }
                return { path in
                    try await client.getSessionFileData(
                        workspaceId: workspaceId,
                        sessionId: self.sessionId,
                        path: path
                    )
                }
            },
            onOpenPathPill: { [workspaceId, serverId, weak apiClient = connection?.apiClient, interactionContext = self.interactionContext] pill, sourceView in
                guard pill.opensWorkspaceFileBrowser,
                      let workspaceId, !workspaceId.isEmpty,
                      let apiClient,
                      let presenter = sourceView.nearestViewController() else {
                    return
                }

                let isHostPath = MarkdownWikiLinkRewriter.resolvedHostPath(pill.path) != nil
                let view = FileBrowserContentView(
                    workspaceId: workspaceId,
                    serverId: serverId,
                    filePath: pill.path,
                    fileName: pill.label,
                    source: isHostPath ? .hostFile : .workspaceFile,
                    sessionId: self.sessionId,
                    fileSize: nil
                )
                .environment(\.apiClient, apiClient)
                .environment(\.reviewCommentSelectionScope, interactionContext.reviewCommentSelectionRouter.map(ReviewCommentSelectionScope.activeSession))

                let host = UIHostingController(rootView: view)
                let navigation = UINavigationController(rootViewController: host)
                FullScreenViewerPresentationPolicy.configureLargePresentation(
                    navigation,
                    traitCollection: sourceView.traitCollection
                )
                presenter.present(navigation, animated: true)
            },
            canFork: canFork,
            onFork: forkAction,
            itemID: itemID,
            interactionContext: interactionContext
        )
    }

    func thinkingRowConfiguration(itemID: String, item: ChatItem) -> ThinkingTimelineRowConfiguration? {
        guard case .thinking(_, let preview, _, let isDone) = item else { return nil }

        let maxBubbleHeight = ThinkingRowHeightPolicy.defaultMaxBubbleHeight

        return ThinkingTimelineRowConfiguration(
            isDone: isDone,
            previewText: preview,
            fullText: toolOutputStore?.fullOutput(for: itemID),
            maxBubbleHeight: maxBubbleHeight,
            itemID: itemID,
            sourceLabel: currentExtensionHiddenThinkingLabel,
            interactionContext: interactionContext
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
            audioPlayer: audioPlayer
        )
    }

    func systemEventRowConfiguration(itemID: String, item: ChatItem) -> (any UIContentConfiguration)? {
        if case .customEvent(_, let message, let presentation) = item {
            return CustomTimelineRowConfiguration(
                message: message,
                presentation: presentation
            )
        }

        if case .cacheMiss(_, let message) = item {
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
                itemID: itemID
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
        let context = ToolPresentationBuilder.Context(
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
        let context = ToolPresentationBuilder.Context(
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

        let interactionCtx = self.interactionContext
        // Stored tool attachments belong to the session, not its workspace path.
        // Keep their fetchers available while workspace metadata is still resolving.
        let attachmentFetcher: ((String) async throws -> Data)? = connection.map { connection in
            { [sessionId, routeScope] attachmentId in
                try await connection.fetchSessionAttachmentWhenReady(
                    sessionId: sessionId,
                    attachmentId: attachmentId,
                    routeScope: routeScope
                )
            }
        }
        let attachmentMediaSourceProvider: ((String, String?, String?) async throws -> AuthenticatedMediaSource)? = connection.map { connection in
            { [sessionId, routeScope] attachmentId, mimeType, sourceFileExtension in
                try await connection.makeSessionAttachmentMediaSourceWhenReady(
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
        let sessionFileDataFetcher: ((String) async throws -> Data)? = connection.map { connection in
            { [sessionId, workspaceId] path in
                try await connection.fetchSessionFileDataWhenReady(
                    workspaceId: workspaceId,
                    sessionId: sessionId,
                    path: path
                )
            }
        }
        let sessionFileMediaSourceProvider: ((String) async throws -> AuthenticatedMediaSource)? = connection.map { connection in
            { [sessionId, workspaceId] path in
                let pathExtension = (path as NSString).pathExtension
                return try await connection.makeSessionFileMediaSourceWhenReady(
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
        if let idx = currentIDs.firstIndex(of: itemID) {
            anchoredCV?.setExpandCollapseAnchor(
                indexPath: IndexPath(item: idx, section: 0)
            )
        }

        reconfigureItems([itemID], in: collectionView)

        // Clear after async layout passes settle.
        DispatchQueue.main.async { [weak anchoredCV] in
            DispatchQueue.main.async { [weak anchoredCV] in
                anchoredCV?.clearExpandCollapseAnchor()
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
