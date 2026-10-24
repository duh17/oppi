import Foundation

@MainActor
enum GuidedControlSessionInitialPrompt {
    struct PreparedPrompt: Equatable {
        let message: String
        let sentComments: [ReviewComment]

    }

    static func make(
        domain: ControlSessionDomain,
        intent: ControlSessionIntent,
        targetId: String?,
        targetName: String?,
        targetPath: String?,
        workspaceId: String?,
        workspaceName: String?,
        userRequest: String,
        comments: ChatReviewCommentsController?
    ) -> PreparedPrompt {
        let completeRequest = comments?.appendReviewBlock(
            to: userRequest,
            pathFormatting: ChatViewController.reviewCommentPathFormattingPolicy(controlDomain: domain)
        ) ?? userRequest
        return PreparedPrompt(
            message: ControlSessionStarterPrompt.make(
                domain: domain,
                intent: intent,
                targetId: targetId,
                targetName: targetName,
                targetPath: targetPath,
                workspaceId: workspaceId,
                workspaceName: workspaceName,
                userRequest: completeRequest
            ),
            sentComments: comments?.stagedComments ?? []
        )
    }
}

@MainActor
struct GuidedControlSessionAtomicLaunch {
    let request: APIClient.CreateControlSessionRequest
    let sourceDraftText: String
    let initialPrompt: GuidedControlSessionInitialPrompt.PreparedPrompt

    static func make(
        domain: ControlSessionDomain,
        intent: ControlSessionIntent,
        targetId: String?,
        targetName: String?,
        targetPath: String?,
        workspaceId: String?,
        workspaceName: String?,
        sourceDraftText: String,
        cleanRequest: String,
        sessionName: String,
        model: String?,
        thinking: ThinkingLevel,
        requestId: String,
        comments: ChatReviewCommentsController?
    ) -> Self {
        let initialPrompt = GuidedControlSessionInitialPrompt.make(
            domain: domain,
            intent: intent,
            targetId: targetId,
            targetName: targetName,
            targetPath: targetPath,
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            userRequest: cleanRequest,
            comments: comments
        )
        return Self(
            request: .init(
                domain: domain,
                intent: intent,
                targetId: targetId,
                targetName: targetName,
                name: sessionName,
                model: model,
                thinking: thinking,
                prompt: initialPrompt.message,
                launchIdempotencyKey: requestId
            ),
            sourceDraftText: sourceDraftText,
            initialPrompt: initialPrompt
        )
    }

    func unchangedSentCommentIds(in currentComments: [ReviewComment]) -> [String] {
        initialPrompt.sentComments.compactMap { sentComment in
            currentComments.first(where: { $0.id == sentComment.id }) == sentComment
                ? sentComment.id
                : nil
        }
    }

    func shouldClearDraft(currentText: String) -> Bool {
        currentText == sourceDraftText
    }
}

@MainActor
enum GuidedControlSessionLaunchCoordinator {
    struct Completion {
        let session: Session
        let starterPromptDelivered: Bool
        let sessionTarget: WorkspaceSessionNavTarget
        let sentCommentIdsToDispose: [String]
        let shouldClearDraft: Bool
        let hasUnsentContentAfterDisposal: Bool
    }

    static func prepare(
        launch: GuidedControlSessionAtomicLaunch,
        existingSession: Session?,
        starterPromptDelivered: Bool,
        serverId: String?,
        fallbackServerId: String?,
        currentDraftText: String,
        currentComments: [ReviewComment],
        create: (APIClient.CreateControlSessionRequest) async throws -> (session: Session, prompted: Bool),
        onSessionCreated: (Session, Bool) -> Void
    ) async throws -> Completion {
        let prepared = try await ControlRevisionSessionLaunchCoordinator.prepare(
            existingSession: existingSession,
            starterPromptDelivered: starterPromptDelivered,
            create: { try await create(launch.request) },
            onSessionCreated: onSessionCreated
        )
        let target = try ControlRevisionCommentNavigation.makeAtomicLaunchSessionTarget(
            serverId: serverId,
            fallbackServerId: fallbackServerId,
            toSessionId: prepared.session.id
        )
        let sentCommentIdsToDispose = launch.unchangedSentCommentIds(in: currentComments)
        let sentCommentIdSet = Set(sentCommentIdsToDispose)
        let shouldClearDraft = launch.shouldClearDraft(currentText: currentDraftText)
        let hasRemainingComments = currentComments.contains { !sentCommentIdSet.contains($0.id) }
        return Completion(
            session: prepared.session,
            starterPromptDelivered: prepared.starterPromptDelivered,
            sessionTarget: target,
            sentCommentIdsToDispose: sentCommentIdsToDispose,
            shouldClearDraft: shouldClearDraft,
            hasUnsentContentAfterDisposal: !shouldClearDraft || hasRemainingComments
        )
    }
}

enum GuidedControlSessionComposerReviewComments {
    struct Presentation: Equatable {
        let pendingCount: Int
        let showsPill: Bool
        let title: String?
        let pillCountText: String?
    }

    static func presentation(stagedCount: Int) -> Presentation {
        let showsPill = ReviewCommentStripChrome.shouldShowPill(
            stagedCount: stagedCount,
            isDraftingComment: false
        )
        return Presentation(
            pendingCount: stagedCount,
            showsPill: showsPill,
            title: showsPill ? ReviewCommentStripChrome.stashTitle(count: stagedCount) : nil,
            pillCountText: showsPill ? ReviewCommentStripChrome.pillCountText(count: stagedCount) : nil
        )
    }
}
