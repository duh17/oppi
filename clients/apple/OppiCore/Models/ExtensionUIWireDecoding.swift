import Foundation

extension ExtensionUIRequest: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, method, title, options, message, placeholder, prefill
        case timeout, timeoutAt, workspaceId, questions, allowCustom, extensionScopeId, extensionDisplayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            sessionId: try c.decode(String.self, forKey: .sessionId),
            method: try c.decode(String.self, forKey: .method),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            options: try c.decodeIfPresent([String].self, forKey: .options),
            message: try c.decodeIfPresent(String.self, forKey: .message),
            placeholder: try c.decodeIfPresent(String.self, forKey: .placeholder),
            prefill: try c.decodeIfPresent(String.self, forKey: .prefill),
            timeout: try c.decodeIfPresent(Int.self, forKey: .timeout),
            timeoutAt: try c.decodeIfPresent(Double.self, forKey: .timeoutAt).map { Date(timeIntervalSince1970: $0 / 1000) },
            workspaceId: try c.decodeIfPresent(String.self, forKey: .workspaceId),
            extensionScopeId: try c.decodeIfPresent(String.self, forKey: .extensionScopeId),
            extensionDisplayName: try c.decodeIfPresent(String.self, forKey: .extensionDisplayName),
            askQuestions: try c.decodeIfPresent([AskQuestion].self, forKey: .questions),
            allowCustom: try c.decodeIfPresent(Bool.self, forKey: .allowCustom)
        )
    }
}

extension ExtensionUIRequest {
    /// Session-scoped `/dialogs` records omit `sessionId` / `workspaceId`.
    /// Inject those ids before reuse of `askRequest` / dialog queues.
    struct DialogSnapshot: Decodable, Sendable, Equatable {
        let id: String
        let method: String
        let title: String?
        let options: [String]?
        let message: String?
        let placeholder: String?
        let prefill: String?
        let timeout: Int?
        let timeoutAt: Date?
        let workspaceId: String?
        let extensionScopeId: String?
        let extensionDisplayName: String?
        let questions: [AskQuestion]?
        let allowCustom: Bool?

        private enum CodingKeys: String, CodingKey {
            case id, method, title, options, message, placeholder, prefill
            case timeout, timeoutAt, workspaceId, questions, allowCustom
            case extensionScopeId, extensionDisplayName
        }

        init(
            id: String,
            method: String,
            title: String? = nil,
            options: [String]? = nil,
            message: String? = nil,
            placeholder: String? = nil,
            prefill: String? = nil,
            timeout: Int? = nil,
            timeoutAt: Date? = nil,
            workspaceId: String? = nil,
            extensionScopeId: String? = nil,
            extensionDisplayName: String? = nil,
            questions: [AskQuestion]? = nil,
            allowCustom: Bool? = nil
        ) {
            self.id = id
            self.method = method
            self.title = title
            self.options = options
            self.message = message
            self.placeholder = placeholder
            self.prefill = prefill
            self.timeout = timeout
            self.timeoutAt = timeoutAt
            self.workspaceId = workspaceId
            self.extensionScopeId = extensionScopeId
            self.extensionDisplayName = extensionDisplayName
            self.questions = questions
            self.allowCustom = allowCustom
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            method = try c.decode(String.self, forKey: .method)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            options = try c.decodeIfPresent([String].self, forKey: .options)
            message = try c.decodeIfPresent(String.self, forKey: .message)
            placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
            prefill = try c.decodeIfPresent(String.self, forKey: .prefill)
            timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
            timeoutAt = try c.decodeIfPresent(Double.self, forKey: .timeoutAt).map {
                Date(timeIntervalSince1970: $0 / 1000)
            }
            workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
            extensionScopeId = try c.decodeIfPresent(String.self, forKey: .extensionScopeId)
            extensionDisplayName = try c.decodeIfPresent(String.self, forKey: .extensionDisplayName)
            questions = try c.decodeIfPresent([AskQuestion].self, forKey: .questions)
            allowCustom = try c.decodeIfPresent(Bool.self, forKey: .allowCustom)
        }
    }

    static func fromDialogSnapshot(
        _ snapshot: DialogSnapshot,
        sessionId: String,
        workspaceId: String?
    ) -> ExtensionUIRequest {
        ExtensionUIRequest(
            id: snapshot.id,
            sessionId: sessionId,
            method: snapshot.method,
            title: snapshot.title,
            options: snapshot.options,
            message: snapshot.message,
            placeholder: snapshot.placeholder,
            prefill: snapshot.prefill,
            timeout: snapshot.timeout,
            timeoutAt: snapshot.timeoutAt,
            workspaceId: snapshot.workspaceId ?? workspaceId,
            extensionScopeId: snapshot.extensionScopeId,
            extensionDisplayName: snapshot.extensionDisplayName,
            askQuestions: snapshot.questions,
            allowCustom: snapshot.allowCustom
        )
    }
}

extension ExtensionUINotification: Decodable {
    private enum CodingKeys: String, CodingKey {
        case method, message, notifyType, statusKey, statusText, title, text
        case widgetKey, widgetLines, widgetPlacement, extensionScopeId, extensionDisplayName, workingIndicator, workingVisible
        case hiddenThinkingLabel, toolsExpanded, nativeSurface
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            method: try c.decode(String.self, forKey: .method),
            message: try c.decodeIfPresent(String.self, forKey: .message),
            notifyType: try c.decodeIfPresent(String.self, forKey: .notifyType),
            statusKey: try c.decodeIfPresent(String.self, forKey: .statusKey),
            statusText: try c.decodeIfPresent(String.self, forKey: .statusText),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            text: try c.decodeIfPresent(String.self, forKey: .text),
            widgetKey: try c.decodeIfPresent(String.self, forKey: .widgetKey),
            widgetLines: try c.decodeIfPresent([String].self, forKey: .widgetLines),
            widgetPlacement: try c.decodeIfPresent(String.self, forKey: .widgetPlacement),
            extensionScopeId: try c.decodeIfPresent(String.self, forKey: .extensionScopeId),
            extensionDisplayName: try c.decodeIfPresent(String.self, forKey: .extensionDisplayName),
            workingIndicator: try c.decodeIfPresent(ExtensionUIWorkingIndicator.self, forKey: .workingIndicator),
            workingVisible: try c.decodeIfPresent(Bool.self, forKey: .workingVisible),
            hiddenThinkingLabel: try c.decodeIfPresent(String.self, forKey: .hiddenThinkingLabel),
            toolsExpanded: try c.decodeIfPresent(Bool.self, forKey: .toolsExpanded),
            nativeSurface: try c.decodeIfPresent(ExtensionUINativeSurface.self, forKey: .nativeSurface)
        )
    }
}
