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
            sessionId: sessionId,
            interactionContext: interactionContext,
            workspaceID: workspaceId,
            serverBaseURL: connection?.apiClient?.baseURL,
            fetchWorkspaceFile: connection?.apiClient.map { client in
                { workspaceID, path in
                    try await client.fetchWorkspaceFile(workspaceID: workspaceID, path: path)
                }
            },
            fetchSessionFile: connection?.apiClient.map { client in
                { workspaceID, sessionID, path in
                    try await client.getSessionFileData(workspaceId: workspaceID, sessionId: sessionID, path: path)
                }
            }
        )
    }

    func userRowConfiguration(itemID _: String, item: ChatItem) -> UserTimelineRowConfiguration? {
        guard case .userMessage(_, let text, let images, _) = item else { return nil }

        // Fork/branch actions now live in Session Timeline sheet so selected-text
        // interactions in row bubbles are never blocked by context-menu competition.
        // Keep row-level copy + selected-text actions only.
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
            onOpenPathPill: { [workspaceId, weak apiClient = connection?.apiClient, interactionContext = self.interactionContext] pill, sourceView in
                guard let workspaceId, !workspaceId.isEmpty,
                      let apiClient,
                      let presenter = sourceView.nearestViewController() else {
                    return
                }

                let view = FileBrowserContentView(
                    workspaceId: workspaceId,
                    filePath: pill.path,
                    fileName: pill.label,
                    fileSize: nil
                )
                .environment(\.apiClient, apiClient)
                .environment(\.selectedTextActionScope, interactionContext.selectedTextPiRouter.map(SelectedTextActionScope.activeSession))

                let host = UIHostingController(rootView: view)
                let navigation = UINavigationController(rootViewController: host)
                navigation.modalPresentationStyle = .pageSheet
                presenter.present(navigation, animated: true)
            },
            canFork: canFork,
            onFork: forkAction,
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

    func permissionRowConfiguration(item: ChatItem) -> PermissionTimelineRowConfiguration? {
        switch item {
        case .permission(let request):
            return PermissionTimelineRowConfiguration(
                outcome: .expired,
                tool: request.tool,
                summary: request.displaySummary
            )

        case .permissionResolved(_, let outcome, let tool, let summary):
            return PermissionTimelineRowConfiguration(
                outcome: outcome,
                tool: tool,
                summary: summary
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
                onToggleExpand: onToggleExpand
            )
        }

        if let subagentCompletion = SubagentCompletionPresentation.parse(from: message) {
            return SubagentCompletionTimelineRowConfiguration(
                presentation: subagentCompletion,
                rawMessage: message
            )
        }

        return SystemTimelineRowConfiguration(message: message)
    }

    func errorRowConfiguration(item: ChatItem) -> ErrorTimelineRowConfiguration? {
        guard case .error(_, let message) = item else { return nil }
        return ErrorTimelineRowConfiguration(message: message)
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
            resultSegments: toolSegmentStore?.resultSegments(for: itemID),
            startedAt: reducer?.toolStartTime(for: itemID),
            elapsedSeconds: reducer?.toolElapsed(for: itemID)
        )

        let interactionCtx = self.interactionContext
        let attachmentFetcher: ((String) async throws -> Data)? = if let workspaceId, let apiClient = connection?.apiClient {
            { [sessionId] attachmentId in
                try await apiClient.fetchSessionAttachment(
                    workspaceId: workspaceId,
                    sessionId: sessionId,
                    attachmentId: attachmentId
                )
            }
        } else {
            nil
        }
        let bashPolicyCommand = ToolCallFormatting.normalized(tool) == "bash"
            ? context.args?["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : ""
        var configuration = ToolPresentationBuilder.build(
            itemID: itemID,
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            context: context
        )
        configuration.expandedContent = VoiceTimelinePresentationAdapter.expandedContent(
            from: audioLifecycleCoordinator?.presentation.timelinePresentation(for: itemID),
            fallback: configuration.expandedContent
        )
        return configuration
            .withSelectedTextPi(router: interactionCtx.selectedTextPiRouter, sessionId: interactionCtx.sessionId)
            .withAudioPlayer(audioPlayer)
            .withSessionAttachmentFetcher(attachmentFetcher)
            .withBashCommandPolicyRuleAction(
                makeBashCommandPolicyRuleAction(command: bashPolicyCommand)
            )
    }

    private func makeBashCommandPolicyRuleAction(
        command: String
    ) -> (@MainActor (BashCommandPolicyRuleDecision) async throws -> Void)? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty,
              let apiClient = connection?.apiClient else {
            return nil
        }

        let scope = bashCommandPolicyRuleScope
        let sessionId = self.sessionId
        return { decision in
            try await Self.upsertBashCommandPolicyRule(
                apiClient: apiClient,
                command: trimmedCommand,
                decision: decision,
                scope: scope,
                sessionId: sessionId
            )
        }
    }

    private var bashCommandPolicyRuleScope: BashCommandPolicyRuleScope {
        let trimmedWorkspaceId = self.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedWorkspaceId, !trimmedWorkspaceId.isEmpty {
            return .workspace(trimmedWorkspaceId)
        }
        return .global
    }

    @discardableResult
    private static func upsertBashCommandPolicyRule(
        apiClient: APIClient,
        command: String,
        decision: BashCommandPolicyRuleDecision,
        scope: BashCommandPolicyRuleScope,
        sessionId: String
    ) async throws -> PolicyRuleRecord {
        let label = decision.ruleLabel(for: command)
        let visibleRules = try await apiClient.listPolicyRules(workspaceId: scope.workspaceId)

        if let existingTargetRule = preferredExactBashPolicyRule(
            in: visibleRules,
            command: command,
            scope: scope
        ) {
            return try await apiClient.patchPolicyRule(
                ruleId: existingTargetRule.id,
                request: PolicyRulePatchRequest(
                    decision: decision.rawValue,
                    label: label,
                    tool: "bash",
                    pattern: command,
                    executable: existingTargetRule.executable
                )
            )
        }

        let sessionExecutable = preferredExactBashPolicyRule(
            in: visibleRules,
            command: command,
            sessionId: sessionId
        )?.executable

        return try await apiClient.createPolicyRule(
            request: PolicyRuleCreateRequest(
                decision: decision.rawValue,
                label: label,
                tool: "bash",
                pattern: command,
                executable: sessionExecutable,
                scope: scope.rawValue,
                workspaceId: scope.workspaceId,
                sessionId: nil,
                expiresAt: nil
            )
        )
    }

    private static func preferredExactBashPolicyRule(
        in rules: [PolicyRuleRecord],
        command: String,
        scope: BashCommandPolicyRuleScope
    ) -> PolicyRuleRecord? {
        preferredExactBashPolicyRule(in: rules, command: command) { scope.matches($0) }
    }

    private static func preferredExactBashPolicyRule(
        in rules: [PolicyRuleRecord],
        command: String,
        sessionId: String
    ) -> PolicyRuleRecord? {
        preferredExactBashPolicyRule(in: rules, command: command) {
            $0.scope == "session" && $0.sessionId == sessionId
        }
    }

    private static func preferredExactBashPolicyRule(
        in rules: [PolicyRuleRecord],
        command: String,
        matching matches: (PolicyRuleRecord) -> Bool
    ) -> PolicyRuleRecord? {
        rules
            .filter { rule in
                rule.tool == "bash"
                    && rule.pattern == command
                    && matches(rule)
            }
            .sorted { lhs, rhs in
                let lhsHasExecutable = lhs.executable?.isEmpty == false
                let rhsHasExecutable = rhs.executable?.isEmpty == false
                if lhsHasExecutable != rhsHasExecutable {
                    return lhsHasExecutable && !rhsHasExecutable
                }
                return lhs.createdAt > rhs.createdAt
            }
            .first
    }

    private enum BashCommandPolicyRuleScope: Sendable {
        case global
        case workspace(String)

        var rawValue: String {
            switch self {
            case .global:
                "global"
            case .workspace:
                "workspace"
            }
        }

        var workspaceId: String? {
            switch self {
            case .global:
                nil
            case .workspace(let workspaceId):
                workspaceId
            }
        }

        func matches(_ rule: PolicyRuleRecord) -> Bool {
            switch self {
            case .global:
                return rule.scope == "global"
            case .workspace(let workspaceId):
                return rule.scope == "workspace" && rule.workspaceId == workspaceId
            }
        }
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
