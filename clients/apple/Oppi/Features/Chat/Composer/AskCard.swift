import Observation
import UIKit

/// A local response claim, not server settlement. Both card and composer claim
/// synchronously; delivery completion releases failed attempts, including any
/// mixed-action callbacks that joined the same in-flight response.
@MainActor
@Observable
final class AskResponseSubmission {
    enum Result { case completed, retryableFailure }
    enum Phase: Equatable {
        case idle, inFlight(String), failed(String), completed(String)
    }
    typealias Completion = @MainActor (Result) -> Void
    typealias Delivery = (@escaping Completion) -> Void

    private(set) var phase: Phase = .idle
    private var requestID: String?
    private var attemptID: UUID?
    private var completions: [Completion] = []

    var submittedRequestID: String? {
        switch phase {
        case .inFlight(let id), .completed(let id): id
        case .idle, .failed: nil
        }
    }

    func blocksResponse(to requestID: String) -> Bool {
        submittedRequestID == requestID
    }

    func submit(
        requestID: String,
        deliver: Delivery,
        completion: @escaping Completion = { _ in }
    ) {
        if self.requestID == nil, phase == .idle {
            self.requestID = requestID
        }
        guard self.requestID == requestID else {
            completion(.completed)
            return
        }
        if phase == .inFlight(requestID) {
            completions.append(completion)
            return
        }
        guard !blocksResponse(to: requestID) else {
            completion(.completed)
            return
        }
        let attempt = UUID()
        attemptID = attempt
        phase = .inFlight(requestID)
        completions.append(completion)
        deliver { [self] result in
            guard attemptID == attempt else { return }
            attemptID = nil
            phase = result == .completed ? .completed(requestID) : .failed(requestID)
            finishCallbacks(result)
        }
    }

    func applyRequestIDChange(_ incomingID: String?) {
        let currentID: String?
        switch phase {
        case .idle: currentID = nil
        case .inFlight(let id), .failed(let id), .completed(let id): currentID = id
        }
        guard incomingID != requestID else { return }
        requestID = incomingID
        attemptID = nil
        // Removing a request is settlement, not a failed delivery. Keep its
        // closed identity so a queued old action cannot rearm it.
        if incomingID == nil, let currentID {
            phase = .completed(currentID)
        } else {
            phase = .idle
        }
        finishCallbacks(.completed)
    }

    private func finishCallbacks(_ result: Result) {
        let callbacks = completions
        completions = []
        for callback in callbacks { callback(result) }
    }
}

// MARK: - AskCard helpers

/// Rules for the inline Ask card in the composer (`AskCardViewController`).
///
/// A single question with single choice sends on tap. Several questions page,
/// one question per page, with no extra review page. Inline question text is
/// capped so an urgent approval cannot cover the whole chat; the expanded
/// sheet shows the full request.
@MainActor
enum AskCard {
    static let quietControlMinimumHitSize: CGFloat = ComposerInputMetrics.controlDiameter
    static let ignoreAccessibilityIdentifier = "ask.ignore"

    static func pageAccessibilityIdentifier(_ page: Int) -> String {
        "ask.page.\(page)"
    }

    /// One page per question; no extra review page.
    static func pageCount(for request: AskRequest) -> Int {
        max(1, request.questions.count)
    }

    static func clampedPage(_ page: Int, for request: AskRequest) -> Int {
        let maxPage = max(0, pageCount(for: request) - 1)
        return min(max(page, 0), maxPage)
    }

    static func timestampNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func responseMetricTags(
        request: AskRequest,
        answers: [String: AskAnswer],
        outcome: String,
        surface: String
    ) -> [String: String] {
        let questionCount = request.questions.count
        let answeredCount = answers.count
        let ignoredCount = max(0, questionCount - answeredCount)
        let multiSelectQuestionCount = request.questions.filter(\.multiSelect).count
        let selectedCount = answers.values.reduce(0) { count, answer in
            switch answer {
            case .single:
                return count + 1
            case .multi(let values):
                return count + values.count
            case .custom:
                return count + 1
            }
        }
        let hasCustomAnswer = answers.values.contains { answer in
            if case .custom = answer { return true }
            return false
        }

        return [
            "outcome": outcome,
            "surface": surface,
            "question_count": countBucket(questionCount),
            "answered_count": countBucket(answeredCount),
            "ignored_count": countBucket(ignoredCount),
            "multi_select": multiSelectQuestionCount > 0 ? "1" : "0",
            "multi_select_count": countBucket(multiSelectQuestionCount),
            "custom": hasCustomAnswer ? "1" : "0",
            "allow_custom": request.allowCustom ? "1" : "0",
            "selected_count": countBucket(selectedCount),
            "response_encoding": responseEncodingTag(request.responseEncoding),
        ]
    }

