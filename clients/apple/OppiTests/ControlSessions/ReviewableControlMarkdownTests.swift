import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("Reviewable control Markdown")
@MainActor
struct ReviewableControlMarkdownTests {
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
        ] {
            guard case .unavailable = ServerSkillFilePresentation.resolve(
                editable: true,
                resourcePath: resourcePath,
                selectedFilePath: selectedPath
            ) else {
                Issue.record("Expected no host path for \(selectedPath)")
                continue
            }
        }
    }

    @Test func skillFilePresentationReadsNeighborsAndReadOnlySkillsWithoutEdit() {
        // A top-level Markdown Skill is that one file: its neighbors open
        // read-only so a revision never edits them.
        #expect(
            ServerSkillFilePresentation.resolve(
                editable: true,
                resourcePath: "/Users/chen/.pi/agent/skills/review.md",
                selectedFilePath: "other.md"
            ) == .readOnly(hostPath: "/Users/chen/.pi/agent/skills/other.md")
        )
        #expect(
            ServerSkillFilePresentation.resolve(
                editable: false,
                resourcePath: "/opt/homebrew/lib/node_modules/tools/skills/review/SKILL.md",
                selectedFilePath: "SKILL.md"
            ) == .readOnly(hostPath: "/opt/homebrew/lib/node_modules/tools/skills/review/SKILL.md")
        )
    }

    @Test func skillFilePresentationExplainsMissingPath() {
        for editable in [true, false] {
            guard case .unavailable(let reason) = ServerSkillFilePresentation.resolve(
                editable: editable,
                resourcePath: nil,
                selectedFilePath: "SKILL.md"
            ) else {
                Issue.record("A pathless Skill has no host file to read")
                continue
            }
            #expect(reason.contains("server did not provide"))
        }
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

    @Test func skillReviewCommentsKeepAbsolutePathsVerbatimInTheSentBlock() throws {
        let suiteName = "ReviewableControlMarkdownTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: "test.skillPaths")
        )
        let draftSessionId = ReviewableControlMarkdownDraftKey.make(
            serverId: "server-1",
            fallbackServerId: nil,
            domain: .skills,
            targetId: "skill-review"
        )
        let launchPath = "/Users/example/workspace/oppi/.pi/skills/review/SKILL.md"
        let checklistPath = "/Users/example/workspace/oppi/.pi/skills/review/references/checklist.md"
        comments.load(localScopeId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
        for (path, body) in [
            (launchPath, "Clarify the entry point."),
            (checklistPath, "Tighten this checklist."),
        ] {
            #expect(comments.save(
                body: body,
                request: ReviewCommentSelectionRequest(
                    selectedText: "Selected text",
                    source: ReviewCommentSourceContext(
                        sessionId: draftSessionId,
                        surface: .fullScreenMarkdown,
                        sourceLabel: "review",
                        filePath: path,
                        lineRange: 1...1,
                        languageHint: "markdown"
                    )
                ),
                localScopeId: ReviewCommentLocalScope.controlDraft,
                sessionId: draftSessionId
            ) == nil)
        }

        let block = comments.appendReviewBlock(to: "", pathFormatting: .verbatim)

        #expect(block.contains("`\(launchPath)`:1"))
        #expect(block.contains("`\(checklistPath)`:1"))
        #expect(ChatViewController.reviewCommentPathFormattingPolicy(controlDomain: .skills) == .verbatim)
        for domain in [ControlSessionDomain.agents, .schedules, .workspaces] {
            #expect(ChatViewController.reviewCommentPathFormattingPolicy(controlDomain: domain) == .normalizedDisplay)
        }
        #expect(ChatViewController.reviewCommentPathFormattingPolicy(controlDomain: nil) == .normalizedDisplay)
    }

    @Test func atomicLaunchTargetNeedsAServerAndOpensTheControlChat() throws {
        #expect(throws: ControlRevisionCommentNavigationError.serverUnavailable) {
            try ControlRevisionCommentNavigation.makeAtomicLaunchSessionTarget(
                serverId: nil,
                fallbackServerId: nil,
                toSessionId: "control-session-1"
            )
        }

        let target = try ControlRevisionCommentNavigation.makeAtomicLaunchSessionTarget(
            serverId: nil,
            fallbackServerId: "server-1",
            toSessionId: "control-session-1"
        )
        #expect(target.serverId == "server-1")
        #expect(target.sessionId == "control-session-1")
        #expect(target.routeScope == .control)
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

    @Test func retryFreezesAtomicPostAndPreservesRevisedDraftAndComments() async throws {
        let suiteName = "ReviewableControlMarkdownTests.frozenRetry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: "test.frozenRetry")
        )
        let draftSessionId = "server-1:skills:skill-1"
        comments.load(localScopeId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
        #expect(comments.save(
            body: "Original comment.",
            request: ReviewCommentSelectionRequest(
                selectedText: "Original selection",
                source: ReviewCommentSourceContext(
                    sessionId: draftSessionId,
                    surface: .fullScreenMarkdown,
                    sourceLabel: "review / SKILL.md"
                )
            ),
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        ) == nil)

        var state = ControlRevisionSessionRetryState(requestId: "stable-request-id")
        var draft = "Original request."
        let originalCandidate = GuidedControlSessionAtomicLaunch.make(
            domain: .skills,
            intent: .revise,
            targetId: "skill-1",
            targetName: "review",
            targetPath: "/tmp/review/SKILL.md",
            workspaceId: "workspace-1",
            workspaceName: "Oppi",
            sourceDraftText: draft,
            cleanRequest: draft,
            sessionName: "Revise review",
            model: "openai/gpt-5.4",
            thinking: .high,
            requestId: state.requestId,
            comments: comments
        )
        let originalLaunch = state.freeze(originalCandidate)
        let session = makeTestSession(id: "control-session-1")
        var postedRequests: [APIClient.CreateControlSessionRequest] = []

        do {
            _ = try await GuidedControlSessionLaunchCoordinator.prepare(
                launch: originalLaunch,
                existingSession: state.createdSession,
                starterPromptDelivered: state.starterPromptDelivered,
                serverId: "server-1",
                fallbackServerId: nil,
                currentDraftText: draft,
                currentComments: comments.stagedComments,
                create: { request in
                    postedRequests.append(request)
                    return (session, false)
                },
                onSessionCreated: { state.recordCreatedSession($0, promptDelivered: $1) }
            )
            Issue.record("A not-sent atomic POST must remain retryable")
        } catch ControlRevisionSessionLaunchError.initialPromptNotSent {
        }

        let originalComment = try #require(comments.stagedComments.first)
        #expect(comments.update(originalComment, body: "Revised unsent comment.") == nil)
        #expect(comments.save(
            body: "New unsent comment.",
            request: ReviewCommentSelectionRequest(
                selectedText: "New selection",
                source: ReviewCommentSourceContext(
                    sessionId: draftSessionId,
                    surface: .fullScreenMarkdown,
                    sourceLabel: "review / SKILL.md"
                )
            ),
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        ) == nil)
        draft = "Revised unsent request."
        let revisedCandidate = GuidedControlSessionAtomicLaunch.make(
            domain: .skills,
            intent: .revise,
            targetId: "skill-1",
            targetName: "review",
            targetPath: "/tmp/review/SKILL.md",
            workspaceId: "workspace-2",
            workspaceName: "Other workspace",
            sourceDraftText: draft,
            cleanRequest: draft,
            sessionName: "Changed name",
            model: "anthropic/claude-sonnet-4",
            thinking: .low,
            requestId: state.requestId,
            comments: comments
        )
        let frozenRetry = state.freeze(revisedCandidate)
        let completion = try await GuidedControlSessionLaunchCoordinator.prepare(
            launch: frozenRetry,
            existingSession: state.createdSession,
            starterPromptDelivered: state.starterPromptDelivered,
            serverId: "server-1",
            fallbackServerId: nil,
            currentDraftText: draft,
            currentComments: comments.stagedComments,
            create: { request in
                postedRequests.append(request)
                return (session, true)
            },
            onSessionCreated: { state.recordCreatedSession($0, promptDelivered: $1) }
        )

        #expect(postedRequests.count == 2)
        for request in postedRequests {
            #expect(request.launchIdempotencyKey == "stable-request-id")
            #expect(request.name == "Revise review")
            #expect(request.model == "openai/gpt-5.4")
            #expect(request.thinking == .high)
            #expect(request.prompt == originalCandidate.request.prompt)
            #expect(request.prompt?.contains("Original request.") == true)
            #expect(request.prompt?.contains("Original comment.") == true)
            #expect(request.prompt?.contains("Revised unsent") == false)
        }
        #expect(completion.sentCommentIdsToDispose.isEmpty)
        #expect(completion.shouldClearDraft == false)
        #expect(completion.hasUnsentContentAfterDisposal)
        comments.clearSent(ids: completion.sentCommentIdsToDispose)
        if completion.shouldClearDraft { draft = "" }
        var navigationTarget: WorkspaceSessionNavTarget?
        if !completion.hasUnsentContentAfterDisposal {
            navigationTarget = completion.sessionTarget
        }
        #expect(draft == "Revised unsent request.")
        #expect(comments.stagedComments.map(\.body).sorted() == [
            "New unsent comment.",
            "Revised unsent comment.",
        ])
        #expect(navigationTarget == nil)
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
        let readerDepth = navigation.workspaceStackRouteElements.count

        let target = try ControlRevisionCommentNavigation.makeAtomicLaunchSessionTarget(
            serverId: "server-1",
            fallbackServerId: nil,
            toSessionId: "control-session-1"
        )
        var handoff = ControlRevisionSheetHandoff()
        handoff.prepare(target)

        #expect(navigation.workspaceStackRouteElements.count == readerDepth)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "server_skill_file")

        let completedTarget = handoff.completeAfterDismissal()
        let dismissedTarget = try #require(completedTarget)
        navigation.openWorkspaceSession(dismissedTarget)

        #expect(navigation.workspaceStackRouteElements.count == readerDepth + 1)
        #expect(navigation.workspaceStackDiagnosticContext.screen == "chat")
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "control-session-1")
        #expect(handoff.completeAfterDismissal() == nil)
    }

    @Test func guidedRevisionLaunchSendsContextOnlyPromptWithHostFileAndStagedComments() throws {
        let suiteName = "ReviewableControlMarkdownTests.guidedPrompt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: "test.guidedPrompt")
        )
        let draftSessionId = "server-1:skills:skill-1"
        comments.load(localScopeId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
        #expect(comments.save(
            body: "Tighten this.",
            request: ReviewCommentSelectionRequest(
                selectedText: "Loose text",
                source: ReviewCommentSourceContext(
                    sessionId: draftSessionId,
                    surface: .fullScreenMarkdown,
                    sourceLabel: "codex / SKILL.md"
                )
            ),
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        ) == nil)

        let launch = GuidedControlSessionAtomicLaunch.make(
            domain: .skills,
            intent: .revise,
            targetId: "skill-1",
            targetName: "codex",
            targetPath: "/Users/example/workspace/agent-skills/skills/codex/SKILL.md",
            workspaceId: nil,
            workspaceName: nil,
            sourceDraftText: "",
            cleanRequest: "",
            sessionName: "Revise codex",
            model: nil,
            thinking: .high,
            requestId: "request-1",
            comments: comments
        )

        let prompt = launch.request.prompt ?? ""
        let header = [
            "Help the user revise an Oppi Skill.",
            "Canonical target ID: skill-1",
            "Canonical target name: codex",
            "Selected existing host file: /Users/example/workspace/agent-skills/skills/codex/SKILL.md",
        ].joined(separator: "\n")
        #expect(prompt.hasPrefix(header))
        #expect(!prompt.contains("Canonical workspace"))
        #expect(prompt.contains("User request:"))
        #expect(prompt.contains("Tighten this."))
    }

    @Test func guidedComposerReusesTheChatReviewCommentStashWhenCommentsAreStaged() {
        let hidden = GuidedControlSessionComposerReviewComments.presentation(stagedCount: 0)
        let singular = GuidedControlSessionComposerReviewComments.presentation(stagedCount: 1)
        let plural = GuidedControlSessionComposerReviewComments.presentation(stagedCount: 2)

        #expect(hidden.showsPill == false)
        #expect(hidden.pendingCount == 0)
        #expect(hidden.title == nil)
        #expect(hidden.pillCountText == nil)
        #expect(singular.showsPill)
        #expect(singular.pendingCount == 1)
        #expect(singular.title == ReviewCommentStripChrome.stashTitle(count: 1))
        #expect(singular.pillCountText == "1 comment")
        #expect(plural.showsPill)
        #expect(plural.pendingCount == 2)
        #expect(plural.title == ReviewCommentStripChrome.stashTitle(count: 2))
        #expect(plural.pillCountText == "2 comments")
    }

    @Test func successfulAtomicLaunchDisposesExactlySentCommentsAndBuildsNavigation() async throws {
        let suiteName = "ReviewableControlMarkdownTests.atomicGuidedLaunch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: "test.atomicGuidedLaunch")
        )
        let draftSessionId = "server-1:skills:skill-1"
        comments.load(localScopeId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
        let path = "/Users/example/.pi/agent/skills/review/SKILL.md"
        #expect(comments.save(
            body: "Keep this constraint explicit.",
            request: ReviewCommentSelectionRequest(
                selectedText: "Current guidance",
                source: ReviewCommentSourceContext(
                    sessionId: draftSessionId,
                    surface: .fullScreenMarkdown,
                    sourceLabel: "review / SKILL.md",
                    filePath: path,
                    lineRange: 8...8,
                    languageHint: "markdown"
                )
            ),
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        ) == nil)

        var state = ControlRevisionSessionRetryState(requestId: "atomic-success")
        var draft = "Tighten the instructions."
        let launch = state.freeze(GuidedControlSessionAtomicLaunch.make(
            domain: .skills,
            intent: .revise,
            targetId: "skill-1",
            targetName: "review",
            targetPath: path,
            workspaceId: "workspace-1",
            workspaceName: "Oppi",
            sourceDraftText: draft,
            cleanRequest: draft,
            sessionName: "Revise review",
            model: nil,
            thinking: .medium,
            requestId: state.requestId,
            comments: comments
        ))
        var postedRequests: [APIClient.CreateControlSessionRequest] = []
        let completion = try await GuidedControlSessionLaunchCoordinator.prepare(
            launch: launch,
            existingSession: nil,
            starterPromptDelivered: false,
            serverId: "server-1",
            fallbackServerId: nil,
            currentDraftText: draft,
            currentComments: comments.stagedComments,
            create: { request in
                postedRequests.append(request)
                return (makeTestSession(id: "control-session-1"), true)
            },
            onSessionCreated: { state.recordCreatedSession($0, promptDelivered: $1) }
        )

        #expect(postedRequests.count == 1)
        let posted = try #require(postedRequests.first)
        #expect(posted.launchIdempotencyKey == "atomic-success")
        #expect(posted.prompt?.contains("User request:\nTighten the instructions.") == true)
        #expect(posted.prompt?.contains("## Review comments") == true)
        #expect(posted.prompt?.contains("`\(path)`:8 (file)") == true)
        #expect(posted.prompt?.contains("> Keep this constraint explicit.") == true)
        #expect(completion.sentCommentIdsToDispose == comments.stagedCommentIds)
        #expect(completion.hasUnsentContentAfterDisposal == false)
        comments.clearSent(ids: completion.sentCommentIdsToDispose)
        if completion.shouldClearDraft { draft = "" }
        #expect(draft.isEmpty)
        #expect(comments.stagedComments.isEmpty)
        #expect(completion.sessionTarget.serverId == "server-1")
        #expect(completion.sessionTarget.sessionId == "control-session-1")
        #expect(completion.sessionTarget.routeScope == .control)
    }

    @Test func failedAtomicPromptPreflightKeepsProductionDraftCommentsAndNavigationInPlace() async throws {
        let suiteName = "ReviewableControlMarkdownTests.failedAtomicPreflight.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let comments = ChatReviewCommentsController(
            store: ReviewCommentStore(defaults: defaults, keyPrefix: "test.failedAtomicPreflight")
        )
        let draftSessionId = "server-1:agents:agent-1"
        comments.load(localScopeId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
        #expect(comments.save(
            body: "Keep this staged.",
            request: ReviewCommentSelectionRequest(
                selectedText: "Current instructions",
                source: ReviewCommentSourceContext(
                    sessionId: draftSessionId,
                    surface: .fullScreenMarkdown,
                    sourceLabel: "Agent definition"
                )
            ),
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        ) == nil)

        var state = ControlRevisionSessionRetryState(requestId: "failed-preflight")
        var draft = "Tighten the responsibilities."
        let launch = state.freeze(GuidedControlSessionAtomicLaunch.make(
            domain: .agents,
            intent: .revise,
            targetId: "agent-1",
            targetName: "Reviewer",
            targetPath: nil,
            workspaceId: "workspace-1",
            workspaceName: "Oppi",
            sourceDraftText: draft,
            cleanRequest: draft,
            sessionName: "Revise Reviewer",
            model: nil,
            thinking: .medium,
            requestId: state.requestId,
            comments: comments
        ))
        var navigationTarget: WorkspaceSessionNavTarget?

        do {
            let completion = try await GuidedControlSessionLaunchCoordinator.prepare(
                launch: launch,
                existingSession: nil,
                starterPromptDelivered: false,
                serverId: "server-1",
                fallbackServerId: nil,
                currentDraftText: draft,
                currentComments: comments.stagedComments,
                create: { _ in (makeTestSession(id: "control-session-1"), false) },
                onSessionCreated: { state.recordCreatedSession($0, promptDelivered: $1) }
            )
            comments.clearSent(ids: completion.sentCommentIdsToDispose)
            if completion.shouldClearDraft { draft = "" }
            navigationTarget = completion.sessionTarget
            Issue.record("Prompt preflight should fail before disposal or navigation")
        } catch ControlRevisionSessionLaunchError.initialPromptNotSent {
        }

        #expect(draft == "Tighten the responsibilities.")
        #expect(comments.stagedComments.map(\.body) == ["Keep this staged."])
        #expect(navigationTarget == nil)
        #expect(state.createdSession?.id == "control-session-1")
        #expect(state.starterPromptDelivered == false)
    }
}
