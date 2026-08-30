import Foundation
import Testing
@testable import Oppi

@Suite("Mac session context chrome")
struct MacSessionContextChromeTests {
    @Test func contextLivesInTheToolbarNotInspectorOrFiles() {
        #expect(MacSessionChromeItem.context.region == .toolbar)
        #expect(MacSessionWindowChrome.items(in: .toolbar).contains(.context))
        #expect(!MacSessionWindowChrome.items(in: .inspector).contains(.context))
        #expect(!MacSessionWindowChrome.items(in: .timeline).contains(.context))
        #expect(!MacSessionWindowChrome.items(in: .composer).contains(.context))
        #expect(MacSessionChromeItem.context.composerSlot == nil)
        #expect(MacSessionChromeItem.outline.region == .toolbar)
    }
}

@Suite("Session stats parser")
struct SessionStatsParserTests {
    @Test func parseStringsAndFallsBackTotal() {
        let stats = SessionStatsParser.parse([
            "tokens": [
                "input": "12",
                "output": 34,
                "cacheRead": "5",
                "cacheWrite": 6,
            ],
            "cost": "1.25",
            "cacheWaste": [
                "missedTokens": "20000",
                "missedCost": "0.15",
                "missCount": 2,
            ],
            "modelBreakdown": [
                ["provider": "anthropic", "model": "claude-sonnet", "tokens": "40", "cost": "0.75"],
                ["provider": "openai-codex", "model": "gpt-5.6-sol", "tokens": 17, "cost": 0.5],
                ["model": "Tools & summaries", "tokens": 9, "cost": 0.1],
            ],
            "contextComposition": [
                "piSystemPromptChars": "100",
                "piSystemPromptTokens": 20,
                "agentsChars": 30,
                "agentsTokens": "4",
                "agentsFiles": [
                    ["path": "/tmp/AGENTS.md", "chars": "40", "tokens": 8],
                    ["chars": 1, "tokens": 1],
                ],
                "skillsListingChars": "50",
                "skillsListingTokens": 9,
            ],
            "loadedResources": [
                "skills": [
                    [
                        "name": "crash-review",
                        "description": "Crash review",
                        "path": "/skills/crash-review",
                    ],
                ],
                "extensions": [
                    ["name": "web-fetch", "path": "/ext/web-fetch"],
                ],
            ],
        ])

        #expect(stats?.tokens.input == 12)
        #expect(stats?.tokens.output == 34)
        #expect(stats?.tokens.cacheRead == 5)
        #expect(stats?.tokens.cacheWrite == 6)
        #expect(stats?.tokens.total == 57)
        #expect(stats?.cost == 1.25)
        #expect(stats?.cacheWaste == SessionCacheWasteSnapshot(
            missedTokens: 20_000,
            missedCost: 0.15,
            missCount: 2
        ))
        #expect(stats?.modelBreakdown == [
            SessionModelUsageSnapshot(provider: "anthropic", model: "claude-sonnet", tokens: 40, cost: 0.75),
            SessionModelUsageSnapshot(provider: "openai-codex", model: "gpt-5.6-sol", tokens: 17, cost: 0.5),
            SessionModelUsageSnapshot(provider: nil, model: "Tools & summaries", tokens: 9, cost: 0.1),
        ])
        #expect(stats?.contextComposition?.agentsFiles == [
            ContextFileTokenSnapshot(path: "/tmp/AGENTS.md", chars: 40, tokens: 8)
        ])
        #expect(stats?.loadedResources?.skills.map(\.name) == ["crash-review"])
        #expect(stats?.loadedResources?.extensions.map(\.name) == ["web-fetch"])
    }

    @Test func parseReturnsNilWithoutTokensObject() {
        #expect(SessionStatsParser.parse(["cost": 1]) == nil)
        #expect(SessionStatsParser.parse(nil) == nil)
    }
}

@Suite("Session context presentation")
struct SessionContextPresentationTests {
    @Test func toolbarChipUsesSessionTokensWithoutStats() {
        var session = MacSessionContextInspectorTestsSupport.session()
        session.contextTokens = 50_000
        session.contextWindow = 200_000

        let snapshot = SessionContextUsagePresentation.snapshot(for: session)
        #expect(snapshot.usageText == "50k / 200k")
        #expect(SessionContextUsagePresentation.toolbarTitle(snapshot) == "50k / 200k")
        #expect(snapshot.progress == 0.25)
    }

    @Test func toolbarTitleIsContextWhenUsageIsUnknown() {
        let snapshot = SessionContextUsagePresentation.snapshot(for: MacSessionContextInspectorTestsSupport.session())
        #expect(SessionContextUsagePresentation.toolbarTitle(snapshot) == "Context")
    }

