import SwiftUI

enum ReviewableControlMarkdownDraftKey {
    static func make(
        serverId: String?,
        fallbackServerId: String?,
        domain: ControlSessionDomain,
        targetId: String
    ) -> String {
        let resolvedServerId = serverId ?? fallbackServerId ?? "unscoped-server"
        return "\(resolvedServerId):\(domain.rawValue):\(targetId)"
    }
}

enum ReviewableControlMarkdownEditFlow: Equatable {
    case directSession
    case guidedRevision
}

struct ControlRevisionSheetHandoff {
    private var pendingTarget: WorkspaceSessionNavTarget?

    mutating func prepare(_ target: WorkspaceSessionNavTarget) {
        pendingTarget = target
    }

    mutating func completeAfterDismissal() -> WorkspaceSessionNavTarget? {
        defer { pendingTarget = nil }
        return pendingTarget
    }
}

@MainActor
enum ControlRevisionCommentTransfer {
    @discardableResult
    static func moveStagedComments(
        serverId: String?,
        fallbackServerId: String?,
        domain: ControlSessionDomain,
        targetId: String?,
        toSessionId: String,
        comments: ChatReviewCommentsController = ChatReviewCommentsController()
    ) throws -> Int {
        guard let targetId else { return 0 }
        let draftSessionId = ReviewableControlMarkdownDraftKey.make(
            serverId: serverId,
            fallbackServerId: fallbackServerId,
            domain: domain,
            targetId: targetId
        )
        return try comments.moveStagedComments(
            fromLocalScopeId: ReviewCommentLocalScope.controlDraft,
            fromSessionId: draftSessionId,
            toLocalScopeId: SessionRouteScope.control.composerDraftScopeID,
            toSessionId: toSessionId
        )
    }
}

enum ControlRevisionCommentNavigationError: Error, Equatable {
    case serverUnavailable
}

extension ControlRevisionCommentNavigationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            return "Could not open the new Oppi session"
        }
    }
}

@MainActor
enum ControlRevisionCommentNavigation {
    struct Handoff {
        let serverId: String
        let movedCount: Int
    }

    static func moveStagedComments(
        serverId: String?,
        fallbackServerId: String?,
        domain: ControlSessionDomain,
        targetId: String?,
        toSessionId: String,
        comments: ChatReviewCommentsController = ChatReviewCommentsController()
    ) throws -> Handoff {
        guard let resolvedServerId = serverId ?? fallbackServerId else {
            throw ControlRevisionCommentNavigationError.serverUnavailable
        }
        let movedCount = try ControlRevisionCommentTransfer.moveStagedComments(
            serverId: serverId,
            fallbackServerId: fallbackServerId,
            domain: domain,
            targetId: targetId,
            toSessionId: toSessionId,
            comments: comments
        )
        return Handoff(serverId: resolvedServerId, movedCount: movedCount)
    }

    /// Build the ordinary control-chat route after the durable comment move.
    /// A zero-comment draft is still a valid handoff; navigation must not be
    /// conditional on having review comments to transfer.
    static func makeSessionTarget(
        serverId: String?,
        fallbackServerId: String?,
        domain: ControlSessionDomain,
        targetId: String?,
        toSessionId: String,
        comments: ChatReviewCommentsController = ChatReviewCommentsController()
    ) throws -> WorkspaceSessionNavTarget {
        let handoff = try moveStagedComments(
            serverId: serverId,
            fallbackServerId: fallbackServerId,
            domain: domain,
            targetId: targetId,
            toSessionId: toSessionId,
            comments: comments
        )
        return WorkspaceSessionNavTarget(
            serverId: handoff.serverId,
            sessionId: toSessionId,
            routeScope: .control
        )
    }

    struct PreparedLaunchMessage {
        let sessionTarget: WorkspaceSessionNavTarget
        let message: String
        let sentCommentIds: [String]

        @MainActor
        func disposeSentComments(using comments: ChatReviewCommentsController) {
            comments.clearSent(ids: sentCommentIds)
        }
    }

