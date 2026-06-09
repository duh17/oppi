import SwiftUI
import UIKit

// MARK: - Answer Model

/// An answer for a single question in an ask request.
enum AskAnswer: Equatable, Sendable {
    case single(String)
    case multi(Set<String>)
    case custom(String)
}

// MARK: - Response Encoding

/// Encodes collected answers into the wire format for `extension_ui_response`.
///
/// - Single-select: `{"questionId": "value"}`
/// - Multi-select: `{"questionId": ["a", "b"]}`
/// - Custom text: `{"questionId": "free text"}`
/// - Ignored questions: omitted from map
enum AskResponseEncoder {
    /// Encode answers to a JSON string. Questions without answers are omitted.
    static func encode(_ answers: [String: AskAnswer]) -> String {
        var result: [String: Any] = [:]
        for (key, answer) in answers {
            switch answer {
            case .single(let value):
                result[key] = value
            case .multi(let values):
                result[key] = Array(values).sorted()
            case .custom(let text):
                result[key] = text
            }
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.sortedKeys]
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Build answer map from raw answers dict.
    /// Returns nil values for questions that were not answered (ignored).
    static func answerMap(
        answers: [String: AskAnswer],
        questions: [AskQuestion]
    ) -> [(question: AskQuestion, answer: AskAnswer?)] {
        questions.map { q in
            (question: q, answer: answers[q.id])
        }
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
    let onSubmit: ([String: AskAnswer]) -> Void
    let onIgnoreAll: () -> Void
    var voiceInputManager: VoiceInputManager? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isExpanded: Bool = false
    @State private var expandedSheetDetent: PresentationDetent = .large

    private let cardCornerRadius: CGFloat = 14
    private let autoAdvanceDelay: Duration = .milliseconds(200)

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

    var body: some View {
        VStack(spacing: 0) {
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
        .padding(.vertical, 10)
        .background(Color.themeBgDark, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(Color.themeComment.opacity(0.15), lineWidth: 0.5)
        )
        // No client-side auto-dismiss. The ask card stays open until the user
        // responds or the session lifecycle clears it (agent_end, session_ended,
        // stop_confirmed). Server-side cleanup in agent_end cancels deferred SDK
        // promises so the agent never gets stuck waiting.
        // Announce page changes for VoiceOver
        .onChange(of: currentPage) {
            let text = Self.pageAnnouncementText(
                page: currentPage,
                questions: request.questions,
                isSingleQuestionSingleSelect: isSingleQuestionSingleSelect
            )
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        .sheet(isPresented: $isExpanded) {
            AskCardExpanded(
                request: request,
                currentPage: $currentPage,
                answers: $answers,
                isExpanded: $isExpanded,
                voiceInputManager: voiceInputManager,
                onSubmit: onSubmit,
                onIgnoreAll: onIgnoreAll
            )
            .presentationDetents([.medium, .large], selection: $expandedSheetDetent)
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.resizes)
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

            if let commandPreview = display.commandPreview {
                AskCommandPreview(command: commandPreview)
            }
        }
        .padding(.horizontal, 12)
    }

    private var expandButton: some View {
        Button {
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
            .background(Color.themeBgHighlight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.themeComment.opacity(0.12), lineWidth: 1)
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
                    onSubmit(answers)
                } else if !isLastQuestionPage {
                    Task {
                        try? await Task.sleep(for: autoAdvanceDelay)
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
        .accessibilityIdentifier("ask.option.\(option.value)")
    }

    private func questionFooter(_ question: AskQuestion) -> some View {
        HStack {
            Spacer()

            Button {
                handleIgnore(question: question)
            } label: {
                Text(isLastQuestionPage ? "Ignore & Send" : "Ignore")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                + Text(" \u{2192}")
                    .font(.caption)
                    .foregroundStyle(.themeComment.opacity(0.6))
            }
            .buttonStyle(.plain)

            if isLastQuestionPage {
                Button {
                    onSubmit(answers)
                } label: {
                    Text("Send")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeOnBlue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.themeBlue, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
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
                HStack(spacing: 5) {
                    ForEach(0..<totalPages, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Color.themeBlue : Color.themeComment.opacity(0.3))
                            .frame(width: 6, height: 6)
                            .onTapGesture {
                                withAnimation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
                                    currentPage = index
                                }
                            }
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(ThemeMotion.easeInOut(duration: 0.25, reduceMotion: reduceMotion)) {
            advanceToNextPage()
        }
    }

    private func handleIgnore(question: AskQuestion) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        // Remove any existing answer — ignored = omitted from map
        answers[question.id] = nil

        if isSingleQuestionSingleSelect {
            // Single question ignored = ignore all
            onIgnoreAll()
        } else if isLastQuestionPage {
            // Last question ignored — submit immediately with this answer omitted.
            onSubmit(answers)
        } else {
            withAnimation(ThemeMotion.easeInOut(duration: 0.25, reduceMotion: reduceMotion)) {
                advanceToNextPage()
            }
        }
    }

    private func advanceToNextPage() {
        if currentPage < totalPages - 1 {
            currentPage += 1
        }
    }
}

// MARK: - Page Count Helper (testable)

extension AskCard {
    /// Compute total page count for a given request.
    /// Ask cards now use one page per question (no extra review page).
    static func pageCount(for request: AskRequest) -> Int {
        max(1, request.questions.count)
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
