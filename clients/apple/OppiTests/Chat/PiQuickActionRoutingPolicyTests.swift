import Foundation
import Testing
@testable import Oppi

@Suite("π quick action routing policy")
struct PiQuickActionRoutingPolicyTests {
    struct Case: CustomStringConvertible, Sendable {
        let name: String
        let context: SelectedTextPiRoutingContext
        let action: PiQuickAction
        let source: SelectedTextSourceContext
        let expected: Expected

        var description: String { name }
    }

    enum Expected: Equatable, Sendable {
        case currentSessionDraftContains(String)
        case quickSessionDraftContains(String)
        case reviewComment
        case none
    }

    @Test(arguments: routingCases)
    func routesSelectionActionsConsistently(testCase: Case) throws {
        let request = SelectedTextPiRequest(
            action: testCase.action,
            selectedText: "let value = 42",
            source: testCase.source
        )

        let route = SelectedTextPiRouterPolicy.route(request: request, context: testCase.context)

        switch testCase.expected {
        case .reviewComment:
            guard case .reviewComment(let routedRequest) = route else {
                Issue.record("Expected review comment route for \(testCase.name), got \(String(describing: route))")
                return
            }
            #expect(routedRequest == request)

        case .currentSessionDraftContains(let needle):
            guard case .currentSessionDraft(let draft) = route else {
                Issue.record("Expected current-session draft for \(testCase.name), got \(String(describing: route))")
                return
            }
            #expect(draft.contains(needle))

        case .quickSessionDraftContains(let needle):
            guard case .quickSessionDraft(let draft) = route else {
                Issue.record("Expected quick-session draft for \(testCase.name), got \(String(describing: route))")
                return
            }
            #expect(draft.contains(needle))

        case .none:
            #expect(route == nil)
        }
    }

    @Test(arguments: SelectedTextSurfaceKind.representativeSurfaces)
    func commentActionInActiveChatAlwaysStagesReviewComment(surface: SelectedTextSurfaceKind) throws {
        let request = SelectedTextPiRequest(
            action: PiQuickAction.reviewCommentAction,
            selectedText: "selected text",
            source: Self.source(surface: surface)
        )

        let route = ChatView.routeForSelectedTextPiAction(request)

        guard case .reviewComment(let routedRequest) = route else {
            Issue.record("Expected active chat comment route for \(surface), got \(String(describing: route))")
            return
        }
        #expect(routedRequest == request)
    }

    @Test(arguments: SelectedTextSurfaceKind.representativeSurfaces)
    func nonChatSurfacesRoutePromptActionsToQuickSession(surface: SelectedTextSurfaceKind) throws {
        for action in [PiQuickAction.explainAction, PiQuickAction.addToPromptAction, PiQuickAction.newSessionAction] {
            let request = SelectedTextPiRequest(
                action: action,
                selectedText: "selected text",
                source: Self.source(surface: surface)
            )

            guard case .quickSessionDraft(let draft) = SelectedTextPiRouterPolicy.route(request: request, context: .nonChat) else {
                Issue.record("Expected non-chat \(surface) / \(action.title) to route to Quick Session")
                continue
            }
            #expect(draft.contains("selected text"))
        }
    }

    @Test(arguments: SelectedTextSurfaceKind.representativeSurfaces)
    func nonChatSurfacesDoNotFallbackReviewCommentsToDrafts(surface: SelectedTextSurfaceKind) throws {
        let request = SelectedTextPiRequest(
            action: PiQuickAction.reviewCommentAction,
            selectedText: "selected text",
            source: Self.source(surface: surface)
        )

        #expect(SelectedTextPiRouterPolicy.route(request: request, context: .nonChat) == nil)
    }

    @MainActor
    @Test func quickSessionRouterDoesNotExposeReviewCommentActions() throws {
        let router = SelectedTextPiActionRouter(dispatch: { _ in }, allowsReviewComments: false)
        let action = SelectedTextPiMenuBuilder.commentAction(
            selectedText: "let value = 42",
            sourceContext: Self.source(surface: .fullScreenCode),
            router: router
        )

        #expect(action == nil)
    }

    static let routingCases: [Case] = [
        Case(
            name: "chat comment stages a review comment",
            context: .activeChat,
            action: PiQuickAction.reviewCommentAction,
            source: source(surface: .fullScreenDiff),
            expected: .reviewComment
        ),
        Case(
            name: "chat add-to-prompt appends to composer",
            context: .activeChat,
            action: PiQuickAction.addToPromptAction,
            source: source(surface: .assistantCodeBlock),
            expected: .currentSessionDraftContains("let value = 42")
        ),
        Case(
            name: "chat new-session explicitly opens Quick Session",
            context: .activeChat,
            action: PiQuickAction.newSessionAction,
            source: source(surface: .assistantProse),
            expected: .quickSessionDraftContains("let value = 42")
        ),
        Case(
            name: "non-chat comment does not fallback to a draft",
            context: .nonChat,
            action: PiQuickAction.reviewCommentAction,
            source: source(surface: .fullScreenSource),
            expected: .none
        ),
        Case(
            name: "non-chat current-session action opens Quick Session",
            context: .nonChat,
            action: PiQuickAction.builtInDefaults[0],
            source: source(surface: .fullScreenCode),
            expected: .quickSessionDraftContains("Explain this.")
        ),
    ]

    static func source(surface: SelectedTextSurfaceKind) -> SelectedTextSourceContext {
        SelectedTextSourceContext(
            sessionId: surface == .assistantProse ? "chat-session" : "",
            surface: surface,
            sourceLabel: "Test source",
            filePath: surface.prefersCodeBlockInsertion ? "Sources/Test.swift" : nil,
            lineRange: 1...2,
            languageHint: surface.prefersCodeBlockInsertion ? "swift" : nil
        )
    }
}

private extension SelectedTextSurfaceKind {
    static let representativeSurfaces: [SelectedTextSurfaceKind] = [
        .assistantProse,
        .userMessage,
        .assistantCodeBlock,
        .assistantTable,
        .thinking,
        .toolCommand,
        .toolOutput,
        .toolExpandedText,
        .fullScreenCode,
        .fullScreenDiff,
        .fullScreenSource,
        .fullScreenTerminal,
        .fullScreenMarkdown,
        .fullScreenThinking,
    ]
}