    @Test func fallbackStatsUseSessionRowTotals() {
        var session = MacSessionContextInspectorTestsSupport.session()
        session.tokens = TokenUsage(input: 12_000, output: 2_000, cacheRead: 80_000, cacheWrite: 8_000)
        session.cost = 1.5

        let stats = SessionStatsSnapshot.fallback(from: session)
        #expect(stats.tokens.promptInput == 100_000)
        #expect(stats.tokens.uncachedInput == 20_000)
        #expect(stats.cost == 1.5)
        #expect(stats.contextComposition == nil)
        #expect(stats.loadedResources == nil)
    }

    @Test func compositionSplitsSystemPromptAgentsSkillsAndMessages() {
        let composition = SessionContextCompositionSnapshot(
            piSystemPromptChars: 400,
            piSystemPromptTokens: 40,
            agentsChars: 80,
            agentsTokens: 10,
            agentsFiles: [
                ContextFileTokenSnapshot(path: "/tmp/AGENTS.md", chars: 80, tokens: 10),
            ],
            skillsListingChars: 40,
            skillsListingTokens: 5
        )

        let segments = SessionContextCompositionProjection.segments(
            totalContextTokens: 100,
            composition: composition
        )

        #expect(segments.map(\.kind) == [
            .piBasePrompt, .agentsFiles, .skillsIndex, .messagesAndRuntime,
        ])
        #expect(segments.map(\.tokens) == [25, 10, 5, 60])
        #expect(segments[1].label == "AGENTS files (1)")
    }

    @Test func compositionIsEmptyWhenContextTokensAreZero() {
        let composition = SessionContextCompositionSnapshot(
            piSystemPromptChars: 10,
            piSystemPromptTokens: 2,
            agentsChars: 0,
            agentsTokens: 0,
            agentsFiles: [],
            skillsListingChars: 0,
            skillsListingTokens: 0
        )
        #expect(
            SessionContextCompositionProjection.segments(
                totalContextTokens: 0,
                composition: composition
            ).isEmpty
        )
    }

    @Test func loadedResourcesUnknownIsNotEmptyWhileLoadingOrFailed() {
        let loading = MacSessionLoadedResourcesPresentation.phase(
            isLoading: true,
            error: nil,
            loadedResources: nil,
            itemCount: 0
        )
        let failed = MacSessionLoadedResourcesPresentation.phase(
            isLoading: false,
            error: "stats timeout",
            loadedResources: nil,
            itemCount: 0
        )
        let unknown = MacSessionLoadedResourcesPresentation.phase(
            isLoading: false,
            error: nil,
            loadedResources: nil,
            itemCount: 0
        )

        #expect(loading == .loading)
        #expect(failed == .failed("stats timeout"))
        #expect(unknown == .unknown)
        #expect(loading != .empty)
        #expect(failed != .empty)
        #expect(unknown != .empty)
        #expect(
            MacSessionLoadedResourcesPresentation.placeholder(kind: .skills, phase: loading)
                == "Loading skills…"
        )
        #expect(
            MacSessionLoadedResourcesPresentation.placeholder(kind: .extensions, phase: loading)
                == "Loading extensions…"
        )
        #expect(
            MacSessionLoadedResourcesPresentation.placeholder(kind: .skills, phase: failed)
                == "Skills unavailable: stats timeout"
        )
        #expect(
            MacSessionLoadedResourcesPresentation.placeholder(kind: .extensions, phase: failed)
                == "Extensions unavailable: stats timeout"
        )
        #expect(
            MacSessionLoadedResourcesPresentation.placeholder(kind: .skills, phase: unknown)
                == "Skills appear after stats load."
        )
        #expect(
            MacSessionLoadedResourcesPresentation.placeholder(kind: .extensions, phase: unknown)
                == "Extensions appear after stats load."
        )
        #expect(
            MacSessionLoadedResourcesPresentation.placeholder(kind: .skills, phase: loading)?
                .contains("No skills loaded") != true
        )
        #expect(
            MacSessionLoadedResourcesPresentation.placeholder(kind: .extensions, phase: unknown)?
                .contains("No extensions loaded") != true
        )
    }

    @Test func loadedResourcesEmptyIsDistinctFromUnknown() {
        let emptyResources = SessionLoadedResourcesSnapshot(skills: [], extensions: [])
        let empty = MacSessionLoadedResourcesPresentation.phase(
            isLoading: false,
            error: nil,
            loadedResources: emptyResources,
            itemCount: 0
        )
        let filled = MacSessionLoadedResourcesPresentation.phase(
            isLoading: false,
            error: nil,
            loadedResources: SessionLoadedResourcesSnapshot(
                skills: [
                    SessionResourceSnapshot(name: "crash-review", description: nil, path: "/skills/crash-review")
                ],
                extensions: []
            ),
            itemCount: 1
        )
        let unknown = MacSessionLoadedResourcesPresentation.phase(
            isLoading: false,
            error: nil,
            loadedResources: nil,
            itemCount: 0
        )

        #expect(empty == .empty)
        #expect(filled == .filled)
        #expect(unknown == .unknown)
        #expect(empty != unknown)
        #expect(
            MacSessionLoadedResourcesPresentation.placeholder(kind: .skills, phase: empty)
                == "No skills loaded for this session."
        )
        #expect(
            MacSessionLoadedResourcesPresentation.placeholder(kind: .extensions, phase: empty)
                == "No extensions loaded for this session."
        )
        #expect(MacSessionLoadedResourcesPresentation.placeholder(kind: .skills, phase: filled) == nil)
    }
}

