import Testing
@testable import Oppi

@Suite("AskRequest")
struct AskRequestTests {

    // MARK: - ServerMessage Decoding

    @Test func decodesSingleQuestionAsk() throws {
        let json = """
        {
            "type": "extension_ui_request",
            "id": "ask-1",
            "sessionId": "s1",
            "method": "ask",
            "questions": [
                {
                    "id": "approach",
                    "question": "What testing approach?",
                    "options": [
                        {"value": "unit", "label": "Unit tests", "description": "Fast, isolated"},
                        {"value": "integration", "label": "Integration tests"}
                    ]
                }
            ],
            "allowCustom": true,
            "timeout": 120000
        }
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUIRequest(let req) = msg else {
            Issue.record("Expected .extensionUIRequest, got \(msg)")
            return
        }
        #expect(req.id == "ask-1")
        #expect(req.method == "ask")
        #expect(req.askQuestions?.count == 1)
        #expect(req.allowCustom == true)
        #expect(req.timeout == 120000)

        let q = try #require(req.askQuestions?.first)
        #expect(q.id == "approach")
        #expect(q.question == "What testing approach?")
        #expect(q.options.count == 2)
        #expect(q.multiSelect == false) // default
        #expect(q.options[0].value == "unit")
        #expect(q.options[0].label == "Unit tests")
        #expect(q.options[0].description == "Fast, isolated")
        #expect(q.options[1].description == nil) // missing optional
    }

    @Test func decodesMultiQuestionMixedSelect() throws {
        let json = """
        {
            "type": "extension_ui_request",
            "id": "ask-2",
            "sessionId": "s1",
            "method": "ask",
            "questions": [
                {
                    "id": "approach",
                    "question": "Testing approach?",
                    "options": [
                        {"value": "unit", "label": "Unit"},
                        {"value": "both", "label": "Both"}
                    ],
                    "multiSelect": false
                },
                {
                    "id": "frameworks",
                    "question": "Which frameworks?",
                    "options": [
                        {"value": "jest", "label": "Jest"},
                        {"value": "vitest", "label": "Vitest"},
                        {"value": "playwright", "label": "Playwright"}
                    ],
                    "multiSelect": true
                }
            ],
            "allowCustom": false
        }
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUIRequest(let req) = msg else {
            Issue.record("Expected .extensionUIRequest, got \(msg)")
            return
        }
        #expect(req.askQuestions?.count == 2)
        #expect(req.allowCustom == false)

        let q1 = try #require(req.askQuestions?[0])
        #expect(q1.id == "approach")
        #expect(q1.multiSelect == false)

        let q2 = try #require(req.askQuestions?[1])
        #expect(q2.id == "frameworks")
        #expect(q2.multiSelect == true)
        #expect(q2.options.count == 3)
    }

    @Test func decodesWithMissingOptionalFields() throws {
        // No description, no multiSelect, no allowCustom, no timeout
        let json = """
        {
            "type": "extension_ui_request",
            "id": "ask-3",
            "sessionId": "s1",
            "method": "ask",
            "questions": [
                {
                    "id": "q1",
                    "question": "Pick one",
                    "options": [
                        {"value": "a", "label": "A"},
                        {"value": "b", "label": "B"}
                    ]
                }
            ]
        }
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUIRequest(let req) = msg else {
            Issue.record("Expected .extensionUIRequest, got \(msg)")
            return
        }
        #expect(req.askQuestions?.count == 1)
        #expect(req.allowCustom == nil)
        #expect(req.timeout == nil)

        let q = try #require(req.askQuestions?.first)
        #expect(q.multiSelect == false) // defaults to false
        #expect(q.options[0].description == nil)
    }

    @Test func unknownFieldsIgnored() throws {
        // Forward compatibility: extra fields in questions/options don't break decoding
        let json = """
        {
            "type": "extension_ui_request",
            "id": "ask-4",
            "sessionId": "s1",
            "method": "ask",
            "futureTopLevel": true,
            "questions": [
                {
                    "id": "q1",
                    "question": "Pick",
                    "options": [
                        {"value": "a", "label": "A", "icon": "star", "color": "#ff0000"}
                    ],
                    "futureField": 42
                }
            ]
        }
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUIRequest(let req) = msg else {
            Issue.record("Expected .extensionUIRequest, got \(msg)")
            return
        }
        #expect(req.askQuestions?.count == 1)
        #expect(req.askQuestions?.first?.options.first?.value == "a")
    }

