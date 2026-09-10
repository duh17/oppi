import SwiftUI
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

// MARK: - AskCard

/// Inline question card rendered inside the ChatInputBar capsule.
///
/// Supports single-question direct mode (tap option → send immediately)
/// and multi-question pager without an extra submit/review page.
///
/// Inline question text is capped to keep urgent approvals from covering the
/// whole chat. The full request remains available through `AskCardExpanded`.
struct AskCard: View {
    let request: AskRequest
    @Binding var currentPage: Int
    @Binding var answers: [String: AskAnswer]
    let onSubmit: ([String: AskAnswer], @escaping AskResponseSubmission.Completion) -> Void
    let onIgnoreAll: (@escaping AskResponseSubmission.Completion) -> Void
    var voiceInputManager: VoiceInputManager? = nil
    var submittedRequestID: String? = nil
    var responseFailed = false
    var autoAdvanceController: AskInlineAutoAdvanceController? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme

    @State private var isExpanded: Bool = false
    @State private var expandedSheetDetent: PresentationDetent = .large
    @State private var presentedAtNs: UInt64 = 0
    @State private var didRecordResponseMetric = false
    @State private var submission = AskResponseSubmission()
    @State private var ownedAutoAdvanceController = AskInlineAutoAdvanceController()

    private let cardCornerRadius: CGFloat = 14

    private var pageAdvance: AskInlineAutoAdvanceController {
        autoAdvanceController ?? ownedAutoAdvanceController
    }

    /// True when this is a single-question, single-select ask.
    /// Tap sends immediately — no pager, no submit page.
    private var isSingleQuestionSingleSelect: Bool {
        request.questions.count == 1 && !request.questions[0].multiSelect
    }

    /// Total pages: one per question.
    private var totalPages: Int {
        AskCard.pageCount(for: request)
    }

    private var currentQuestion: AskQuestion? {
        guard currentPage < request.questions.count else { return nil }
        return request.questions[currentPage]
    }

    private var isLastQuestionPage: Bool {
        !isSingleQuestionSingleSelect && currentPage == request.questions.count - 1
    }

