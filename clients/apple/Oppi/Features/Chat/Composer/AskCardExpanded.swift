import SwiftUI
import UIKit

// MARK: - AskCardExpanded

/// Full-screen expanded view for ask questions.
///
/// Presents a vertical option list with full question text, descriptions,
/// and optional custom text input. Multi-question requests use page
/// navigation across questions only (no extra submit/review page).
///
/// All state is shared with the inline `AskCard` via bindings — collapsing
/// preserves answers and current page position.
struct AskCardExpanded: View {
    let request: AskRequest
    @Binding var currentPage: Int
    @Binding var answers: [String: AskAnswer]
    @Binding var isExpanded: Bool
    var voiceInputManager: VoiceInputManager? = nil
    let onSubmit: ([String: AskAnswer]) -> Void
    let onIgnoreAll: () -> Void

    @State private var customTexts: [String: String] = [:]
    @FocusState private var focusedQuestionId: String?
    @State private var navigatingForward: Bool = true

    /// Question currently receiving custom dictation text.
    @State private var dictationQuestionId: String?

    /// Custom text value before dictation started.
    @State private var dictationBaseText: String = ""

    /// Prefix used while streaming transcript updates (base + separator).
    @State private var dictationPrefixText: String = ""

    private let optionCornerRadius: CGFloat = 12

    private var isSingleQuestionSingleSelect: Bool {
        request.questions.count == 1 && !request.questions[0].multiSelect
    }

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
            navigationHeader

            Divider()
                .overlay(Color.themeComment.opacity(0.15))