    /// Move staged comments into the created control session, then build the
    /// first user message from the typed request plus the existing review block.
    /// The stash is cleared only after the caller reports a successful send.
    static func prepareLaunchMessage(
        request: String,
        serverId: String?,
        fallbackServerId: String?,
        domain: ControlSessionDomain,
        targetId: String?,
        toSessionId: String,
        comments: ChatReviewCommentsController = ChatReviewCommentsController()
    ) throws -> PreparedLaunchMessage {
        let sessionTarget = try makeSessionTarget(
            serverId: serverId,
            fallbackServerId: fallbackServerId,
            domain: domain,
            targetId: targetId,
            toSessionId: toSessionId,
            comments: comments
        )
        comments.load(
            localScopeId: SessionRouteScope.control.composerDraftScopeID,
            sessionId: toSessionId
        )
        let message = comments.appendReviewBlock(
            to: request,
            pathFormatting: ChatView.reviewCommentPathFormattingPolicy(controlDomain: domain)
        )
        return PreparedLaunchMessage(
            sessionTarget: sessionTarget,
            message: message,
            sentCommentIds: comments.stagedCommentIds
        )
    }
}

struct ControlRevisionSessionRetryState {
    var createdSession: Session?
    var starterPromptDelivered = false
    var requestId: String

    init(requestId: String = UUID().uuidString) {
        self.requestId = requestId
    }

    mutating func recordCreatedSession(_ session: Session, promptDelivered: Bool) {
        createdSession = session
        starterPromptDelivered = promptDelivered
    }

    mutating func resetForNextLaunch(requestId: String = UUID().uuidString) {
        createdSession = nil
        starterPromptDelivered = false
        self.requestId = requestId
    }
}

@MainActor
enum ControlRevisionSessionLaunchCoordinator {
    struct PreparedSession {
        let session: Session
        let starterPromptDelivered: Bool
    }

    static func prepare(
        existingSession: Session?,
        starterPromptDelivered: Bool,
        requestId: String,
        create: () async throws -> (session: Session, prompted: Bool),
        onSessionCreated: (Session, Bool) -> Void,
        activateSession: (Session) async throws -> Void,
        sendStarterPrompt: (Session, String) async throws -> Void
    ) async throws -> PreparedSession {
        let session: Session
        var delivered = starterPromptDelivered
        if let existingSession {
            session = existingSession
        } else {
            let response = try await create()
            session = response.session
            delivered = response.prompted
            onSessionCreated(session, delivered)
        }

        if !delivered {
            try await activateSession(session)
            try await sendStarterPrompt(session, requestId)
            delivered = true
        }
        return PreparedSession(session: session, starterPromptDelivered: delivered)
    }
}

