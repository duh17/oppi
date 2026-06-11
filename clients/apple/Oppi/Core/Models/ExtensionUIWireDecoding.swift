import Foundation

extension ExtensionUIRequest: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, method, title, options, message, placeholder, prefill
        case timeout, timeoutAt, workspaceId, questions, allowCustom
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
            askQuestions: try c.decodeIfPresent([AskQuestion].self, forKey: .questions),
            allowCustom: try c.decodeIfPresent(Bool.self, forKey: .allowCustom)
        )
    }
}

extension ExtensionUINotification: Decodable {
    private enum CodingKeys: String, CodingKey {
        case method, message, notifyType, statusKey, statusText, title, text
        case widgetKey, widgetLines, widgetPlacement, workingIndicator, workingVisible
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
            workingIndicator: try c.decodeIfPresent(ExtensionUIWorkingIndicator.self, forKey: .workingIndicator),
            workingVisible: try c.decodeIfPresent(Bool.self, forKey: .workingVisible),
            hiddenThinkingLabel: try c.decodeIfPresent(String.self, forKey: .hiddenThinkingLabel),
            toolsExpanded: try c.decodeIfPresent(Bool.self, forKey: .toolsExpanded),
            nativeSurface: try c.decodeIfPresent(ExtensionUINativeSurface.self, forKey: .nativeSurface)
        )
    }
}