    private var isAskSubmitted: Bool {
        submittedRequestID == request.id || submission.blocksResponse(to: request.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            FeatureEducationTipBannerHost(
                tip: FeatureEducationTips.AnswerPromptTip(),
                descriptor: FeatureEducationTips.answerPrompt,
                contentInsets: EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12)
            )

            if let question = currentQuestion {
                questionPageContent(question)
            }

            // Page indicator (multi-question only)
            if !isSingleQuestionSingleSelect {
                pageIndicator
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        .onAppear {
            if presentedAtNs == 0 {
                presentedAtNs = Self.timestampNs()
            }
            applyRequestIdentity(request, page: currentPage, invalidatePending: isAskSubmitted)
        }
        .onDisappear {
            pageAdvance.invalidate()
        }
        .padding(.vertical, 10)
        .background(theme.bg.secondary, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(theme.text.tertiary.opacity(0.15), lineWidth: 0.5)
        )
        // No client-side auto-dismiss. The ask card stays open until the user
        // responds or the session lifecycle clears it (agent_end, session_ended,
        // stop_confirmed). Server-side cleanup in agent_end cancels deferred SDK
        // promises so the agent never gets stuck waiting.
        // Announce page changes for VoiceOver
        .onChange(of: request) { _, newRequest in
            submission.applyRequestIDChange(newRequest.id)
            let clamped = Self.clampedPage(currentPage, for: newRequest)
            if clamped != currentPage {
                currentPage = clamped
            }
            applyRequestIdentity(newRequest, page: clamped, invalidatePending: true)
        }
        .onChange(of: submittedRequestID) { _, newID in
            if newID == request.id {
                pageAdvance.invalidate()
            }
        }
        .onChange(of: currentPage) {
            applyRequestIdentity(request, page: currentPage, invalidatePending: true)
            let text = Self.pageAnnouncementText(
                page: currentPage,
                questions: request.questions,
                isSingleQuestionSingleSelect: isSingleQuestionSingleSelect
            )
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        .onChange(of: isExpanded) {
            if isExpanded {
                pageAdvance.invalidate()
            }
        }
        .sheet(isPresented: $isExpanded) {
            AskCardExpanded(
                request: request,
                currentPage: $currentPage,
                answers: $answers,
                isExpanded: $isExpanded,
                voiceInputManager: voiceInputManager,
                sheetDetent: $expandedSheetDetent,
                onSubmit: { submitAnswers($0, surface: "expanded") },
                onIgnoreAll: { ignoreAll(surface: "expanded") }
            )
            .presentationDetents([.medium, .large], selection: $expandedSheetDetent)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
    }

    // MARK: - Question Page

    @ViewBuilder
    private func questionPageContent(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            questionText(question)

            // Full-width option rows matching the expanded ask surface.
            if !question.options.isEmpty {
                optionRows(for: question)
            }

            if let timeoutSummary {
                Label(timeoutSummary, systemImage: "timer")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .padding(.horizontal, 12)
            }

            // Multi-select done button
            if question.multiSelect,
               let selected = AskCardShared.multiSelectCount(for: question, answers: answers),
               selected > 0,
               !isLastQuestionPage {
                Button {
                    confirmMultiSelect(for: question)
                } label: {
                    Text("Done (\(selected) selected)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeBlue)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.themeBlue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }

            if responseFailed || submission.phase == .failed(request.id) {
                Text("Couldn't confirm response. Try again.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .padding(.horizontal, 12)
            }

            // Footer: type answer + ignore
            questionFooter(question)
        }
    }

    private func questionText(_ question: AskQuestion) -> some View {
        let display = Self.inlineQuestionDisplay(for: question.question)
        let summary = display.summary.isEmpty ? "Review this request." : display.summary
        let usesPreview = Self.usesInlineQuestionPreview(
            summary,
            dynamicTypeSize: dynamicTypeSize
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(summary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.themeFg)
                    .lineLimit(usesPreview ? Self.inlineQuestionLineLimit(for: dynamicTypeSize) : nil)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Question: \(summary)")

                expandButton
            }

            AskSelectionModePill(question: question)

            if let commandPreview = display.commandPreview {
                AskCommandPreview(command: commandPreview)
            }
        }
        .padding(.horizontal, 12)
    }

    private var expandButton: some View {
        Button {
            pageAdvance.invalidate()
            AppHaptics.toolbarExpansion()
            isExpanded = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.callout)
                .foregroundStyle(.themeComment)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Expand ask request")
        .accessibilityHint("Opens the complete question and details")
        .accessibilityIdentifier("ask.expand")
    }

    private struct AskCommandPreview: View {
        let command: String
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Command")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)

                Text(command)
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.bg.highlight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.text.tertiary.opacity(0.12), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Command preview")
            .accessibilityValue(command)
        }
    }

    private func optionRows(for question: AskQuestion) -> some View {
        VStack(spacing: 8) {
            ForEach(question.options, id: \.value) { option in
                optionRow(option, question: question)
            }
        }
        .padding(.horizontal, 12)
    }

    private func optionRow(_ option: AskOption, question: AskQuestion) -> some View {
        let isSelected = AskCardShared.isOptionSelected(option, in: question, answers: answers)

        return Button {
            AskCardShared.handleOptionTap(option, question: question, answers: $answers) {
                if isSingleQuestionSingleSelect {
                    pageAdvance.invalidate()
                    submitAnswers(answers, surface: "inline")
                } else if !isLastQuestionPage {
                    applyRequestIdentity(request, page: currentPage, invalidatePending: false)
                    pageAdvance.schedule(requestID: request.id, page: currentPage) {
                        withAnimation(ThemeMotion.easeInOut(duration: 0.25, reduceMotion: reduceMotion)) {
                            advanceToNextPage()
                        }
                    }
                }
            }
        } label: {
            AskOptionChoiceRow(
                option: option,
                isSelected: isSelected,
                isMultiSelect: question.multiSelect,
                density: .inline
            )
        }
        .buttonStyle(.plain)
        .disabled(isAskSubmitted)
        .accessibilityIdentifier("ask.option.\(option.value)")
    }

    private func questionFooter(_ question: AskQuestion) -> some View {
        HStack {
            Spacer()

            Button {
                handleIgnore(question: question)
            } label: {
                Text("\(Text(isLastQuestionPage ? "Ignore & Send" : "Ignore").foregroundStyle(.themeComment))\(Text(" \u{2192}").foregroundStyle(.themeComment.opacity(0.6)))")
                    .font(.caption)
                    .frame(
                        minWidth: Self.quietControlMinimumHitSize,
                        minHeight: Self.quietControlMinimumHitSize,
                        alignment: .trailing
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAskSubmitted)
            .accessibilityIdentifier(Self.ignoreAccessibilityIdentifier)

            if isLastQuestionPage {
                Button {
                    submitAnswers(answers, surface: "inline")
                } label: {
                    Text(responseFailed || submission.phase == .failed(request.id) ? "Retry" : "Send")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeOnBlue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.themeBlue, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isAskSubmitted)
                .accessibilityIdentifier("ask.send")
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Page Indicator

    private var timeoutSummary: String? {
        guard let timeout = request.timeout, timeout > 0 else { return nil }
        let seconds = max(1, (timeout + 999) / 1000)
        return "Expires in about \(seconds) seconds"
    }

    private var pageIndicator: some View {
        Group {
            if totalPages <= 4 {
                HStack(spacing: 8) {
                    ForEach(0..<totalPages, id: \.self) { index in
                        Button {
                            selectPage(index)
                        } label: {
                            Circle()
                                .fill(index == currentPage ? theme.accent.blue : theme.text.tertiary.opacity(0.3))
                                .frame(width: 6, height: 6)
                                .frame(
                                    width: Self.quietControlMinimumHitSize,
                                    height: Self.quietControlMinimumHitSize
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isAskSubmitted)
                        .accessibilityLabel("Question \(index + 1) of \(totalPages)")
                        .accessibilityIdentifier(Self.pageAccessibilityIdentifier(index))
                        .accessibilityAddTraits(index == currentPage ? [.isSelected] : [])
                    }
                }
            } else {
                Text("\(currentPage + 1) of \(totalPages)")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Selection Logic

    private func confirmMultiSelect(for question: AskQuestion) {
        AppHaptics.impact(style: .light)
        pageAdvance.invalidate()
        withAnimation(ThemeMotion.easeInOut(duration: 0.25, reduceMotion: reduceMotion)) {
            advanceToNextPage()
        }
    }

    private func handleIgnore(question: AskQuestion) {
        AppHaptics.impact(style: .soft)
        pageAdvance.invalidate()
        // Remove any existing answer — ignored = omitted from map
        answers[question.id] = nil

        if isSingleQuestionSingleSelect {
            // Single question ignored = ignore all
            ignoreAll(surface: "inline")
        } else if isLastQuestionPage {
            // Last question ignored — submit immediately with this answer omitted.
            submitAnswers(answers, surface: "inline")
        } else {
            withAnimation(ThemeMotion.easeInOut(duration: 0.25, reduceMotion: reduceMotion)) {
                advanceToNextPage()
            }
        }
    }

    private func selectPage(_ index: Int) {
        pageAdvance.invalidate()
        guard index != currentPage else { return }
        withAnimation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
            currentPage = index
        }
    }

    private func applyRequestIdentity(
        _ request: AskRequest,
        page: Int,
        invalidatePending: Bool
    ) {
        pageAdvance.noteIdentity(request: request, page: page)
        if invalidatePending {
            pageAdvance.invalidate()
        }
    }

    private func advanceToNextPage() {
        if currentPage < totalPages - 1 {
            currentPage += 1
        }
    }

    private func submitAnswers(_ submittedAnswers: [String: AskAnswer], surface: String) {
        guard !isAskSubmitted else { return }
        pageAdvance.invalidate()
        submission.submit(requestID: request.id) { complete in
            recordResponseMetric(outcome: submittedAnswers.isEmpty ? "empty" : "answered", surface: surface, submittedAnswers: submittedAnswers)
            onSubmit(submittedAnswers, complete)
            FeatureEducationTips.markPromptAnswered()
        }
    }

    private func ignoreAll(surface: String) {
        guard !isAskSubmitted else { return }
        pageAdvance.invalidate()
        submission.submit(requestID: request.id) { complete in
            recordResponseMetric(outcome: "ignored", surface: surface, submittedAnswers: [:])
            onIgnoreAll(complete)
            FeatureEducationTips.markPromptAnswered()
        }
    }

    private func recordResponseMetric(
        outcome: String,
        surface: String,
        submittedAnswers: [String: AskAnswer]
    ) {
        guard !didRecordResponseMetric else { return }
        didRecordResponseMetric = true

        let startedNs = presentedAtNs == 0 ? Self.timestampNs() : presentedAtNs
        let durationMs = Double((Self.timestampNs() &- startedNs) / 1_000_000)
        let tags = Self.responseMetricTags(
            request: request,
            answers: submittedAnswers,
            outcome: outcome,
            surface: surface
        )
        let sessionId = request.sessionId
        let workspaceId = request.workspaceId
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .askResponseMs,
                value: durationMs,
                unit: .ms,
                sessionId: sessionId,
                workspaceId: workspaceId,
                tags: tags
            )
        }
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

// MARK: - Page Count Helper (testable)

extension AskCard {
    static let quietControlMinimumHitSize: CGFloat = ComposerInputMetrics.controlDiameter
    static let ignoreAccessibilityIdentifier = "ask.ignore"

    static func pageAccessibilityIdentifier(_ page: Int) -> String {
        "ask.page.\(page)"
    }

    /// Compute total page count for a given request.
    /// Ask cards now use one page per question (no extra review page).
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

    static func inlineQuestionLineLimit(for size: DynamicTypeSize) -> Int {
        switch size {
        case .accessibility1, .accessibility2, .accessibility3,
             .accessibility4, .accessibility5:
            return 8
        default:
            return 6
        }
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
        dynamicTypeSize: DynamicTypeSize
    ) -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let nonEmptyLineCount = trimmed
            .split(whereSeparator: \.isNewline)
            .filter { !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count

        if nonEmptyLineCount > inlineQuestionLineLimit(for: dynamicTypeSize) {
            return true
        }

        let characterLimit = dynamicTypeSize.isAccessibilitySize ? 420 : 280
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