/// Full-screen Markdown or text-file review that keeps selected-text comments
/// local until the user explicitly asks an Oppi control session to apply them.
struct ReviewableControlMarkdownView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(QuickCommentTemplateStore.self) private var quickCommentTemplateStore
    @Environment(\.dismiss) private var dismiss

    private let viewerContent: FullScreenCodeContent
    private let languageHint: String?
    private let usesEmbeddedPresentation: Bool
    let domain: ControlSessionDomain
    let targetId: String
    let targetName: String
    let sourceLabel: String
    let sourcePath: String
    let editFlow: ReviewableControlMarkdownEditFlow

    init(
        content: String,
        domain: ControlSessionDomain,
        targetId: String,
        targetName: String,
        sourceLabel: String,
        sourcePath: String,
        editFlow: ReviewableControlMarkdownEditFlow = .directSession
    ) {
        self.viewerContent = .markdown(content: content, filePath: sourcePath)
        self.languageHint = "markdown"
        self.usesEmbeddedPresentation = false
        self.domain = domain
        self.targetId = targetId
        self.targetName = targetName
        self.sourceLabel = sourceLabel
        self.sourcePath = sourcePath
        self.editFlow = editFlow
    }

    init(
        fileContent: String,
        domain: ControlSessionDomain,
        targetId: String,
        targetName: String,
        sourceLabel: String,
        sourcePath: String,
        editFlow: ReviewableControlMarkdownEditFlow = .directSession
    ) {
        self.viewerContent = .fromText(fileContent, filePath: sourcePath)
        self.languageHint = Self.languageHint(for: sourcePath)
        self.usesEmbeddedPresentation = true
        self.domain = domain
        self.targetId = targetId
        self.targetName = targetName
        self.sourceLabel = sourceLabel
        self.sourcePath = sourcePath
        self.editFlow = editFlow
    }

    @State private var comments = ChatReviewCommentsController()
    @State private var showCommentStash = false
    @State private var showGuidedRevision = false
    @State private var guidedSessionHandoff = ControlRevisionSheetHandoff()
    @State private var isCreatingSession = false
    @State private var createdSession: Session?
    @State private var starterPromptDelivered = false
    @State private var starterPromptRequestId = UUID().uuidString
    @State private var error: String?

    private var draftSessionId: String {
        ReviewableControlMarkdownDraftKey.make(
            serverId: connection.currentServerId,
            fallbackServerId: sessionStore.activeServerId,
            domain: domain,
            targetId: targetId
        )
    }

    private var selectionContext: ReviewCommentSelectionContext {
        ReviewCommentSelectionContext(
            dispatcher: selectionRouter,
            sessionId: draftSessionId,
            sourceLabel: sourceLabel,
            filePath: sourcePath,
            languageHint: languageHint
        )
    }

    private var selectionRouter: ReviewCommentSelectionRouter {
        ReviewCommentSelectionRouter(
            dispatch: { _ in },
            inlineSave: { body, request in
                saveComment(body: body, request: request)
            },
            inlineQuickComments: QuickCommentTemplate.quickCommentTemplates(
                quickCommentTemplateStore.templates
            )
        )
    }

    private var navigationActions: [FullScreenViewerNavigationAction] {
        [
            FullScreenViewerNavigationAction(
                id: "edit-in-session",
                title: isCreatingSession ? "Starting…" : "Edit",
                accessibilityLabel: "Edit in Oppi Session",
                isEnabled: !isCreatingSession,
                handler: {
                    switch editFlow {
                    case .directSession:
                        Task { await createOrOpenRevisionSession() }
                    case .guidedRevision:
                        showGuidedRevision = true
                    }
                }
            ),
            FullScreenViewerNavigationAction(
                id: "staged-comments",
                systemImage: comments.stagedCount == 0 ? "text.bubble" : "text.bubble.fill",
                accessibilityLabel: "Staged Comments",
                accessibilityValue: stagedCommentCountLabel,
                handler: {
                    showCommentStash = true
                }
            ),
        ]
    }

    private var stagedCommentCountLabel: String {
        let count = comments.stagedCount
        return count == 1 ? "1 staged comment" : "\(count) staged comments"
    }

    private var starterPrompt: String {
        ControlSessionStarterPrompt.make(
            domain: domain,
            intent: .revise,
            targetId: targetId,
            targetName: targetName,
            targetPath: domain == .skills ? sourcePath : nil,
            userRequest: "Inspect the current definition and wait for my staged review comments before proposing changes."
        )
    }

    var body: some View {
        viewer
        .task(id: draftSessionId) {
            comments.load(
                localScopeId: ReviewCommentLocalScope.controlDraft,
                sessionId: draftSessionId
            )
        }
        .sheet(isPresented: $showCommentStash) {
            ReviewCommentStashSheet(
                comments: comments.stagedComments,
                focusedCommentId: nil,
                onEdit: { comment, body in
                    if let updateError = comments.update(comment, body: body) {
                        error = updateError
                        return false
                    }
                    return true
                },
                onDelete: { comments.delete($0) },
                onClose: { showCommentStash = false }
            )
        }
        .sheet(isPresented: $showGuidedRevision, onDismiss: completeGuidedSessionHandoff) {
            GuidedControlSessionSheet(
                domain: domain,
                intent: .revise,
                targetId: targetId,
                targetName: targetName,
                targetPath: domain == .skills ? sourcePath : nil,
                placeholder: "Describe how this \(domainTitle) should change…",
                stagedComments: comments,
                onSessionPrepared: { target in
                    guidedSessionHandoff.prepare(target)
                    showGuidedRevision = false
                }
            )
        }
        .alert("Unable to Edit", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private var viewer: some View {
        if usesEmbeddedPresentation {
            EmbeddedFileViewerView(
                content: viewerContent,
                reviewCommentSelectionContext: selectionContext,
                navigationActions: navigationActions
            )
            .ignoresSafeArea(edges: .top)
        } else {
            FullScreenCodeView(
                content: viewerContent,
                reviewCommentSelectionContext: selectionContext,
                navigationActions: navigationActions
            )
        }
    }

    @MainActor
    private func completeGuidedSessionHandoff() {
        guard let target = guidedSessionHandoff.completeAfterDismissal() else { return }
        navigation.openWorkspaceSession(target)
    }

    private var domainTitle: String {
        switch domain {
        case .agents: "Agent"
        case .schedules: "Schedule"
        case .skills: "Skill"
        case .workspaces: "Workspace"
        }
    }

    private static func languageHint(for path: String) -> String? {
        switch FileType.detect(from: path, content: "") {
        case .markdown: "markdown"
        case .json: "json"
        case .code(let language): language.displayName
        case .latex: "latex"
        case .orgMode: "org"
        case .mermaid: "mermaid"
        case .graphviz: "dot"
        default: nil
        }
    }

    @MainActor
    private func saveComment(body: String, request: ReviewCommentSelectionRequest) -> Bool {
        if let saveError = comments.save(
            body: body,
            request: request,
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        ) {
            error = saveError
            return false
        }
        return true
    }

    @MainActor
    private func createOrOpenRevisionSession() async {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        defer { isCreatingSession = false }

        do {
            guard let apiClient else {
                error = "Server is offline"
                return
            }

            let prepared = try await ControlRevisionSessionLaunchCoordinator.prepare(
                existingSession: createdSession,
                starterPromptDelivered: starterPromptDelivered,
                requestId: starterPromptRequestId,
                create: {
                    // Persist the session first; prompt delivery then has its own
                    // stable request ID and observable command result.
                    let response = try await apiClient.createControlSession(.init(
                        domain: domain,
                        intent: .revise,
                        targetId: targetId,
                        targetName: targetName,
                        name: "Revise \(targetName)",
                        launchIdempotencyKey: starterPromptRequestId
                    ))
                    return (response.session, response.prompted == true)
                },
                onSessionCreated: { session, delivered in
                    createdSession = session
                    starterPromptDelivered = delivered
                    sessionStore.cacheSessionForNavigation(session)
                },
                activateSession: { session in
                    _ = try await apiClient.resumeSession(scope: .control, sessionId: session.id)
                },
                sendStarterPrompt: { session, requestId in
                    try await apiClient.sendSessionCommand(
                        scope: .control,
                        sessionId: session.id,
                        message: .prompt(
                            message: starterPrompt,
                            requestId: requestId,
                            clientTurnId: requestId
                        )
                    )
                }
            )
            let session = prepared.session
            starterPromptDelivered = prepared.starterPromptDelivered

            let sessionTarget = try ControlRevisionCommentNavigation.makeSessionTarget(
                serverId: connection.currentServerId,
                fallbackServerId: sessionStore.activeServerId,
                domain: domain,
                targetId: targetId,
                toSessionId: session.id,
                comments: comments
            )

            error = nil
            dismiss()
            await Task.yield()
            navigation.openWorkspaceSession(sessionTarget)
        } catch {
            self.error = "\(error.localizedDescription) Your staged comments are still saved."
        }
    }
}
