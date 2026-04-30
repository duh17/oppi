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
/// No text is truncated — question text, option labels, and descriptions
/// all size to content. If inline height exceeds ~40% of screen, an expand
/// button appears which opens `AskCardExpanded` via `.fullScreenCover`.
struct AskCard: View {
    let request: AskRequest
    let onSubmit: ([String: AskAnswer]) -> Void
    let onIgnoreAll: () -> Void
    var voiceInputManager: VoiceInputManager? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentPage: Int = 0
    @State private var answers: [String: AskAnswer] = [:]
    @State private var isExpanded: Bool = false

    /// Scales option card width for accessibility Dynamic Type sizes.
    private var optionCardWidth: CGFloat {
        Self.optionCardWidth(for: dynamicTypeSize)
    }

    private let optionCornerRadius: CGFloat = 12
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
        .overlay(alignment: .topTrailing) {
            Button {
                isExpanded = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .fullScreenCover(isPresented: $isExpanded) {
            AskCardExpanded(
                request: request,
                currentPage: $currentPage,
                answers: $answers,
                isExpanded: $isExpanded,
                voiceInputManager: voiceInputManager,
                onSubmit: onSubmit,
                onIgnoreAll: onIgnoreAll
            )
        }
    }

    // MARK: - Question Page

    @ViewBuilder
    private func questionPageContent(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Question text — never truncated
            Text(question.question)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .accessibilityLabel("Question: \(question.question)")

            // Option cards — horizontal scroll
            optionStrip(for: question)

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

    private func optionStrip(for question: AskQuestion) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(question.options, id: \.value) { option in
                    optionCard(option, question: question)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func optionCard(_ option: AskOption, question: AskQuestion) -> some View {
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    if question.multiSelect {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.caption)
                            .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                    }

                    Text(option.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let description = option.description {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: optionCardWidth, alignment: .topLeading)
            .frame(minHeight: 56)
            .padding(10)
            .background(
                isSelected ? Color.themeBlue.opacity(0.15) : Color.themeBgHighlight,
                in: RoundedRectangle(cornerRadius: optionCornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: optionCornerRadius)
                    .stroke(
                        isSelected ? Color.themeBlue.opacity(0.5) : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
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

    /// Option card width scaled for Dynamic Type accessibility sizes.
    static func optionCardWidth(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .accessibility1, .accessibility2, .accessibility3,
             .accessibility4, .accessibility5:
            return 200
        case .xxxLarge, .xxLarge:
            return 160
        default:
            return 120
        }
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
