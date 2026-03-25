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

    @Test func genericSelectNotRoutedToAsk() throws {
        // method: "select" should NOT populate askQuestions
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

    // MARK: - Router Integration

    @Test @MainActor func routerRoutesAskToActiveAskRequest() {
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

        #expect(conn.activeAskRequest != nil)
        #expect(conn.activeAskRequest?.id == "ask-r1")
        #expect(conn.activeAskRequest?.questions.count == 1)
        #expect(conn.activeAskRequest?.allowCustom == true)
        #expect(conn.activeAskRequest?.timeout == 60000)
        // Generic dialog should NOT be set
        #expect(conn.activeExtensionDialog == nil)
    }

    @Test @MainActor func routerRoutesSelectToGenericDialog() {
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

        #expect(conn.activeExtensionDialog != nil)
        #expect(conn.activeExtensionDialog?.id == "ext-1")
        // Ask request should NOT be set
        #expect(conn.activeAskRequest == nil)
    }

    @Test @MainActor func disconnectClearsAskRequest() {
        let conn = ServerConnection()
        conn._setActiveSessionIdForTesting("s1")

        conn.activeAskRequest = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Q", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        conn.askAnswerMode = true

        conn.disconnectSession()

        #expect(conn.activeAskRequest == nil)
        #expect(conn.askAnswerMode == false)
    }

    @Test @MainActor func secondAskReplacesFirst() {
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
        #expect(conn.activeAskRequest?.id == "ask-1")

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
        #expect(conn.activeAskRequest?.id == "ask-2")
        #expect(conn.activeAskRequest?.allowCustom == false)
    }
}