    @Test func genericSelectDecodesWithoutAskQuestions() throws {
        // method: "select" keeps the raw Pi extension UI fields separate from askQuestions.
        let json = """
        {"type":"extension_ui_request","id":"ext1","sessionId":"s1","method":"select","title":"Choose","options":["A","B"]}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUIRequest(let req) = msg else {
            Issue.record("Expected .extensionUIRequest, got \(msg)")
            return
        }
        #expect(req.method == "select")
        #expect(req.askQuestions == nil)
        #expect(req.options == ["A", "B"])
    }

    // MARK: - AskRequest Model

    @Test func askRequestEquatable() {
        let q = AskQuestion(
            id: "q1",
            question: "Pick",
            options: [AskOption(value: "a", label: "A")],
            multiSelect: false
        )
        let r1 = AskRequest(id: "r1", sessionId: "s1", questions: [q], allowCustom: true, timeout: nil)
        let r2 = AskRequest(id: "r1", sessionId: "s1", questions: [q], allowCustom: true, timeout: nil)
        #expect(r1 == r2)
    }

    @Test func askQuestionIdentifiable() {
        let q = AskQuestion(
            id: "unique-id",
            question: "test",
            options: [],
            multiSelect: false
        )
        #expect(q.id == "unique-id")
    }

    @Test func extensionSelectInlineAskExtractsOptionDescriptions() {
        let request = ExtensionUIRequest(
            id: "ext-approval",
            sessionId: "s1",
            method: "select",
            title: """
            Touch approval extension

            This changes the native extension approval path.

            Tool: bash
            Input: {"command":"npm test"}

            Allow this tool call?

              Allow once: Run this tool call now
              Deny: Block the tool call
            """,
            options: ["Allow once", "Deny"]
        )

        let ask = request.inlineAskRequest

        #expect(ask?.questions.first?.question.contains("Touch approval extension") == true)
        #expect(ask?.questions.first?.question.contains("Allow once: Run this tool call now") == false)
        #expect(ask?.questions.first?.options[0].description == "Run this tool call now")
        #expect(ask?.questions.first?.options[1].description == "Block the tool call")
    }

    @Test func extensionSelectInlineAskPreservesIndentedOptionLikePromptContent() {
        let request = ExtensionUIRequest(
            id: "ext-permission",
            sessionId: "s1",
            method: "select",
            title: """
            Review this command before allowing it.

            Input:
              cat <<'EOF'
              Deny: this is command input, not an answer description
              EOF

            Allow this tool call?

              Allow once: Run this tool call now
              Deny: Block the tool call
            """,
            options: ["Allow once", "Deny"]
        )

        let ask = request.inlineAskRequest
        let question = ask?.questions.first?.question ?? ""

        #expect(question.contains("Deny: this is command input, not an answer description"))
        #expect(question.contains("Allow once: Run this tool call now") == false)
        #expect(ask?.questions.first?.options[0].description == "Run this tool call now")
        #expect(ask?.questions.first?.options[1].description == "Block the tool call")
    }

    @Test func extensionSelectInlineResponseMapsSingleAnswerToValue() throws {
        let request = ExtensionUIRequest(
            id: "select-1",
            sessionId: "s1",
            method: "select",
            options: ["A", "B"]
        )

        let ask = try #require(request.askRequest)
        let payload = try #require(ask.responsePayload(from: [
            ExtensionUIRequest.inlineQuestionId: .single("B"),
        ]))

        #expect(ask.responseEncoding == .extensionSelect)
        #expect(payload == ExtensionUIResponsePayload(value: "B"))
    }

    @Test func extensionSelectInlineResponseCancelsWhenMissingAnswer() throws {
        let request = ExtensionUIRequest(
            id: "select-2",
            sessionId: "s1",
            method: "select",
            options: ["A", "B"]
        )

        let ask = try #require(request.askRequest)
        let payload = try #require(ask.responsePayload(from: [:]))

        #expect(ask.responseEncoding == .extensionSelect)
        #expect(payload == .cancelled)
    }

    @Test func extensionConfirmInlineResponseMapsConfirmAndCancel() throws {
        let request = ExtensionUIRequest(id: "confirm-1", sessionId: "s1", method: "confirm")
        let ask = try #require(request.askRequest)

        let confirmed = try #require(ask.responsePayload(from: [
            ExtensionUIRequest.inlineQuestionId: .single(ExtensionUIRequest.confirmValue),
        ]))
        let cancelled = try #require(ask.responsePayload(from: [
            ExtensionUIRequest.inlineQuestionId: .single(ExtensionUIRequest.cancelValue),
        ]))

        #expect(ask.responseEncoding == .extensionConfirm)
        #expect(confirmed == ExtensionUIResponsePayload(confirmed: true))
        #expect(cancelled == .cancelled)
    }

    @Test func extensionInputInlineResponseMapsTextAnswersToValue() throws {
        let request = ExtensionUIRequest(id: "input-1", sessionId: "s1", method: "input")
        let ask = try #require(request.askRequest)

        let custom = try #require(ask.responsePayload(from: [
            ExtensionUIRequest.inlineQuestionId: .custom("custom text"),
        ]))
        let single = try #require(ask.responsePayload(from: [
            ExtensionUIRequest.inlineQuestionId: .single("single text"),
        ]))

        #expect(ask.responseEncoding == .extensionInput)
        #expect(custom == ExtensionUIResponsePayload(value: "custom text"))
        #expect(single == ExtensionUIResponsePayload(value: "single text"))
    }

    @Test func extensionInputInlineResponseCancelsWhenMissingText() throws {
        let request = ExtensionUIRequest(id: "input-2", sessionId: "s1", method: "input")

        let ask = try #require(request.askRequest)
        let payload = try #require(ask.responsePayload(from: [:]))

        #expect(ask.responseEncoding == .extensionInput)
        #expect(payload == .cancelled)
    }

    @Test func extensionEditorDoesNotProduceInlineResponsePayload() {
        let request = ExtensionUIRequest(id: "editor-1", sessionId: "s1", method: "editor")

        #expect(request.nativePresentation == .editorSheet)
        #expect(request.askRequest == nil)
        #expect(request.inlineAskRequest == nil)
    }

    @Test func extensionDialogPresentationKeepsStandardPromptsInlineAndEditorSheet() {
        let ask = ExtensionUIRequest(
            id: "ask-1",
            sessionId: "s1",
            method: "ask",
            askQuestions: [
                AskQuestion(id: "q1", question: "Proceed?", options: [
                    AskOption(value: "yes", label: "Yes"),
                ], multiSelect: false),
            ],
            allowCustom: false
        )
        let select = ExtensionUIRequest(id: "select-1", sessionId: "s1", method: "select", options: ["A"])
        let confirm = ExtensionUIRequest(id: "confirm-1", sessionId: "s1", method: "confirm")
        let input = ExtensionUIRequest(id: "input-1", sessionId: "s1", method: "input")
        let editor = ExtensionUIRequest(id: "editor-1", sessionId: "s1", method: "editor")
        let emptySelect = ExtensionUIRequest(id: "empty-select", sessionId: "s1", method: "select", options: [])
        let future = ExtensionUIRequest(id: "future-1", sessionId: "s1", method: "futureForm")

        #expect(ask.nativePresentation == .askCard)
        #expect(ask.askRequest?.id == "ask-1")
        #expect(ask.askRequest?.allowCustom == false)
        #expect(ask.askRequest?.responseEncoding == .ask)
        #expect(ask.inlineAskRequest == nil)

        #expect(select.nativePresentation == .inlineAskCard)
        #expect(select.askRequest?.responseEncoding == .extensionSelect)
        #expect(confirm.nativePresentation == .inlineAskCard)
        #expect(confirm.askRequest?.responseEncoding == .extensionConfirm)
        #expect(input.nativePresentation == .inlineAskCard)
        #expect(input.askRequest?.responseEncoding == .extensionInput)

        #expect(editor.nativePresentation == .editorSheet)
        #expect(editor.askRequest == nil)
        #expect(editor.inlineAskRequest == nil)

        #expect(emptySelect.nativePresentation == .fallbackSheet)
        #expect(emptySelect.askRequest == nil)
        #expect(emptySelect.inlineAskRequest == nil)

        #expect(future.nativePresentation == .fallbackSheet)
        #expect(future.askRequest == nil)
        #expect(future.inlineAskRequest == nil)
    }

    // MARK: - Router Integration

    @Test @MainActor func routerRoutesAskToAskRequestStore() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        let request = ExtensionUIRequest(
            id: "ask-r1",
            sessionId: "s1",
            method: "ask",
            timeout: 60000,
            askQuestions: [
                AskQuestion(id: "q1", question: "Pick one", options: [
                    AskOption(value: "a", label: "A"),
                    AskOption(value: "b", label: "B"),
                ], multiSelect: false),
            ],
            allowCustom: true
        )

        let message = ServerMessage.extensionUIRequest(request)
        conn.handleActiveSessionUI(message, sessionId: "s1")

        let pendingAsk = conn.askRequestStore.pending(for: "s1")
        #expect(pendingAsk != nil)
        #expect(pendingAsk?.id == "ask-r1")
        #expect(pendingAsk?.questions.count == 1)
        #expect(pendingAsk?.allowCustom == true)
        #expect(pendingAsk?.timeout == 60000)
        // Generic dialog should NOT be set
        #expect(conn.activeExtensionDialog == nil)
    }

    @Test @MainActor func routerRoutesSelectToAskRequestStore() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        let request = ExtensionUIRequest(
            id: "ext-1",
            sessionId: "s1",
            method: "select",
            title: "Choose",
            options: ["A", "B"]
        )

        let message = ServerMessage.extensionUIRequest(request)
        conn.handleActiveSessionUI(message, sessionId: "s1")

        let pendingAsk = conn.askRequestStore.pending(for: "s1")
        #expect(pendingAsk?.id == "ext-1")
        #expect(pendingAsk?.responseEncoding == .extensionSelect)
        #expect(conn.activeExtensionDialog == nil)
    }

    @Test @MainActor func disconnectClearsFocusedSessionAndPreservesPendingAsk() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        let ask = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Q", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        conn.askRequestStore.set(ask, for: "s1")

        conn.disconnectSession()

        #expect(conn.focusedSessionId == nil)
        #expect(conn.askRequestStore.pending(for: "s1")?.id == "ask-1")
    }

    @Test @MainActor func disconnectPreservesPendingAskForRestore() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        let ask = AskRequest(
            id: "ask-stash",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Q", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        conn.askRequestStore.set(ask, for: "s1")

        conn.disconnectSession()

        #expect(conn.focusedSessionId == nil)
        #expect(conn.askRequestStore.pending(for: "s1")?.id == "ask-stash")
    }

    @Test @MainActor func focusSessionRestoresPendingAsk() {
        let conn = ServerConnection()
        let ask = AskRequest(
            id: "ask-pending",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Q", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        conn.askRequestStore.set(ask, for: "s1")

        conn.focusSession("s1")

        #expect(conn.askRequestStore.pending(for: "s1")?.id == "ask-pending")
    }

    @Test @MainActor func focusSessionPreservesPreviousAskAndStopsWatchdogOnHandoff() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        let firstAsk = AskRequest(
            id: "ask-s1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Q1", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        let secondAsk = AskRequest(
            id: "ask-s2",
            sessionId: "s2",
            questions: [AskQuestion(id: "q2", question: "Q2", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )

        conn.askRequestStore.set(firstAsk, for: "s1")
        conn.askRequestStore.set(secondAsk, for: "s2")
        conn.handleActiveSessionUI(.agentStart, sessionId: "s1")

        #expect(conn.silenceWatchdog.lastEventTime != nil)

        conn.focusSession("s2")

        #expect(conn.askRequestStore.pending(for: "s1")?.id == "ask-s1")
        #expect(conn.askRequestStore.pending(for: "s2")?.id == "ask-s2")
        #expect(conn.silenceWatchdog.lastEventTime == nil)
    }

    @Test @MainActor func routeStreamMessageStoresAskForInactiveSession() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("active")

        let (_, continuation) = AsyncStream<SessionStreamEvent>.makeStream()
        conn.sessionEventContinuations["s2"] = continuation

        let request = ExtensionUIRequest(
            id: "ask-other",
            sessionId: "s2",
            method: "ask",
            askQuestions: [AskQuestion(id: "q1", question: "Other?", options: [
                AskOption(value: "a", label: "A"),
            ], multiSelect: false)],
            allowCustom: true
        )

        conn.routeStreamMessage(StreamMessage(
            sessionId: "s2",
            seq: 1,
            currentSeq: nil,
            message: .extensionUIRequest(request)
        ))

        #expect(conn.askRequestStore.pending(for: "active") == nil)
        #expect(conn.askRequestStore.pending(for: "s2")?.id == "ask-other")
    }

    @Test @MainActor func inactiveTerminalMessagesClearPendingAskForInactiveSession() {
        let terminalMessages: [ServerMessage] = [
            .stopConfirmed(source: .user, reason: nil),
            .sessionEnded(reason: "done"),
        ]

        for message in terminalMessages {
            let conn = ServerConnection()
            conn._setActiveSessionIdForTesting("active")

            let ask = AskRequest(
                id: "ask-stale",
                sessionId: "s2",
                questions: [AskQuestion(id: "q1", question: "Q", options: [], multiSelect: false)],
                allowCustom: true,
                timeout: nil
            )
            conn.askRequestStore.set(ask, for: "s2")

            conn.routeStreamMessage(StreamMessage(
                sessionId: "s2",
                seq: 1,
                currentSeq: nil,
                message: message
            ))

            #expect(conn.askRequestStore.pending(for: "s2") == nil)

            conn.focusSession("s2")
            #expect(conn.askRequestStore.pending(for: "s2") == nil)
        }
    }

    @Test @MainActor func inactiveTerminalMessagesClearStashedExtensionDialog() {
        let terminalMessages: [ServerMessage] = [
            .stopConfirmed(source: .user, reason: nil),
            .sessionEnded(reason: "done"),
        ]

        for message in terminalMessages {
            let conn = ServerConnection()
            conn._setActiveSessionIdForTesting("active")

            conn.pendingExtensionDialogs["s2"] = ExtensionUIRequest(
                id: "editor-stale",
                sessionId: "s2",
                method: "editor",
                title: "Edit"
            )

            conn.routeStreamMessage(StreamMessage(
                sessionId: "s2",
                seq: 1,
                currentSeq: nil,
                message: message
            ))

            #expect(conn.pendingExtensionDialogs["s2"] == nil)

            conn.focusSession("s2")
            #expect(conn.activeExtensionDialog == nil)
        }
    }

    @Test @MainActor func inactiveTerminalStateClearsPendingAskForInactiveSession() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("active")
        conn.sessionStore.upsert(makeTestSession(id: "s2", status: .busy))

        let ask = AskRequest(
            id: "ask-state",
            sessionId: "s2",
            questions: [AskQuestion(id: "q1", question: "Q", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        conn.askRequestStore.set(ask, for: "s2")

        conn.routeStreamMessage(StreamMessage(
            sessionId: "s2",
            seq: 1,
            currentSeq: nil,
            message: .state(session: makeTestSession(id: "s2", status: .ready))
        ))

        #expect(conn.askRequestStore.pending(for: "s2") == nil)

        conn.focusSession("s2")
        #expect(conn.askRequestStore.pending(for: "s2") == nil)
    }

    @Test @MainActor func secondAskWaitsBehindFirst() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        let first = ExtensionUIRequest(
            id: "ask-1",
            sessionId: "s1",
            method: "ask",
            askQuestions: [AskQuestion(id: "q1", question: "First?", options: [
                AskOption(value: "a", label: "A"),
            ], multiSelect: false)],
            allowCustom: true
        )
        conn.handleActiveSessionUI(.extensionUIRequest(first), sessionId: "s1")
        #expect(conn.askRequestStore.pending(for: "s1")?.id == "ask-1")

        let second = ExtensionUIRequest(
            id: "ask-2",
            sessionId: "s1",
            method: "ask",
            askQuestions: [AskQuestion(id: "q2", question: "Second?", options: [
                AskOption(value: "b", label: "B"),
            ], multiSelect: false)],
            allowCustom: false
        )
        conn.handleActiveSessionUI(.extensionUIRequest(second), sessionId: "s1")
        #expect(conn.askRequestStore.pending(for: "s1")?.id == "ask-1")

        conn.clearAskRequest(id: "ask-1")

        #expect(conn.askRequestStore.pending(for: "s1")?.id == "ask-2")
        #expect(conn.askRequestStore.pending(for: "s1")?.allowCustom == false)
    }

    @Test @MainActor func extensionUIResponseClearsOnlyAnsweredInlineAsk() async throws {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")
        conn._sendMessageForTesting = { _ in }

        let first = ExtensionUIRequest(
            id: "select-1",
            sessionId: "s1",
            method: "select",
            title: "First URL",
            options: ["Approve once", "Deny"]
        )
        let second = ExtensionUIRequest(
            id: "select-2",
            sessionId: "s1",
            method: "select",
            title: "Second URL",
            options: ["Approve once", "Deny"]
        )

        conn.handleActiveSessionUI(.extensionUIRequest(first), sessionId: "s1")
        conn.handleActiveSessionUI(.extensionUIRequest(second), sessionId: "s1")
        #expect(conn.askRequestStore.pending(for: "s1")?.id == "select-1")

        try await conn.respondToExtensionUI(
            id: "select-1",
            sessionId: "s1",
            payload: ExtensionUIResponsePayload(value: "Approve once")
        )

        #expect(conn.askRequestStore.pending(for: "s1")?.id == "select-2")
    }
}
