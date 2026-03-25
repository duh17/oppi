import SwiftUI
import UIKit

// MARK: - AskCardExpanded

/// Full-screen expanded view for ask questions.
///
/// Presents a vertical option list with full question text, descriptions,
/// and optional custom text input. Multi-question requests use page
/// navigation with a submit/review page at the end.
///
/// All state is shared with the inline `AskCard` via bindings — collapsing
/// preserves answers and current page position.
struct AskCardExpanded: View {
    let request: AskRequest
    @Binding var currentPage: Int
    @Binding var answers: [String: AskAnswer]
    @Binding var isExpanded: Bool
    let onSubmit: ([String: AskAnswer]) -> Void
    let onIgnoreAll: () -> Void

    @State private var customTexts: [String: String] = [:]
    @FocusState private var focusedQuestionId: String?
    @State private var navigatingForward: Bool = true

    private let optionCornerRadius: CGFloat = 12

    private var isSingleQuestionSingleSelect: Bool {
        request.questions.count == 1 && !request.questions[0].multiSelect
    }

    private var totalPages: Int {
        AskCard.pageCount(for: request)
    }

    private var isSubmitPage: Bool {
        !isSingleQuestionSingleSelect && currentPage == request.questions.count
    }

    private var currentQuestion: AskQuestion? {
        guard currentPage < request.questions.count else { return nil }
        return request.questions[currentPage]
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationHeader

            Divider()
                .overlay(Color.themeComment.opacity(0.15))

            ZStack {
                ScrollView {
                    Group {
                        if isSubmitPage {
                            submitPageContent
                        } else if let question = currentQuestion {
                            questionPageContent(question)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(currentPage)
                .transition(.asymmetric(
                    insertion: .move(edge: navigatingForward ? .trailing : .leading),
                    removal: .move(edge: navigatingForward ? .leading : .trailing)
                ))
            }
            .clipped()
            .frame(maxHeight: .infinity)

            footerBar
        }
        .background(Color.themeBg.ignoresSafeArea())
        .onAppear {
            loadCustomTextsFromAnswers()
        }
    }

    // MARK: - Navigation Header

    private var navigationHeader: some View {
        HStack {
            if !isSingleQuestionSingleSelect && currentPage > 0 {
                Button {
                    navigateBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.medium))
                        Text("Back")
                            .font(.body)
                    }
                    .foregroundStyle(.themeBlue)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 60, height: 1)
            }

            Spacer()

            if !isSingleQuestionSingleSelect {
                if isSubmitPage {
                    Text("Review")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.themeComment)
                } else {
                    Text("Question \(currentPage + 1) of \(request.questions.count)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.themeComment)
                }
            }

            Spacer()

            Button {
                isExpanded = false
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.body)
                    .foregroundStyle(.themeComment)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Question Page

    @ViewBuilder
    private func questionPageContent(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(question.question)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(question.options, id: \.value) { option in
                    expandedOptionCard(option, question: question)
                }
            }

            if question.multiSelect, let count = multiSelectCount(for: question), count > 0 {
                Button {
                    confirmMultiSelect()
                } label: {
                    Text("Done (\(count) selected)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeBlue)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(.themeBlue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }

            if request.allowCustom {
                customTextInput(for: question)
            }
        }
    }

    private func expandedOptionCard(_ option: AskOption, question: AskQuestion) -> some View {
        let isSelected = isOptionSelected(option, in: question)

        return Button {
            handleOptionTap(option, question: question)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                if question.multiSelect {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.body)
                        .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .fixedSize(horizontal: false, vertical: true)

                    if let description = option.description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                if !question.multiSelect && isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeBlue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
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

    @ViewBuilder
    private func customTextInput(for question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or type your answer")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeComment)

            TextField("Type your answer...", text: customTextBinding(for: question.id), axis: .vertical)
                .font(.body)
                .foregroundStyle(.themeFg)
                .padding(12)
                .background(Color.themeBgHighlight, in: RoundedRectangle(cornerRadius: optionCornerRadius))
                .focused($focusedQuestionId, equals: question.id)
                .lineLimit(1...5)
                .submitLabel(.done)
                .onSubmit {
                    commitCustomText(for: question)
                    focusedQuestionId = nil
                }
        }
    }

    // MARK: - Submit Page

    private var submitPageContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Answers")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.themeFg)

            let entries = AskResponseEncoder.answerMap(answers: answers, questions: request.questions)

            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 10) {
                        if entry.answer != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.themeBlue)
                        } else {
                            Image(systemName: "minus.circle")
                                .font(.body)
                                .foregroundStyle(.themeComment)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.question.question)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.themeFg)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(answerDisplayText(entry.answer))
                                .font(.subheadline)
                                .foregroundStyle(entry.answer != nil ? .themeFg : .themeComment)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if index < entries.count - 1 {
                        Divider()
                            .overlay(Color.themeComment.opacity(0.1))
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.themeComment.opacity(0.15))

