import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("Reviewable control Markdown")
@MainActor
struct ReviewableControlMarkdownTests {
    private enum RetryFailure: Error {
        case simulatedNetworkFailure
    }

    private struct SkillPathCase {
        let resourcePath: String
        let selectedPath: String
        let expected: String
    }

    @Test func skillFilePresentationResolvesDirectoryTopLevelAndNestedFiles() {
        let cases = [
            SkillPathCase(
                resourcePath: "/Users/chen/.pi/agent/skills/review/SKILL.md",
                selectedPath: "SKILL.md",
                expected: "/Users/chen/.pi/agent/skills/review/SKILL.md"
            ),
            SkillPathCase(
                resourcePath: "/Users/chen/.pi/agent/skills/review.md",
                selectedPath: "review.md",
                expected: "/Users/chen/.pi/agent/skills/review.md"
            ),
            SkillPathCase(
                resourcePath: "/Users/chen/.pi/agent/skills/review/SKILL.md",
                selectedPath: "references/checklist.md",
                expected: "/Users/chen/.pi/agent/skills/review/references/checklist.md"
            ),
        ]

        for testCase in cases {
            #expect(
                ServerSkillFilePresentation.resolve(
                    editable: true,
                    resourcePath: testCase.resourcePath,
                    selectedFilePath: testCase.selectedPath
                ) == .editable(hostPath: testCase.expected)
            )
        }
    }

    @Test func skillFilePresentationNormalizesResourcePathsAndRejectsInvalidFilePaths() {
        #expect(
            ServerSkillFilePresentation.resolve(
                editable: true,
                resourcePath: "/Users/chen/.pi/agent/skills/./review/SKILL.md",
                selectedFilePath: "references/checklist.md"
            ) == .editable(
                hostPath: "/Users/chen/.pi/agent/skills/review/references/checklist.md"
            )
        )

        for (resourcePath, selectedPath) in [
            ("/Users/chen/.pi/agent/skills/review/SKILL.md", "../outside.md"),
            ("/Users/chen/.pi/agent/skills/review/SKILL.md", "references/../outside.md"),
            ("/Users/chen/.pi/agent/skills/review/SKILL.md", "/outside.md"),
            ("/Users/chen/.pi/agent/skills/review/SKILL.md", "refs\\outside.md"),
            ("relative/review/SKILL.md", "SKILL.md"),
            ("/Users/chen/.pi/agent/skills/review.md", "other.md"),
        ] {
            guard case .editingUnavailable = ServerSkillFilePresentation.resolve(
                editable: true,
                resourcePath: resourcePath,
                selectedFilePath: selectedPath
            ) else {
                Issue.record("Expected editing to be unavailable for \(selectedPath)")
                continue
            }
        }
    }

    @Test func skillFilePresentationExplainsMissingEditablePathButKeepsReadOnlySkillsOrdinary() {
        let missingPath = ServerSkillFilePresentation.resolve(
            editable: true,
            resourcePath: nil,
            selectedFilePath: "SKILL.md"
        )
        guard case .editingUnavailable(let reason) = missingPath else {
            Issue.record("An editable pathless Skill must explain why editing is unavailable")
            return
        }
        #expect(reason.contains("server did not provide"))
        #expect(
            ServerSkillFilePresentation.resolve(
                editable: false,
                resourcePath: nil,
                selectedFilePath: "SKILL.md"
            ) == .readOnly
        )
    }

    @Test func targetDraftKeysAreSeparatedByServerDomainAndCanonicalTarget() {
        let firstServer = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .schedules,
            targetId: "shared-id"
        )
        let secondServer = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-2",
            fallbackServerId: nil,
            domain: .schedules,
            targetId: "shared-id"
        )
        let agent = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .agents,
            targetId: "shared-id"
        )
        let skill = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "shared-id"
        )

        #expect(firstServer == "server-1:schedules:shared-id")
        #expect(firstServer != secondServer)
        #expect(firstServer != agent)
        #expect(skill == "server-1:skills:shared-id")
    }

    @Test func targetDraftKeyUsesActiveServerFallback() {
        #expect(
            ReviewableControlMarkdownDraftKey.make(
                serverId: nil,
                fallbackServerId: "cached-server",
                domain: .agents,
                targetId: "agent-1"
            ) == "cached-server:agents:agent-1"
        )
    }

    @Test func agentDetailHandoffMovesTargetDraftIntoNewControlSessionStash() throws {
        let suiteName = "ReviewableControlMarkdownTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "test.agentHandoff")
        let draftSessionId = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .agents,
            targetId: "agent-1"
        )
        store.load(workspaceId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
        let saved = try store.create(
            workspaceId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId,
            body: "Keep the prompt concise.",
            reference: ReviewCommentReference(
                source: .timelineText,
                label: "Agent definition",
                path: nil,
                side: nil,
                startLine: nil,
                endLine: nil,
                selectedText: "Long prompt",
                languageHint: nil,
                toolCallId: nil,
                timelineItemId: nil,
                url: nil
            )
        )

        let moved = try ControlRevisionCommentTransfer.moveStagedComments(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .agents,
            targetId: "agent-1",
            toSessionId: "control-session-1",
            comments: ChatReviewCommentsController(store: store)
        )

        #expect(moved == 1)
        let source = ReviewCommentStore(defaults: defaults, keyPrefix: "test.agentHandoff")
        source.load(workspaceId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
        #expect(source.stagedComments.isEmpty)

        let destination = ReviewCommentStore(defaults: defaults, keyPrefix: "test.agentHandoff")
        destination.load(
            workspaceId: SessionRouteScope.control.composerDraftScopeID,
            sessionId: "control-session-1"
        )
        #expect(destination.stagedComments.map(\.id) == [saved.id])
    }

    @Test func skillCommentHandoffPreservesAbsolutePathsAndFormatsEveryFileVerbatim() throws {
        let suiteName = "ReviewableControlMarkdownTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefix = "test.skillHandoff"
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        let draftSessionId = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-review"
        )
        let launchPath = "/Users/chenda/workspace/oppi/.pi/skills/review/SKILL.md"
        let checklistPath = "/Users/chenda/workspace/oppi/.pi/skills/review/references/checklist.md"
        store.load(workspaceId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
        for (path, body) in [
            (launchPath, "Clarify the entry point."),
            (checklistPath, "Tighten this checklist."),
        ] {
            _ = try store.create(
                workspaceId: ReviewCommentLocalScope.controlDraft,
                sessionId: draftSessionId,
                body: body,
                reference: ReviewCommentReference(
                    source: .file,
                    label: nil,
                    path: path,
                    side: nil,
                    startLine: 1,
                    endLine: 1,
                    selectedText: "Selected text",
                    languageHint: "markdown",
                    toolCallId: nil,
                    timelineItemId: nil,
                    url: nil
                )
            )
        }

        let moved = try ControlRevisionCommentTransfer.moveStagedComments(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-review",
            toSessionId: "control-session-1",
            comments: ChatReviewCommentsController(store: store)
        )

        let destinationStore = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        let destination = ChatReviewCommentsController(store: destinationStore)
        destination.load(
            localScopeId: SessionRouteScope.control.composerDraftScopeID,
            sessionId: "control-session-1"
        )
        let block = destination.appendReviewBlock(to: "", pathFormatting: .verbatim)

        #expect(moved == 2)
        #expect(Set(destination.stagedComments.compactMap(\.reference.path)) == Set([
            launchPath,
            checklistPath,
        ]))
        #expect(block.contains("`\(launchPath)`:1 (file)"))
        #expect(block.contains("`\(checklistPath)`:1 (file)"))
        #expect(ChatView.reviewCommentPathFormattingPolicy(controlDomain: .skills) == .verbatim)
        for domain in [ControlSessionDomain.agents, .schedules, .workspaces] {
            #expect(ChatView.reviewCommentPathFormattingPolicy(controlDomain: domain) == .normalizedDisplay)
        }
        #expect(ChatView.reviewCommentPathFormattingPolicy(controlDomain: nil) == .normalizedDisplay)
    }

    @Test func missingServerNavigationKeepsTargetDraftComments() throws {
        let suiteName = "ReviewableControlMarkdownTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "test.navigationPrecondition")
        let draftSessionId = ReviewableControlMarkdownDraftKey.make(
            serverId: nil,
            fallbackServerId: nil,
            domain: .agents,
            targetId: "agent-1"
        )
        store.load(workspaceId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
        _ = try store.create(
            workspaceId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId,
            body: "Keep this comment staged.",
            reference: ReviewCommentReference(
                source: .timelineText,
                label: "Agent definition",
                path: nil,
                side: nil,
                startLine: nil,
                endLine: nil,
                selectedText: "Prompt",
                languageHint: nil,
                toolCallId: nil,
                timelineItemId: nil,
                url: nil
            )
        )

        #expect(throws: ControlRevisionCommentNavigationError.serverUnavailable) {
            try ControlRevisionCommentNavigation.moveStagedComments(
                serverId: nil,
                fallbackServerId: nil,
                domain: .agents,
                targetId: "agent-1",
                toSessionId: "control-session-1",
                comments: ChatReviewCommentsController(store: store)
            )
        }

        let source = ReviewCommentStore(defaults: defaults, keyPrefix: "test.navigationPrecondition")
        source.load(workspaceId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
        #expect(source.stagedComments.count == 1)
    }

    @Test func successfulGuidedLaunchResetDoesNotReusePreviousSession() {
        let firstRequestId = "first-request"
        var state = ControlRevisionSessionRetryState(requestId: firstRequestId)
        state.recordCreatedSession(makeTestSession(id: "control-session-1"), promptDelivered: true)

        state.resetForNextLaunch(requestId: "second-request")

        #expect(state.createdSession == nil)
        #expect(state.starterPromptDelivered == false)
        #expect(state.requestId == "second-request")
        #expect(state.requestId != firstRequestId)
    }

    @Test func promptedFalseRetryReusesCreatedSessionAndStableRequestId() async throws {
        let session = makeTestSession(id: "control-session-1")
        let requestId = "stable-request-id"
        var createCalls = 0
        var cachedSessions: [Session] = []
        var activatedSessionIds: [String] = []
        var sentRequestIds: [String] = []
        var retainedSession: Session?
        var delivered = false

        do {
            _ = try await ControlRevisionSessionLaunchCoordinator.prepare(
                existingSession: retainedSession,
                starterPromptDelivered: delivered,
                requestId: requestId,
                create: {
                    createCalls += 1
                    return (session, false)
                },
                onSessionCreated: { created, promptDelivered in
                    retainedSession = created
                    delivered = promptDelivered
                    cachedSessions.append(created)
                },
                activateSession: { activatedSessionIds.append($0.id) },
                sendStarterPrompt: { _, sentRequestId in
                    sentRequestIds.append(sentRequestId)
                    throw RetryFailure.simulatedNetworkFailure
                }
            )
            Issue.record("The first starter-prompt delivery should fail")
        } catch RetryFailure.simulatedNetworkFailure {
        }

        let prepared = try await ControlRevisionSessionLaunchCoordinator.prepare(
            existingSession: retainedSession,
            starterPromptDelivered: delivered,
            requestId: requestId,
            create: {
                createCalls += 1
                return (session, false)
            },
            onSessionCreated: { _, _ in
                Issue.record("Retry must reuse the retained session")
            },
            activateSession: { activatedSessionIds.append($0.id) },
            sendStarterPrompt: { retriedSession, sentRequestId in
                #expect(retriedSession.id == session.id)
                sentRequestIds.append(sentRequestId)
            }
        )

        #expect(createCalls == 1)
        #expect(cachedSessions.map(\.id) == [session.id])
        #expect(activatedSessionIds == [session.id, session.id])
        #expect(sentRequestIds == [requestId, requestId])
        #expect(prepared.session.id == session.id)
        #expect(prepared.starterPromptDelivered)
    }

    @Test func promptedSessionRetryAfterCommentTransferFailureReusesCreatedSession() async throws {
        let session = makeTestSession(id: "control-session-transfer-retry")
        var createCalls = 0
        var retainedSession: Session?
        var delivered = false
        var transferCalls = 0

        let first = try await ControlRevisionSessionLaunchCoordinator.prepare(
            existingSession: retainedSession,
            starterPromptDelivered: delivered,
            requestId: "transfer-retry-request",
            create: {
                createCalls += 1
                return (session, true)
            },
            onSessionCreated: { created, promptDelivered in
                retainedSession = created
                delivered = promptDelivered
            },
            activateSession: { _ in
                Issue.record("A prompted control session must not be resumed for delivery")
            },
            sendStarterPrompt: { _, _ in
                Issue.record("A prompted control session must not send its starter prompt again")
            }
        )

        do {
            transferCalls += 1
            throw RetryFailure.simulatedNetworkFailure
        } catch RetryFailure.simulatedNetworkFailure {
            // The staged comments remain local when the transfer fails.
        }

        let retry = try await ControlRevisionSessionLaunchCoordinator.prepare(
            existingSession: retainedSession,
            starterPromptDelivered: delivered,
            requestId: "transfer-retry-request",
            create: {
                createCalls += 1
                return (session, true)
            },
            onSessionCreated: { _, _ in
                Issue.record("A comment-transfer retry must reuse the created session")
            },
            activateSession: { _ in
                Issue.record("A delivered starter prompt must not resume again")
            },
            sendStarterPrompt: { _, _ in
                Issue.record("A prompted control session must not resend its starter prompt")
            }
        )

        #expect(first.session.id == session.id)
        #expect(retry.session.id == session.id)
        #expect(createCalls == 1)
        #expect(transferCalls == 1)
    }

    @Test func zeroStagedCommentsStillBuildsAnOrdinaryControlSessionTarget() throws {
        let suiteName = "ReviewableControlMarkdownTests.zeroComments.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: "test.zeroComments")
        )

        let target = try ControlRevisionCommentNavigation.makeSessionTarget(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-1",
            toSessionId: "control-session-1",
            comments: comments
        )

        #expect(target.serverId == "server-1")
        #expect(target.sessionId == "control-session-1")
        #expect(target.routeScope == .control)
    }

    @Test func guidedSkillHandoffUpdatesTheReaderOwnedCommentController() throws {
        let suiteName = "ReviewableControlMarkdownTests.guidedReaderState.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: "test.guidedReaderState")
        )
        let draftSessionId = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-1"
        )
        comments.load(
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        )
        let request = ReviewCommentSelectionRequest(
            selectedText: "Current guidance",
            source: ReviewCommentSourceContext(
                sessionId: draftSessionId,
                surface: .fullScreenMarkdown,
                sourceLabel: "Skill file",
                filePath: "/Users/chen/.pi/agent/skills/review/SKILL.md",
                lineRange: 4...4,
                languageHint: "markdown",
                timelineItemId: "skill-reader"
            )
        )
        #expect(comments.save(
            body: "Tighten this guidance.",
            request: request,
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        ) == nil)
        #expect(comments.stagedCount == 1)

        _ = try ControlRevisionCommentNavigation.makeSessionTarget(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-1",
            toSessionId: "control-session-1",
            comments: comments
        )

        #expect(comments.stagedCount == 0)
        #expect(comments.stagedComments.isEmpty)
    }

    @Test func guidedSkillHandoffNavigatesOnlyAfterSheetDismissalCompletes() throws {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false
        navigation.openWorkspaceUtility(.skills)
        navigation.openServerSkillBrowser(.init(serverId: "server-1", resourceId: "skill-1"))
        navigation.openServerSkillFile(.init(
            serverId: "server-1",
            resourceId: "skill-1",
            path: "SKILL.md"
        ))
        let readerDepth = navigation.workspacePath.count

        let target = try ControlRevisionCommentNavigation.makeSessionTarget(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-1",
            toSessionId: "control-session-1"
        )
        var handoff = ControlRevisionSheetHandoff()
        handoff.prepare(target)

        #expect(navigation.workspacePath.count == readerDepth)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_skill_file")

        let completedTarget = handoff.completeAfterDismissal()
        let dismissedTarget = try #require(completedTarget)
        navigation.openWorkspaceSession(dismissedTarget)

        #expect(navigation.workspacePath.count == readerDepth + 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "chat")
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "control-session-1")
        #expect(handoff.completeAfterDismissal() == nil)
    }

    @Test func skillGuidedComposerPromptKeepsTheSelectedHostFile() {
        let prompt = ControlSessionStarterPrompt.make(
            domain: .skills,
            intent: .revise,
            targetId: "skill-1",
            targetName: "codex",
            targetPath: "/Users/chenda/workspace/agent-skills/skills/codex/SKILL.md",
            workspaceId: "workspace-1",
            workspaceName: "Oppi",
            userRequest: "Tighten the instructions."
        )

        #expect(prompt.contains("Selected existing host file: /Users/chenda/workspace/agent-skills/skills/codex/SKILL.md"))
        #expect(prompt.contains("Canonical workspace ID: workspace-1"))
        #expect(prompt.contains("User request:\nTighten the instructions."))
        #expect(prompt.contains("stock `read`"))
        #expect(prompt.contains("stock `edit`"))
    }

    @Test func guidedComposerReusesTheChatReviewCommentStashWhenCommentsAreStaged() {
        let hidden = GuidedControlSessionComposerReviewComments.presentation(stagedCount: 0)
        let singular = GuidedControlSessionComposerReviewComments.presentation(stagedCount: 1)
        let plural = GuidedControlSessionComposerReviewComments.presentation(stagedCount: 2)

        #expect(hidden.showsStash == false)
        #expect(hidden.pendingCount == 0)
        #expect(hidden.title == nil)
        #expect(singular.showsStash)
        #expect(singular.pendingCount == 1)
        #expect(singular.title == ChatInputBar<EmptyView>.reviewCommentStashTitle(count: 1))
        #expect(plural.showsStash)
        #expect(plural.pendingCount == 2)
        #expect(plural.title == ChatInputBar<EmptyView>.reviewCommentStashTitle(count: 2))
    }

    @Test func skillLaunchSendsStagedCommentsOnceThenDisposesThem() throws {
        let suiteName = "ReviewableControlMarkdownTests.autoSend.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: "test.autoSend")
        )
        let draftSessionId = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-1"
        )
        comments.load(
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        )
        let path = "/Users/chenda/workspace/agent-skills/skills/codex/SKILL.md"
        #expect(comments.save(
            body: "Tighten this guidance.",
            request: ReviewCommentSelectionRequest(
                selectedText: "Current guidance",
                source: ReviewCommentSourceContext(
                    sessionId: draftSessionId,
                    surface: .fullScreenMarkdown,
                    sourceLabel: "codex / SKILL.md",
                    filePath: path,
                    lineRange: 4...4,
                    languageHint: "markdown",
                    timelineItemId: "skill-reader"
                )
            ),
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        ) == nil)

        let prepared = try ControlRevisionCommentNavigation.prepareLaunchMessage(
            request: "Tighten the instructions.",
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-1",
            toSessionId: "control-session-1",
            comments: comments
        )

        #expect(prepared.sessionTarget.sessionId == "control-session-1")
        #expect(prepared.sessionTarget.routeScope == .control)
        #expect(prepared.message.contains("Tighten the instructions."))
        #expect(prepared.message.contains("## Review comments"))
        #expect(prepared.message.contains("`\(path)`:4 (file)"))
        #expect(prepared.message.contains("> Tighten this guidance."))
        #expect(prepared.sentCommentIds.count == 1)
        #expect(comments.stagedCount == 1)

        prepared.disposeSentComments(using: comments)
        #expect(comments.stagedCount == 0)
    }

    @Test func failedSkillLaunchSendKeepsStagedComments() throws {
        let suiteName = "ReviewableControlMarkdownTests.failedAutoSend.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: "test.failedAutoSend")
        )
        let draftSessionId = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-1"
        )
        comments.load(
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        )
        #expect(comments.save(
            body: "Keep this comment.",
            request: ReviewCommentSelectionRequest(
                selectedText: "Current guidance",
                source: ReviewCommentSourceContext(
                    sessionId: draftSessionId,
                    surface: .fullScreenMarkdown,
                    sourceLabel: "codex / SKILL.md",
                    filePath: "/Users/chenda/workspace/agent-skills/skills/codex/SKILL.md",
                    lineRange: 4...4,
                    languageHint: "markdown"
                )
            ),
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        ) == nil)

        let prepared = try ControlRevisionCommentNavigation.prepareLaunchMessage(
            request: "Tighten the instructions.",
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-1",
            toSessionId: "control-session-1",
            comments: comments
        )

        #expect(prepared.sentCommentIds.count == 1)
        #expect(comments.stagedCount == 1)
    }
}
