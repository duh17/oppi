import UIKit

/// What the composer's primary button does: send, ignore the Ask, or stop.
enum ComposerPrimaryActionKind: Equatable {
    case send
    case ignoreAsk
    case stop
}

/// Owns inline-ask paging, draft answers, and the submitted-request mark
/// that keeps the composer empty after submit/ignore until a different ask arrives.
@MainActor
struct AskComposerClearingState {
    var currentPage = 0
    var draftAnswers: [String: AskAnswer] = [:]
    var textRevision: UInt64 = 0
    var submission = AskResponseSubmission()
    var submittedRequestID: String? { submission.submittedRequestID }

    /// Ask request id changed. Reset page and drafts. Keep the submitted mark
    /// unless a *different* ask id arrived. Clearing the pending request after
    /// a successful send must not drop the mark.
    mutating func applyRequestIDChange(_ incomingRequestID: String?) {
        currentPage = 0
        draftAnswers = [:]
        submission.applyRequestIDChange(incomingRequestID)
    }
}

/// The composer bar's decisions: what shows, what the field says, what the
/// primary button does, and how an inline Ask's answers advance. Pure values,
/// so `ComposerBarController` and its tests share them.
@MainActor
enum ComposerPolicy {
    static func composerTextTrailingPadding(showsExpandButton: Bool) -> CGFloat {
        showsExpandButton ? 10 : 0
    }

    static func shouldShowExpandButton(
        allowsExpansion: Bool,
        visualLineCount: Int,
        threshold: Int,
        maxLines: Int
    ) -> Bool {
        allowsExpansion && visualLineCount >= min(threshold, maxLines)
    }

    static func inlineTextMaxLines(
        hasAskRequest: Bool,
        hasAttachments: Bool,
        hasRepoPointers: Bool
    ) -> Int {
        if hasAskRequest || hasAttachments || hasRepoPointers {
            return ComposerInputMetrics.inlineMaxLinesWithAttachments
        }
        return ComposerInputMetrics.inlineMaxLines
    }