            HStack {
                if isSubmitPage {
                    Button {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        onIgnoreAll()
                    } label: {
                        Text("Ignore All")
                            .font(.body)
                            .foregroundStyle(.themeComment)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        handleIgnore()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Ignore")
                                .font(.body)
                                .foregroundStyle(.themeComment)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.themeComment.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if isSubmitPage {
                    Button {
                        onSubmit(answers)
                    } label: {
                        Text("Submit")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(.themeBlue, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                } else if !isSingleQuestionSingleSelect {
                    Button {
                        navigateForward()
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentPage == request.questions.count - 1 ? "Review" : "Next")
                                .font(.body.weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.themeBlue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Color.themeBg)
    }

    // MARK: - Navigation

    private func navigateForward() {
        focusedQuestionId = nil
        commitCustomTextIfNeeded()
        navigatingForward = true
        withAnimation(.easeInOut(duration: 0.25)) {
            if currentPage < totalPages - 1 {
                currentPage += 1
            }
        }
    }

    private func navigateBack() {
        focusedQuestionId = nil
        navigatingForward = false
        withAnimation(.easeInOut(duration: 0.25)) {
            if currentPage > 0 {
                currentPage -= 1
            }
        }
    }

    // MARK: - Selection Logic

    private func isOptionSelected(_ option: AskOption, in question: AskQuestion) -> Bool {
        guard let answer = answers[question.id] else { return false }
        switch answer {
        case .single(let value):
            return value == option.value
        case .multi(let values):
            return values.contains(option.value)
        case .custom:
            return false
        }
    }

    private func multiSelectCount(for question: AskQuestion) -> Int? {
        guard case .multi(let values) = answers[question.id] else { return nil }
        return values.count
    }

    private func handleOptionTap(_ option: AskOption, question: AskQuestion) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        customTexts[question.id] = ""

        if question.multiSelect {
            var current: Set<String>
            if case .multi(let existing) = answers[question.id] {
                current = existing
            } else {
                current = []
            }

            if current.contains(option.value) {
                current.remove(option.value)
            } else {
                current.insert(option.value)
            }
            answers[question.id] = current.isEmpty ? nil : .multi(current)
        } else {
            answers[question.id] = .single(option.value)

            if isSingleQuestionSingleSelect {
                onSubmit(answers)
            }
        }
    }

    private func confirmMultiSelect() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        navigateForward()
    }

    private func handleIgnore() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        if let question = currentQuestion {
            answers[question.id] = nil
            customTexts[question.id] = ""
        }

        if isSingleQuestionSingleSelect {
            onIgnoreAll()
        } else {
            navigateForward()
        }
    }

    // MARK: - Custom Text

    private func customTextBinding(for questionId: String) -> Binding<String> {
        Binding(
            get: { customTexts[questionId] ?? "" },
            set: { newValue in
                customTexts[questionId] = newValue
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    answers[questionId] = .custom(trimmed)
                }
            }
        )
    }

    private func commitCustomText(for question: AskQuestion) {
        let text = (customTexts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            answers[question.id] = .custom(text)
        }
    }

    private func commitCustomTextIfNeeded() {
        if let question = currentQuestion {
            commitCustomText(for: question)
        }
    }

    private func loadCustomTextsFromAnswers() {
        for (key, answer) in answers {
            if case .custom(let text) = answer {
                customTexts[key] = text
            }
        }
    }

    // MARK: - Display Helpers

    private func answerDisplayText(_ answer: AskAnswer?) -> String {
        guard let answer else { return "(not answered)" }
        switch answer {
        case .single(let value):
            return value
        case .multi(let values):
            return Array(values).sorted().joined(separator: ", ")
        case .custom(let text):
            return "\"\(text)\""
        }
    }
}