    private static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<0: return "0"
        case 0...5: return String(count)
        case 6...10: return "6-10"
        default: return "11+"
        }
    }

    private static func responseEncodingTag(_ encoding: AskResponseEncoding) -> String {
        switch encoding {
        case .ask: return "ask"
        case .extensionSelect: return "select"
        case .extensionConfirm: return "confirm"
        case .extensionInput: return "input"
        }
    }

    static func inlineQuestionDisplay(for question: String) -> (summary: String, commandPreview: String?) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        guard let headingIndex = lines.firstIndex(where: isCommandSectionHeading) else {
            return (trimmed, nil)
        }

        let summary = lines[..<headingIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            summary,
            commandPreview(from: lines, after: headingIndex)
        )
    }

    static func inlineQuestionLineLimit(for category: UIContentSizeCategory) -> Int {
        category.isAccessibilityCategory ? 8 : 6
    }

    private static func isCommandSectionHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return false }
        let title = String(trimmed.drop(while: { $0 == "#" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.caseInsensitiveCompare("Command") == .orderedSame
    }

    private static func commandPreview(from lines: [String], after headingIndex: Int) -> String? {
        var index = headingIndex + 1
        while index < lines.count,
              lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }
        guard index < lines.count else { return nil }

        let firstLine = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = commandFenceMarker(for: firstLine) {
            index += 1
            var commandLines: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(fence) {
                    break
                }
                commandLines.append(line)
                index += 1
            }
            return normalizedCommandPreview(commandLines.joined(separator: "\n"))
        }

        var commandLines: [String] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") { break }
            if trimmed.isEmpty {
                if commandLines.isEmpty {
                    index += 1
                    continue
                }
                break
            }
            commandLines.append(line)
            index += 1
        }

        return normalizedCommandPreview(commandLines.joined(separator: "\n"))
    }

    private static func commandFenceMarker(for line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func normalizedCommandPreview(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func usesInlineQuestionPreview(
        _ question: String,
        contentSizeCategory: UIContentSizeCategory
    ) -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let nonEmptyLineCount = trimmed
            .split(whereSeparator: \.isNewline)
            .filter { !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count

        if nonEmptyLineCount > inlineQuestionLineLimit(for: contentSizeCategory) {
            return true
        }

        let characterLimit = contentSizeCategory.isAccessibilityCategory ? 420 : 280
        return trimmed.count > characterLimit
    }

    /// VoiceOver announcement text when the page changes.
    static func pageAnnouncementText(
        page: Int,
        questions: [AskQuestion],
        isSingleQuestionSingleSelect: Bool
    ) -> String {
        guard !isSingleQuestionSingleSelect else { return questions[0].question }
        if questions.isEmpty {
            return ""
        }
        let clampedPage = min(max(page, 0), questions.count - 1)
        return "Question \(clampedPage + 1) of \(questions.count): \(questions[clampedPage].question)"
    }
}

// MARK: - Inline auto-advance

/// Owns the delayed single-select page advance on the inline ask card.
///
/// A newer selection, Ignore, explicit page change, submit, expansion, or
/// request replacement must cancel and invalidate any pending follow-through.
@MainActor
final class AskInlineAutoAdvanceController {
    struct Identity: Equatable {
        var requestID: String
        var page: Int
        var questionIDs: [String]
    }

    static let defaultDelay: Duration = .milliseconds(200)

    typealias Wait = @MainActor (Duration) async throws -> Void

    private var pending: Task<Void, Never>?
    private(set) var generation: UInt64 = 0
    private(set) var current: Identity?
    private let delay: Duration
    private let wait: Wait

    init(
        delay: Duration = defaultDelay,
        wait: @escaping Wait = { try await Task.sleep(for: $0) }
    ) {
        self.delay = delay
        self.wait = wait
    }

    func noteIdentity(request: AskRequest, page: Int) {
        noteIdentity(
            requestID: request.id,
            page: page,
            questionIDs: request.questions.map(\.id)
        )
    }

    func noteIdentity(requestID: String, page: Int, questionIDs: [String]) {
        current = Identity(requestID: requestID, page: page, questionIDs: questionIDs)
    }

    func invalidate() {
        pending?.cancel()
        pending = nil
        generation &+= 1
    }

    func schedule(
        requestID: String,
        page: Int,
        advance: @escaping @MainActor () -> Void
    ) {
        invalidate()
        let scheduledGeneration = generation
        let scheduled = Identity(
            requestID: requestID,
            page: page,
            questionIDs: current?.questionIDs ?? []
        )
        let wait = self.wait
        let delay = self.delay
        pending = Task {
            do {
                try await wait(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard scheduledGeneration == self.generation else { return }
            guard self.current == scheduled else { return }
            advance()
        }
    }
}
