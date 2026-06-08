import SwiftUI
import UIKit

// MARK: - AskCardExpanded

/// Expanded sheet view for ask questions.
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
    @State private var focusedQuestionId: String?
    @State private var navigatingForward: Bool = true
    @State private var suppressKeyboard = false
    @State private var keyboardLanguage: String?
    @State private var focusRequestID = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .id(currentPage)
                .transition(ThemeMotion.directionalPage(forward: navigatingForward, reduceMotion: reduceMotion))
            }
            .clipped()
            .frame(maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footerBar
        }
        .background(Color.themeBg.ignoresSafeArea())
        .onAppear {
            loadCustomTextsFromAnswers()
        }
        .onChange(of: voiceInputManager?.transcriptPresentationRevision) { _, _ in
            guard let questionId = dictationQuestionId else { return }
            guard ComposerShared.ownsVoiceInput(voiceInputManager, owner: .askCard) else { return }
            applyDictationTranscript(voiceInputManager?.currentTranscript ?? "", for: questionId)
        }
        .onChange(of: keyboardLanguage) { _, newLanguage in
            guard ReleaseFeatures.voiceInputEnabled,
                  let manager = voiceInputManager,
                  AppPreferences.Keyboard.normalize(newLanguage) != nil else { return }
            Task {
                await manager.prewarm(
                    keyboardLanguage: newLanguage,
                    source: "ask_card_keyboard_change"
                )
            }
        }
        .onDisappear {
            suppressKeyboard = false
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
                    suppressKeyboard = false
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
            MarkdownContentViewWrapper(
                content: question.question,
                isStreaming: false,
                textSelectionEnabled: true
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

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
            suppressKeyboard = false
            focusedQuestionId = nil
            customTexts[question.id] = ""
            AskCardShared.handleOptionTap(option, question: question, answers: $answers) {
                if isSingleQuestionSingleSelect {
                    isExpanded = false
                    onSubmit(answers)
                }
            }
        } label: {
            AskOptionChoiceRow(
                option: option,
                isSelected: isSelected,
                isMultiSelect: question.multiSelect,
                density: .expanded
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

            HStack(alignment: .bottom, spacing: 8) {
                dictationButton(for: question)
                    .fixedSize()

                ZStack(alignment: .leading) {
                    if (customTexts[question.id] ?? "").isEmpty {
                        Text("Type your answer...")
                            .font(.body)
                            .foregroundStyle(.themeComment)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }

                    PastableTextView(
                        text: customTextBinding(for: question.id),
                        placeholder: "",
                        font: .preferredFont(forTextStyle: .body),
                        textColor: UIColor(Color.themeFg),
                        tintColor: UIColor(Color.themeBlue),
                        volatileSuffixLength: dictationQuestionId == question.id
                            ? ComposerShared.volatileSuffixLength(manager: voiceInputManager, owner: .askCard)
                            : 0,
                        correctionRanges: correctionRangesForDisplay(questionId: question.id),
                        maxLines: 5,
                        autocorrectionEnabled: true,
                        onPasteImages: { _ in },
                        onCommandEnter: {
                            Task {
                                await finalizeDictationIfNeeded()
                                commitCustomText(for: question)
                                focusedQuestionId = nil
                                if isSingleQuestionSingleSelect {
                                    suppressKeyboard = false
                                    isExpanded = false
                                    onSubmit(answers)
                                }
                            }
                        },
                        onAlternateEnter: nil,
                        onOverflowChange: nil,
                        onLineCountChange: nil,
                        onFocusChange: { isFocused in
                            focusedQuestionId = isFocused ? question.id : nil
                        },
                        onDictationStateChange: nil,
                        focusRequestID: focusRequestID,
                        blurRequestID: 0,
                        dictationRequestID: 0,
                        suppressKeyboard: suppressKeyboard,
                        allowKeyboardRestoreOnTap: true,
                        onKeyboardRestoreRequest: handleKeyboardRestoreRequest,
                        accessibilityIdentifier: "ask.input",
                        keyboardLanguage: $keyboardLanguage
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 46)
            .background(Color.themeBgHighlight, in: RoundedRectangle(cornerRadius: optionCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: optionCornerRadius)
                    .stroke(Color.themeComment.opacity(0.12), lineWidth: 1)
            )
            .id("ask-input-\(question.id)")
        }
    }

    @ViewBuilder
    private func dictationButton(for question: AskQuestion) -> some View {
        if ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager {
            let ownsActiveQuestion = dictationQuestionId == question.id
            let presentation = ownsActiveQuestion
                ? ComposerShared.micButtonPresentation(for: manager, owner: .askCard)
                : ComposerShared.blockedMicButtonPresentation(for: manager)

            Button {
                Task {
                    await handleDictationTap(for: question, manager: manager)
                }
            } label: {
                MicButtonLabel(
                    presentation: presentation,
                    accentColor: .themeBlue,
                    diameter: 32
                )
            }
            .buttonStyle(.plain)
            .disabled(!presentation.isEnabled)
            .accessibilityIdentifier("ask.voiceInput")
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue)
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
                                suppressKeyboard = false
                                isExpanded = false
                                onSubmit(answers)
                            }
                        } label: {
                            Text("Send")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.themeOnBlue)
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
                            suppressKeyboard = false
                            isExpanded = false
                            onSubmit(answers)
                        }
                    } label: {
                        Text("Send")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.themeOnBlue)
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
        suppressKeyboard = false
        focusedQuestionId = nil
        commitCustomTextIfNeeded()
        navigatingForward = true
        withAnimation(ThemeMotion.easeInOut(duration: 0.25, reduceMotion: reduceMotion)) {
            if currentPage < totalPages - 1 {
                currentPage += 1
            }
        }
    }

    private func navigateBackWithoutDictation() {
        suppressKeyboard = false
        focusedQuestionId = nil
        navigatingForward = false
        withAnimation(ThemeMotion.easeInOut(duration: 0.25, reduceMotion: reduceMotion)) {
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
            suppressKeyboard = false
            focusedQuestionId = nil
            answers[question.id] = nil
            customTexts[question.id] = ""
        }

        if isSingleQuestionSingleSelect {
            suppressKeyboard = false
            isExpanded = false
            onIgnoreAll()
        } else if isLastQuestionPage {
            Task {
                await finalizeDictationIfNeeded()
                commitCustomTextIfNeeded()
                suppressKeyboard = false
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

    private func correctionRangesForDisplay(questionId: String) -> [NSRange] {
        guard dictationQuestionId == questionId,
              let manager = voiceInputManager,
              ComposerShared.ownsVoiceInput(manager, owner: .askCard) else { return [] }
        let offset = (dictationPrefixText as NSString).length
        return manager.currentTranscriptCorrectionRanges.map { range in
            NSRange(location: range.location + offset, length: range.length)
        }
    }

    // MARK: - Dictation

    private func handleDictationTap(for question: AskQuestion, manager: VoiceInputManager) async {
        guard ComposerShared.canControlVoiceInput(manager, owner: .askCard) else { return }
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
        focusedQuestionId = question.id

        do {
            dictationPrefixText = try await ComposerShared.startVoiceInput(
                manager: manager,
                keyboardLanguage: keyboardLanguage,
                owner: .askCard,
                baseText: base,
                suppressKeyboard: $suppressKeyboard,
                focusRequestID: $focusRequestID
            )
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
        guard ComposerShared.ownsVoiceInput(manager, owner: .askCard) else { return }
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
            if ComposerShared.ownsVoiceInput(manager, owner: .askCard),
               manager.isRecording || manager.isPreparing {
                await manager.cancelRecording()
            }
        }
    }

    private func clearDictationState() {
        dictationQuestionId = nil
        dictationBaseText = ""
        dictationPrefixText = ""
    }

    private func handleKeyboardRestoreRequest() {
        suppressKeyboard = false
        guard dictationQuestionId != nil else { return }
        Task {
            await finalizeDictationIfNeeded()
        }
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
        ComposerShared.dictationPrefix(for: base)
    }

    static func combinedDictationText(base: String, prefix: String, transcript: String) -> String {
        guard !transcript.isEmpty else { return base }
        return prefix + transcript
    }
}