@MainActor
@Suite("Mac session context stats store")
struct MacSessionTraceStoreContextStatsTests {
    @Test func loadSessionStatsSendsGetSessionStatsAndAppliesResult() async {
        let store = MacSessionTraceStore()
        let target = MacSessionContextInspectorTestsSupport.target()
        store.select(target)

        let requestIdBox = ContextStatsRequestIdBox()
        store._sendLiveMessageForTesting = { message in
            guard case .getSessionStats(let requestId) = message else {
                return true
            }
            if let requestId {
                requestIdBox.complete(requestId)
            }
            return true
        }

        let loadTask = Task {
            await store.loadSessionStatsFromLocalConfig()
        }

        let requestId = await requestIdBox.value()
        #expect(store.isLoadingSessionStats)

        store.applyServerMessageForTesting(
            .commandResult(
                command: "get_session_stats",
                requestId: requestId,
                success: true,
                data: [
                    "tokens": [
                        "input": 1,
                        "output": 2,
                        "cacheRead": 3,
                        "cacheWrite": 4,
                        "total": 10,
                    ],
                    "cost": 0.5,
                    "contextComposition": [
                        "piSystemPromptChars": 20,
                        "piSystemPromptTokens": 5,
                        "agentsChars": 0,
                        "agentsTokens": 0,
                        "agentsFiles": [],
                        "skillsListingChars": 0,
                        "skillsListingTokens": 0,
                    ],
                ],
                error: nil
            ),
            target: target
        )

        await loadTask.value
        #expect(!store.isLoadingSessionStats)
        #expect(store.sessionStats?.tokens.total == 10)
        #expect(store.sessionStats?.cost == 0.5)
        #expect(store.sessionStats?.contextComposition?.piSystemPromptTokens == 5)
        #expect(store.sessionStatsError == nil)
    }

    @Test func ignoresMismatchedSessionStatsRequestId() async {
        let store = MacSessionTraceStore()
        let target = MacSessionContextInspectorTestsSupport.target()
        store.select(target)

        store._sendLiveMessageForTesting = { message in
            guard case .getSessionStats(let requestId) = message else {
                return true
            }
            #expect(requestId != nil)
            return true
        }

        let loadTask = Task {
            await store.loadSessionStatsFromLocalConfig()
        }
        await loadTask.value

        store.applyServerMessageForTesting(
            .commandResult(
                command: "get_session_stats",
                requestId: "other-request",
                success: true,
                data: [
                    "tokens": [
                        "input": 1,
                        "output": 2,
                        "cacheRead": 0,
                        "cacheWrite": 0,
                        "total": 3,
                    ],
                    "cost": 0.1,
                ],
                error: nil
            ),
            target: target
        )

        #expect(store.sessionStats == nil)
        #expect(store.isLoadingSessionStats)
    }

    @Test func selectClearsSessionStats() {
        let store = MacSessionTraceStore()
        let target = MacSessionContextInspectorTestsSupport.target()
        store.select(target)
        store.applyServerMessageForTesting(
            .commandResult(
                command: "get_session_stats",
                requestId: nil,
                success: true,
                data: [
                    "tokens": [
                        "input": 1,
                        "output": 2,
                        "cacheRead": 0,
                        "cacheWrite": 0,
                        "total": 3,
                    ],
                    "cost": 0.1,
                ],
                error: nil
            ),
            target: target
        )
        #expect(store.sessionStats?.tokens.total == 3)

        store.select(MacSessionContextInspectorTestsSupport.target(sessionId: "session-context-2"))
        #expect(store.sessionStats == nil)
    }
}

enum MacSessionContextInspectorTestsSupport {
    static func session(id: String = "session-context") -> Session {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return Session(
            id: id,
            workspaceId: "workspace-context",
            workspaceName: "Workspace",
            status: .ready,
            createdAt: now,
            lastActivity: now,
            model: "provider/model",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            firstMessage: "Hello"
        )
    }

    static func target(sessionId: String = "session-context") -> MacSelectedSessionTarget {
        let session = session(id: sessionId)
        return MacSelectedSessionTarget(
            workspaceId: "workspace-context",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }
}

@MainActor
private final class ContextStatsRequestIdBox {
    private var requestId: String?
    private var continuation: CheckedContinuation<String, Never>?

    func complete(_ requestId: String) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: requestId)
        } else {
            self.requestId = requestId
        }
    }

    func value() async -> String {
        if let requestId {
            return requestId
        }
        return await withCheckedContinuation { continuation in
            if let requestId {
                continuation.resume(returning: requestId)
            } else {
                self.continuation = continuation
            }
        }
    }
}