            ZStack {
                ScrollView {
                    Group {
                        if let question = currentQuestion {
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
        .onChange(of: voiceInputManager?.currentTranscript) { _, newTranscript in
            guard let questionId = dictationQuestionId else { return }
            applyDictationTranscript(newTranscript ?? "", for: questionId)
        }
        .onDisappear {
            cancelDictationIfNeeded()
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
                Text("Question \(currentPage + 1) of \(request.questions.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.themeComment)
            }

            Spacer()

            Button {
                Task {
                    await finalizeDictationIfNeeded()
                    commitCustomTextIfNeeded()
                    focusedQuestionId = nil
                    isExpanded = false
                }
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

            if question.multiSelect,
               let count = AskCardShared.multiSelectCount(for: question, answers: answers),
               count > 0,
               !isLastQuestionPage {
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
        let isSelected = AskCardShared.isOptionSelected(option, in: question, answers: answers)

        return Button {
            cancelDictationIfNeeded(for: question.id)
            customTexts[question.id] = ""
            AskCardShared.handleOptionTap(option, question: question, answers: $answers) {
                if isSingleQuestionSingleSelect {
                    isExpanded = false
                    onSubmit(answers)
                }
            }
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

            HStack(alignment: .center, spacing: 8) {
                dictationButton(for: question)
                    .fixedSize()

                TextField("Type your answer...", text: customTextBinding(for: question.id), axis: .vertical)
                    .font(.body)
                    .foregroundStyle(.themeFg)
                    .focused($focusedQuestionId, equals: question.id)
                    .lineLimit(1...5)
                    .submitLabel(isSingleQuestionSingleSelect ? .send : .done)
                    .onSubmit {
                        Task {
                            await finalizeDictationIfNeeded()
                            commitCustomText(for: question)
                            focusedQuestionId = nil
                            if isSingleQuestionSingleSelect {
                                isExpanded = false
                                onSubmit(answers)
                            }
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 46)
            .background(Color.themeBgHighlight, in: RoundedRectangle(cornerRadius: optionCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: optionCornerRadius)
                    .stroke(Color.themeComment.opacity(0.12), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func dictationButton(for question: AskQuestion) -> some View {
        if ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager {
            let ownsActiveDictation = dictationQuestionId == question.id
            let isRecording = manager.isRecording && ownsActiveDictation
            let isPreparing = manager.isPreparing && ownsActiveDictation
            let isProcessing = manager.isProcessing && ownsActiveDictation
            let isBlockedByOtherInput = (manager.isRecording || manager.isPreparing) && !ownsActiveDictation
            let engineBadge = ComposerShared.micEngineBadge(for: manager)

            Button {
                Task {
                    await handleDictationTap(for: question, manager: manager)
                }
            } label: {
                MicButtonLabel(
                    isRecording: isRecording,
                    isProcessing: isPreparing || isProcessing,
                    audioLevel: manager.audioLevel,
                    languageLabel: manager.activeLanguageLabel,
                    accentColor: .themeBlue,
                    engineBadge: engineBadge,
                    diameter: 32
                )
            }
            .buttonStyle(.plain)
            .disabled(manager.isProcessing || isBlockedByOtherInput)
            .accessibilityIdentifier("ask.voiceInput")
            .accessibilityLabel(ComposerShared.accessibilityLabel(isRecording: isRecording, isPreparing: isPreparing))
            .accessibilityValue(ComposerShared.voiceRouteAccessibilityValue(for: manager))
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.themeComment.opacity(0.15))

            HStack {
                Button {
                    handleIgnore()
                } label: {
                    HStack(spacing: 4) {
                        Text(isLastQuestionPage ? "Ignore & Send" : "Ignore")
                            .font(.body)
                            .foregroundStyle(.themeComment)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.themeComment.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if isSingleQuestionSingleSelect {
                    // Single-question single-select: show Send when custom text is entered
                    if hasCustomTextForCurrentQuestion {
                        Button {
                            Task {
                                await finalizeDictationIfNeeded()
                                commitCustomTextIfNeeded()
                                isExpanded = false
                                onSubmit(answers)
                            }
                        } label: {
                            Text("Send")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(.themeBlue, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                } else if isLastQuestionPage {
                    Button {
                        Task {
                            await finalizeDictationIfNeeded()
                            commitCustomTextIfNeeded()
                            isExpanded = false
                            onSubmit(answers)
                        }
                    } label: {
                        Text("Send")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(.themeBlue, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        navigateForward()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Next")
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
        if dictationQuestionId != nil {
            Task {
                await finalizeDictationIfNeeded()
                navigateForwardWithoutDictation()
            }
        } else {
            navigateForwardWithoutDictation()
        }
    }

    private func navigateBack() {
        if dictationQuestionId != nil {
            Task {
                await finalizeDictationIfNeeded()
                navigateBackWithoutDictation()
            }
        } else {
            navigateBackWithoutDictation()
        }
    }

    private func navigateForwardWithoutDictation() {
        focusedQuestionId = nil
        commitCustomTextIfNeeded()
        navigatingForward = true
        withAnimation(.easeInOut(duration: 0.25)) {
            if currentPage < totalPages - 1 {
                currentPage += 1
            }
        }
    }

    private func navigateBackWithoutDictation() {
        focusedQuestionId = nil
        navigatingForward = false
        withAnimation(.easeInOut(duration: 0.25)) {
            if currentPage > 0 {
                currentPage -= 1
            }
        }
    }

    // MARK: - Selection Logic

    private func confirmMultiSelect() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !isLastQuestionPage {
            navigateForward()
        }
    }

    private func handleIgnore() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        if let question = currentQuestion {
            cancelDictationIfNeeded(for: question.id)
            answers[question.id] = nil
            customTexts[question.id] = ""
        }

        if isSingleQuestionSingleSelect {
            isExpanded = false
            onIgnoreAll()
        } else if isLastQuestionPage {
            Task {
                await finalizeDictationIfNeeded()
                commitCustomTextIfNeeded()
                isExpanded = false
                onSubmit(answers)
            }
        } else {
            navigateForward()
        }
    }

    /// True when the current question has non-empty custom text entered.
    private var hasCustomTextForCurrentQuestion: Bool {
        guard let question = currentQuestion else { return false }
        let text = (customTexts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
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

    // MARK: - Dictation

    private func handleDictationTap(for question: AskQuestion, manager: VoiceInputManager) async {
        switch manager.state {
        case .recording:
            guard dictationQuestionId == question.id else { return }
            await finalizeDictationIfNeeded()
        case .preparingModel:
            guard dictationQuestionId == question.id else { return }
            await finalizeDictationIfNeeded()
        case .idle:
            await startDictation(for: question, manager: manager)
        case .processing, .error:
            break
        }
    }

    private func startDictation(for question: AskQuestion, manager: VoiceInputManager) async {
        let base = customTexts[question.id] ?? ""
        dictationQuestionId = question.id
        dictationBaseText = base

        dictationPrefixText = Self.dictationPrefix(for: base)

        focusedQuestionId = question.id

        do {
            try await manager.startRecording(source: "ask_card_mic_tap")
        } catch {
            clearDictationState()
        }
    }

    private func applyDictationTranscript(_ transcript: String, for questionId: String) {
        guard dictationQuestionId == questionId else { return }

        let combinedText = Self.combinedDictationText(
            base: dictationBaseText,
            prefix: dictationPrefixText,
            transcript: transcript
        )
        customTexts[questionId] = combinedText

        let trimmed = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            answers[questionId] = .custom(trimmed)
        }
    }

    private func finalizeDictationIfNeeded() async {
        guard let manager = voiceInputManager, let questionId = dictationQuestionId else { return }
        defer { clearDictationState() }

        if manager.isRecording {
            let transcript = await manager.stopRecording()
            applyDictationTranscript(transcript, for: questionId)
        } else if manager.isPreparing {
            await manager.cancelRecording()
        }
    }

    private func cancelDictationIfNeeded(for questionId: String? = nil) {
        guard let manager = voiceInputManager, let activeQuestionId = dictationQuestionId else { return }

        if let questionId, activeQuestionId != questionId {
            return
        }

        clearDictationState()

        Task {
            if manager.isRecording || manager.isPreparing {
                await manager.cancelRecording()
            }
        }
    }

    private func clearDictationState() {
        dictationQuestionId = nil
        dictationBaseText = ""
        dictationPrefixText = ""
    }

    private func loadCustomTextsFromAnswers() {
        for (key, answer) in answers {
            if case .custom(let text) = answer {
                customTexts[key] = text
            }
        }
    }

}

extension AskCardExpanded {
    static func dictationPrefix(for base: String) -> String {
        if base.isEmpty || base.last?.isWhitespace == true {
            return base
        }
        return base + " "
    }

    static func combinedDictationText(base: String, prefix: String, transcript: String) -> String {
        guard !transcript.isEmpty else { return base }
        return prefix + transcript
    }
}