    static func canSubmitMessage(
        allowsEmptySubmit: Bool,
        text: String,
        hasImages: Bool,
        hasFiles: Bool,
        hasReviewComments: Bool
    ) -> Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return allowsEmptySubmit || hasText || hasImages || hasFiles || hasReviewComments
    }

    static func allowKeyboardRestoreOnTap(voiceState _: VoiceInputManager.State) -> Bool {
        true
    }

    static func shouldShowComposerActionRow(
        alwaysShowActionRow: Bool,
        isBusy _: Bool,
        isInputFocused: Bool,
        isKeyboardSuppressed _: Bool,
        hasAttachments: Bool,
        hasRepoPointers: Bool
    ) -> Bool {
        alwaysShowActionRow
            || isInputFocused
            || hasAttachments
            || hasRepoPointers
    }

    static func suppressKeyboardAfterSend(
        voiceState: VoiceInputManager.State,
        wasSuppressed: Bool
    ) -> Bool {
        switch voiceState {
        case .recording, .preparingModel:
            return wasSuppressed
        case .idle, .processing, .error:
            return wasSuppressed
        }
    }

    static func composerPlaceholder(
        askRequest: AskRequest?,
        pendingReviewCommentCount: Int,
        isBusy: Bool,
        busyStreamingBehavior: StreamingBehavior
    ) -> String {
        if pendingReviewCommentCount > 0 {
            return "Send \(pendingReviewCommentCount) review \(pendingReviewCommentCount == 1 ? "comment" : "comments")…"
        }
        if let askRequest {
            let includesMultiSelect = askRequest.questions.contains { $0.multiSelect }
            if askRequest.allowCustom {
                if let placeholder = askRequest.customPlaceholder?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !placeholder.isEmpty {
                    return placeholder
                }
                return includesMultiSelect ? "Select options or type…" : "Type answer…"
            }
            return includesMultiSelect ? "Select options…" : "Choose an option…"
        }
        guard isBusy else { return "Message…" }
        return busyStreamingBehavior == .steer ? "Steer agent…" : "Queue follow-up…"
    }

    static func primaryActionKind(
        isBusy: Bool,
        canSend: Bool,
        isSending: Bool,
        hasAskRequest: Bool
    ) -> ComposerPrimaryActionKind {
        if canSend || isSending {
            return .send
        }
        guard isBusy else { return .send }
        return hasAskRequest ? .ignoreAsk : .stop
    }

    static func showsBusyModeSelector(isBusy: Bool, hasAskRequest: Bool) -> Bool {
        isBusy && !hasAskRequest
    }

    static func customAskAnswers(
        request: AskRequest?,
        activeQuestionID: String? = nil,
        draftAnswers: [String: AskAnswer] = [:],
        text: String
    ) -> [String: AskAnswer]? {
        guard let request,
              request.allowCustom,
              let question = customAskQuestion(request: request, activeQuestionID: activeQuestionID)
        else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var answers = draftAnswers
        answers[question.id] = .custom(trimmed)
        return answers
    }

    private static func customAskQuestion(request: AskRequest, activeQuestionID: String?) -> AskQuestion? {
        if let activeQuestionID,
           let question = request.questions.first(where: { $0.id == activeQuestionID }) {
            return question
        }
        return request.questions.first
    }

    static func shouldSubmitAskResponseImmediately(request: AskRequest?, currentPage: Int) -> Bool {
        guard let request else { return false }
        guard request.questions.count > 1 else { return true }
        return currentPage >= request.questions.count - 1
    }

    static func customAskText(answers: [String: AskAnswer], questionID: String?) -> String {
        guard let questionID, case .custom(let text) = answers[questionID] else {
            return ""
        }
        return text
    }

    static func composerTextForActiveAskQuestion(
        request: AskRequest?,
        activeQuestionID: String?,
        draftAnswers: [String: AskAnswer],
        keepComposerClearedForSubmittedRequestID: String?
    ) -> String? {
        if let submittedRequestID = keepComposerClearedForSubmittedRequestID {
            if request == nil {
                return nil
            }
            if request?.id == submittedRequestID {
                return ""
            }
        }
        guard let request else { return nil }
        guard request.allowCustom else { return "" }
        return customAskText(answers: draftAnswers, questionID: activeQuestionID)
    }

    struct AskComposerSendTransition: Equatable {
        let nextPage: Int
        let answers: [String: AskAnswer]
        let nextComposerText: String
        let shouldSubmit: Bool
    }

    static func askComposerSendTransition(
        request: AskRequest?,
        currentPage: Int,
        draftAnswers: [String: AskAnswer],
        text: String
    ) -> AskComposerSendTransition? {
        guard let request,
              request.questions.indices.contains(currentPage) else {
            return nil
        }

        let activeQuestionID = request.questions[currentPage].id
        let answers: [String: AskAnswer]
        if let customAnswers = customAskAnswers(
            request: request,
            activeQuestionID: activeQuestionID,
            draftAnswers: draftAnswers,
            text: text
        ) {
            answers = customAnswers
        } else {
            guard draftAnswers[activeQuestionID] != nil else { return nil }
            answers = draftAnswers
        }

        if shouldSubmitAskResponseImmediately(request: request, currentPage: currentPage) {
            return AskComposerSendTransition(
                nextPage: currentPage,
                answers: answers,
                nextComposerText: "",
                shouldSubmit: true
            )
        }

        let nextPage = min(currentPage + 1, request.questions.count - 1)
        let nextQuestionID = request.questions[nextPage].id
        return AskComposerSendTransition(
            nextPage: nextPage,
            answers: answers,
            nextComposerText: customAskText(answers: answers, questionID: nextQuestionID),
            shouldSubmit: false
        )
    }
}
