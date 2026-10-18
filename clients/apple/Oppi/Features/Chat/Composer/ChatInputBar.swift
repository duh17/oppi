import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ChatInputPrimaryActionKind: Equatable {
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

/// Action-row pills the composer owns. Hosts pass data and callbacks, never views.
struct ComposerActionRow {
    var leading: [ComposerAction] = []
    var trailing: [ComposerAction] = []
    var leadingScrolls = false
}

struct ComposerAction: Identifiable {
    enum Icon {
        case image(UIImage)
        case symbol(String)
        case monogram(String)
    }

    enum Chrome {
        case toolbar
        case chip
        case cancel
    }

    final class Handler {
        let run: () -> Void
        init(_ run: @escaping () -> Void) {
            self.run = run
        }
    }

    enum Kind {
        case tap(Handler)
        case menu(UIMenu)
        case picker(ComposerActionPopover)
    }

    let id: String
    var icon: Icon?
    var title: String
    var tint: UIColor?
    var accessibilityLabel: String
    var accessibilityValue: String?
    var showsChevron = true
    var chrome: Chrome = .toolbar
    var kind: Kind
}

struct ComposerActionPopover {
    var preferredWidth: CGFloat = 220
    var make: @MainActor () -> UIViewController
    var update: (@MainActor (UIViewController) -> Void)?
}

struct ComposerOptionRow {
    var id: String
    var title: String
    var subtitle: String?
    var icon: UIImage?
    var isSelected: Bool
    var accessibilityIdentifier: String
    var accessibilityLabel: String?
}

/// Chat input bar with full-width composer and action row.
///
/// UIKit owns the bar. SwiftUI hosts embed it through one representable seam.
/// Ask card content stays SwiftUI until its own conversion and is hosted with
/// `HostFactory.content`.
///
/// **Layout**:
/// ```
/// ┌──────────────────────────────────────┐
/// │ [image strip]                        │
/// │ text input area…            [⬆/×/■] │
/// └──────────────────────────────────────┘
/// [+]  [action row content…]
/// ```
struct ChatInputBar: View {
    @Binding var text: String
    @Binding var textBeforeRecording: String?
    @Binding var pendingAttachments: [PendingAttachment]
    @Binding var pendingRepoPointers: [PendingFileReference]

    let isBusy: Bool
    @Binding var busyStreamingBehavior: StreamingBehavior
    let isSending: Bool
    var pendingReviewCommentCount: Int = 0
    var placeholderOverride: String? = nil
    var allowsEmptySubmit = false
    let sendProgressText: String?
    let isStopping: Bool
    var voiceInputManager: VoiceInputManager?
    var onPrepareVoiceInput: ((VoiceInputManager) async throws -> Void)? = nil
    let showForceStop: Bool
    let isForceStopInFlight: Bool
    var askRequest: AskRequest?
    var onAskSubmit: ((AskRequest, [String: AskAnswer], @escaping AskResponseSubmission.Completion) -> Void)?
    var onAskIgnoreAll: ((AskRequest, @escaping AskResponseSubmission.Completion) -> Void)?
    var autoAdvanceController: AskInlineAutoAdvanceController? = nil

    let slashCommands: [SlashCommand]
    let fileSuggestions: [FileSuggestion]
    let onFileSuggestionQuery: ((String?) -> Void)?
    let onSend: () -> Void
    let onStop: () -> Void
    let onForceStop: () -> Void
    let onExpand: () -> Void
    let externalFocusRequestID: Int
    var externalDictationRequestID: Int = 0
    var externalDictationOwner: ComposerShared.VoiceInputOwner = .inboxComposer
    var onExternalDictationHandled: ((_ requestID: Int) -> Void)? = nil
    let appliesOuterPadding: Bool
    var alwaysShowActionRow: Bool = false
    var allowsExpansion: Bool = true
    var allowsAttachments: Bool = true
    var attachmentButtonPlacement: HorizontalEdge = .leading
    var actionRowMinimumHeight: CGFloat = 0
    var showsAccessoryRow: Bool = true
    var autocorrectionEnabled: Bool = true
    var inputAccessibilityIdentifier: String = "chat.input"
    var sendAccessibilityIdentifier: String = "chat.send"
    var actionRow: ComposerActionRow = .init()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @Environment(\.themeID) private var themeID
    @Environment(\.composerDraftStore) private var composerDraftStore
    @Environment(\.composerMediaImportGate) private var mediaImportGate
    @State private var askHeight: CGFloat = 0
    /// Bumped when a hosted slot (Ask card, busy-mode tip) changes height
    /// outside a SwiftUI update, so SwiftUI measures the bar again.
    @State private var slotHeightRevision = 0
    @State private var suppressKeyboard = false
    @State private var focusRequestID = 0
    @State private var keyboardLanguage: String?
    @State private var voiceInputStartError: String?
    @State private var isInputFocused = false

    var body: some View {
        VStack(spacing: 8) {
            ComposerShared.captureFailureNotice(
                manager: voiceInputManager,
                owner: .inlineComposer
            ) {
                Button("Retry dictation") {
                    Task { await startOwnedVoiceInput(owner: .inlineComposer) }
                }
            }
            ChatInputBarHost(
                text: $text,
                textBeforeRecording: $textBeforeRecording,
                pendingAttachments: $pendingAttachments,
                pendingRepoPointers: $pendingRepoPointers,
                isBusy: isBusy,
                busyStreamingBehavior: $busyStreamingBehavior,
                isSending: isSending,
                pendingReviewCommentCount: pendingReviewCommentCount,
                placeholderOverride: placeholderOverride,
                allowsEmptySubmit: allowsEmptySubmit,
                sendProgressText: sendProgressText,
                isStopping: isStopping,
                voiceInputManager: voiceInputManager,
                onPrepareVoiceInput: onPrepareVoiceInput,
                showForceStop: showForceStop,
                isForceStopInFlight: isForceStopInFlight,
                askRequest: askRequest,
                onAskSubmit: onAskSubmit,
                onAskIgnoreAll: onAskIgnoreAll,
                autoAdvanceController: autoAdvanceController,
                slashCommands: slashCommands,
                fileSuggestions: fileSuggestions,
                onFileSuggestionQuery: onFileSuggestionQuery,
                onSend: onSend,
                onStop: onStop,
                onForceStop: onForceStop,
                onExpand: onExpand,
                appliesOuterPadding: appliesOuterPadding,
                alwaysShowActionRow: alwaysShowActionRow,
                allowsExpansion: allowsExpansion,
                allowsAttachments: allowsAttachments,
                attachmentButtonPlacement: attachmentButtonPlacement == .trailing ? .trailing : .leading,
                actionRowMinimumHeight: actionRowMinimumHeight,
                showsAccessoryRow: showsAccessoryRow,
                autocorrectionEnabled: autocorrectionEnabled,
                inputAccessibilityIdentifier: inputAccessibilityIdentifier,
                sendAccessibilityIdentifier: sendAccessibilityIdentifier,
                actionRow: actionRow,
                palette: themeID.palette,
                reduceMotion: reduceMotion,
                composerDraftStore: composerDraftStore,
                mediaImportGate: mediaImportGate,
                askHeight: $askHeight,
                slotHeightRevision: $slotHeightRevision,
                suppressKeyboard: $suppressKeyboard,
                focusRequestID: $focusRequestID,
                keyboardLanguage: $keyboardLanguage,
                reportsInputFocused: $isInputFocused
            )
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("chat.keyboard.dismiss")
                .accessibilityLabel("Dismiss keyboard")
            }
        }
        .onChange(of: text) { _, newValue in
            ComposerShared.notifyFileSuggestionContext(
                for: newValue,
                isBusy: isBusy,
                onFileSuggestionQuery: onFileSuggestionQuery
            )
        }
        .onChange(of: externalFocusRequestID) { _, _ in
            suppressKeyboard = false
            focusRequestID += 1
        }
        .task(id: externalDictationRequestID) {
            await startExternalDictationIfRequested()
        }
        .onChange(of: voiceInputManager?.currentComposerCaptureFailure, initial: true) { _, _ in
            ComposerShared.discardFailedTake(
                manager: voiceInputManager, owner: .inlineComposer,
                text: $text, textBeforeRecording: $textBeforeRecording, suppressKeyboard: $suppressKeyboard
            )
        }
        .onChange(of: voiceInputManager?.state) { _, _ in
            if ComposerShared.shouldSuppressKeyboardForActiveVoiceInput(
                voiceInputManager,
                owner: .inlineComposer
            ) {
                suppressKeyboard = true
            }
        }
        .onChange(of: voiceInputManager?.transcriptPresentationRevision) { _, _ in
            guard let prefix = textBeforeRecording, let manager = voiceInputManager else { return }
            guard ComposerShared.ownsVoiceInput(manager, owner: .inlineComposer) else { return }
            text = prefix + manager.currentTranscript
        }
        .alert("Couldn't Start Dictation", isPresented: Binding(
            get: { voiceInputStartError != nil },
            set: { if !$0 { voiceInputStartError = nil } }
        )) {
            Button("OK", role: .cancel) { voiceInputStartError = nil }
        } message: {
            Text(voiceInputStartError ?? "Please try again.")
        }
    }

    private func startExternalDictationIfRequested() async {
        let requestID = externalDictationRequestID
        guard requestID > 0 else { return }
        defer { onExternalDictationHandled?(requestID) }
        guard let manager = voiceInputManager else { return }
        guard ComposerShared.canControlVoiceInput(manager, owner: externalDictationOwner) else { return }
        guard ComposerShared.micTapAction(for: manager.state) == .start else { return }
        await startOwnedVoiceInput(owner: externalDictationOwner)
    }

    private func startOwnedVoiceInput(owner: ComposerShared.VoiceInputOwner) async {
        guard let manager = voiceInputManager else { return }
        guard ComposerShared.canControlVoiceInput(manager, owner: owner) else { return }
        do {
            try await ComposerShared.startVoiceInput(
                manager: manager,
                keyboardLanguage: keyboardLanguage,
                owner: owner,
                baseText: text,
                text: $text,
                textBeforeRecording: $textBeforeRecording,
                suppressKeyboard: $suppressKeyboard,
                focusRequestID: $focusRequestID,
                prepare: {
                    try await onPrepareVoiceInput?(manager)
                }
            )
        } catch is CancellationError {
        } catch {
            voiceInputStartError = error.localizedDescription
        }
    }

    static func askComposerTextFieldBinding(
        text: Binding<String>,
        clearing: Binding<AskComposerClearingState>,
        displayText: @escaping () -> String
    ) -> Binding<String> {
        let field = ComposerShared.textFieldBinding(text: text, displayText: displayText)
        return Binding(
            get: { field.wrappedValue },
            set: {
                clearing.wrappedValue.textRevision &+= 1
                field.wrappedValue = $0
            }
        )
    }

    @discardableResult
    static func restoreFailedAskComposerText(
        text: Binding<String>,
        clearing: AskComposerClearingState,
        submittedTextRevision: UInt64,
        request: AskRequest?,
        activeQuestionID: String?
    ) -> Bool {
        guard clearing.textRevision == submittedTextRevision, text.wrappedValue.isEmpty else { return false }
        guard let restored = composerTextForActiveAskQuestion(
            request: request,
            activeQuestionID: activeQuestionID,
            draftAnswers: clearing.draftAnswers,
            keepComposerClearedForSubmittedRequestID: clearing.submittedRequestID
        ) else { return false }
        text.wrappedValue = restored
        return true
    }

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
    ) -> ChatInputPrimaryActionKind {
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

// MARK: - Representable seam

private struct ChatInputBarHost: UIViewControllerRepresentable {
    @Binding var text: String
    @Binding var textBeforeRecording: String?
    @Binding var pendingAttachments: [PendingAttachment]
    @Binding var pendingRepoPointers: [PendingFileReference]
    var isBusy: Bool
    @Binding var busyStreamingBehavior: StreamingBehavior
    var isSending: Bool
    var pendingReviewCommentCount: Int
    var placeholderOverride: String?
    var allowsEmptySubmit: Bool
    var sendProgressText: String?
    var isStopping: Bool
    var voiceInputManager: VoiceInputManager?
    var onPrepareVoiceInput: ((VoiceInputManager) async throws -> Void)?
    var showForceStop: Bool
    var isForceStopInFlight: Bool
    var askRequest: AskRequest?
    var onAskSubmit: ((AskRequest, [String: AskAnswer], @escaping AskResponseSubmission.Completion) -> Void)?
    var onAskIgnoreAll: ((AskRequest, @escaping AskResponseSubmission.Completion) -> Void)?
    var autoAdvanceController: AskInlineAutoAdvanceController?
    var slashCommands: [SlashCommand]
    var fileSuggestions: [FileSuggestion]
    var onFileSuggestionQuery: ((String?) -> Void)?
    var onSend: () -> Void
    var onStop: () -> Void
    var onForceStop: () -> Void
    var onExpand: () -> Void
    var appliesOuterPadding: Bool
    var alwaysShowActionRow: Bool
    var allowsExpansion: Bool
    var allowsAttachments: Bool
    var attachmentButtonPlacement: ComposerAttachmentButtonPlacement
    var actionRowMinimumHeight: CGFloat
    var showsAccessoryRow: Bool
    var autocorrectionEnabled: Bool
    var inputAccessibilityIdentifier: String
    var sendAccessibilityIdentifier: String
    var actionRow: ComposerActionRow
    var palette: ThemePalette
    var reduceMotion: Bool
    var composerDraftStore: ComposerDraftStore?
    var mediaImportGate: ComposerMediaImportGate?
    @Binding var askHeight: CGFloat
    @Binding var slotHeightRevision: Int
    @Binding var suppressKeyboard: Bool
    @Binding var focusRequestID: Int
    @Binding var keyboardLanguage: String?
    @Binding var reportsInputFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> ComposerBarController {
        let controller = ComposerBarController()
        context.coordinator.controller = controller
        controller.host = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: ComposerBarController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.controller = controller
        controller.host = context.coordinator
        controller.apply()
        context.coordinator.scheduleSlots()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController controller: ComposerBarController,
        context: Context
    ) -> CGSize? {
        _ = slotHeightRevision
        let proposed = proposal.width ?? 0
        let fallback = controller.view.bounds.width
        let safeWidth: CGFloat
        if proposed.isFinite, proposed >= 280, proposed < 10_000 {
            safeWidth = proposed
        } else if fallback.isFinite, fallback >= 280, fallback < 10_000 {
            safeWidth = fallback
        } else {
            safeWidth = 390
        }
        return controller.sizeThatFits(width: safeWidth)
    }

    @MainActor
    final class Coordinator: ComposerBarHosting {
        var parent: ChatInputBarHost
        weak var controller: ComposerBarController?
        private var askHost: HostedContentController?
        private var tipHost: HostedContentController?
        private var slotRefreshScheduled = false

        init(parent: ChatInputBarHost) {
            self.parent = parent
        }

        var content: ComposerBarContent {
            ComposerBarContent(
                text: parent.text,
                textBeforeRecording: parent.textBeforeRecording,
                pendingAttachments: parent.pendingAttachments,
                pendingRepoPointers: parent.pendingRepoPointers,
                isBusy: parent.isBusy,
                busyStreamingBehavior: parent.busyStreamingBehavior,
                isSending: parent.isSending,
                pendingReviewCommentCount: parent.pendingReviewCommentCount,
                placeholderOverride: parent.placeholderOverride,
                allowsEmptySubmit: parent.allowsEmptySubmit,
                sendProgressText: parent.sendProgressText,
                isStopping: parent.isStopping,
                voiceInputManager: parent.voiceInputManager,
                showForceStop: parent.showForceStop,
                isForceStopInFlight: parent.isForceStopInFlight,
                askRequest: parent.askRequest,
                slashCommands: parent.slashCommands,
                fileSuggestions: parent.fileSuggestions,
                appliesOuterPadding: parent.appliesOuterPadding,
                alwaysShowActionRow: parent.alwaysShowActionRow,
                allowsExpansion: parent.allowsExpansion,
                allowsAttachments: parent.allowsAttachments,
                attachmentButtonPlacement: parent.attachmentButtonPlacement,
                actionRowMinimumHeight: parent.actionRowMinimumHeight,
                showsAccessoryRow: parent.showsAccessoryRow,
                autocorrectionEnabled: parent.autocorrectionEnabled,
                inputAccessibilityIdentifier: parent.inputAccessibilityIdentifier,
                sendAccessibilityIdentifier: parent.sendAccessibilityIdentifier,
                actionRow: parent.actionRow,
                colors: ComposerThemeColors(palette: parent.palette),
                reduceMotion: parent.reduceMotion,
                suppressKeyboard: parent.suppressKeyboard,
                focusRequestID: parent.focusRequestID,
                keyboardLanguage: parent.keyboardLanguage,
                askHeight: parent.askHeight,
                keyStripHeight: 0,
                mediaImportEpoch: parent.mediaImportGate?.epoch ?? 0
            )
        }

        func setText(_ text: String) { parent.text = text }
        func setTextBeforeRecording(_ value: String?) { parent.textBeforeRecording = value }
        func setPendingAttachments(_ value: [PendingAttachment]) { parent.pendingAttachments = value }
        func setPendingRepoPointers(_ value: [PendingFileReference]) { parent.pendingRepoPointers = value }
        func setBusyStreamingBehavior(_ value: StreamingBehavior) { parent.busyStreamingBehavior = value }
        func setSuppressKeyboard(_ value: Bool) { parent.suppressKeyboard = value }
        func consumeFocusRequest() { parent.focusRequestID = 0 }
        func setKeyboardLanguage(_ value: String?) { parent.keyboardLanguage = value }
        func setInputFocused(_ value: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.reportsInputFocused != value else { return }
                self.parent.reportsInputFocused = value
            }
        }
        func performSend() { parent.onSend() }
        func performStop() { parent.onStop() }
        func performForceStop() { parent.onForceStop() }
        func performExpand() { parent.onExpand() }
        func submitAsk(
            _ request: AskRequest,
            answers: [String: AskAnswer],
            completion: @escaping AskResponseSubmission.Completion
        ) {
            parent.onAskSubmit?(request, answers, completion)
        }
        func ignoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion) {
            parent.onAskIgnoreAll?(request, completion)
        }
        func startVoice(
            keyboardLanguage: String?,
            owner: ComposerShared.VoiceInputOwner,
            baseText: String
        ) async throws {
            guard let manager = parent.voiceInputManager else { return }
            try await ComposerShared.startVoiceInput(
                manager: manager,
                keyboardLanguage: keyboardLanguage,
                owner: owner,
                baseText: baseText,
                text: parent.$text,
                textBeforeRecording: parent.$textBeforeRecording,
                suppressKeyboard: parent.$suppressKeyboard,
                focusRequestID: parent.$focusRequestID,
                prepare: {
                    try await self.parent.onPrepareVoiceInput?(manager)
                }
            )
        }
        func stopVoice() async {
            guard let manager = parent.voiceInputManager else { return }
            await ComposerShared.stopVoiceInput(
                manager: manager,
                text: parent.$text,
                textBeforeRecording: parent.$textBeforeRecording
            )
        }
        func cancelVoice() async {
            guard let manager = parent.voiceInputManager else { return }
            await ComposerShared.cancelVoiceInput(
                manager: manager,
                textBeforeRecording: parent.$textBeforeRecording,
                suppressKeyboard: parent.$suppressKeyboard
            )
        }
        func finishVoiceBeforeSubmit() async {
            guard let manager = parent.voiceInputManager else { return }
            await ComposerShared.finishOwnedVoiceInputBeforeSubmit(
                manager: manager,
                owner: .inlineComposer,
                text: parent.$text,
                textBeforeRecording: parent.$textBeforeRecording,
                suppressKeyboard: parent.$suppressKeyboard,
                restoreKeyboard: false
            )
        }
        func handlePastedImages(_ images: [UIImage]) {
            ComposerShared.handlePastedImages(images, into: parent.$pendingAttachments)
        }
        func insertSlashCommand(_ command: SlashCommand) {
            ComposerShared.insertSlashCommand(command, into: parent.$text)
        }
        func insertFileSuggestion(_ suggestion: FileSuggestion) {
            ComposerShared.insertFileSuggestion(
                suggestion,
                text: parent.$text,
                pendingRepoPointers: parent.$pendingRepoPointers
            )
        }
        func removeAttachment(id: String) {
            ComposerShared.removeAttachment(id, from: parent.$pendingAttachments)
        }
        func removeRepoPointer(id: String) {
            ComposerShared.removeFile(id, from: parent.$pendingRepoPointers)
        }
        func importPhotoProviders(
            _ providers: [NSItemProvider],
            capturedGate: UInt64,
            capturedLocal: UInt64,
            currentLocal: @escaping () -> UInt64,
            onFailure: @escaping (String) -> Void
        ) {
            let gate = capturedGate
            ComposerShared.importPhotoLibraryProviders(
                providers,
                into: parent.$pendingAttachments,
                store: parent.composerDraftStore,
                shouldAccept: {
                    (self.parent.mediaImportGate?.isCurrent(gate) ?? true)
                        && capturedLocal == currentLocal()
                },
                onFailure: { message in
                    Task { @MainActor in
                        onFailure(message)
                    }
                }
            )
        }
        func addCapturedImage(_ image: UIImage) {
            ComposerShared.addCapturedImage(image, to: parent.$pendingAttachments)
        }
        func applyCanvas(
            attachment: PendingAttachment,
            recognizedText: String,
            replacingAttachmentID: String?
        ) -> Bool {
            ComposerShared.applyCanvasToComposer(
                attachment: attachment,
                recognizedText: recognizedText,
                text: parent.$text,
                pendingAttachments: parent.$pendingAttachments,
                replacingAttachmentID: replacingAttachmentID
            )
        }
        func loadSelectedFiles(
            _ result: Result<[URL], Error>,
            capturedGate: UInt64,
            capturedLocal: UInt64,
            currentLocal: @escaping () -> UInt64,
            onFailure: @escaping (String) -> Void
        ) {
            ComposerShared.loadSelectedFiles(
                result,
                into: parent.$pendingAttachments,
                store: parent.composerDraftStore,
                shouldAccept: {
                    (self.parent.mediaImportGate?.isCurrent(capturedGate) ?? true)
                        && capturedLocal == currentLocal()
                },
                onFailure: { message in
                    Task { @MainActor in
                        onFailure(message)
                    }
                }
            )
        }
        func notifyFileSuggestionContext(for text: String) {
            ComposerShared.notifyFileSuggestionContext(
                for: text,
                isBusy: parent.isBusy,
                onFileSuggestionQuery: parent.onFileSuggestionQuery
            )
        }
        func discardFailedVoiceTake() {
            ComposerShared.discardFailedTake(
                manager: parent.voiceInputManager,
                owner: .inlineComposer,
                text: parent.$text,
                textBeforeRecording: parent.$textBeforeRecording,
                suppressKeyboard: parent.$suppressKeyboard
            )
        }
        func restoreKeyboardFromSuppression() {
            ComposerShared.handleKeyboardRestore(
                suppressKeyboard: parent.$suppressKeyboard,
                textBeforeRecording: parent.$textBeforeRecording,
                voiceInputManager: parent.voiceInputManager,
                expectedOwner: .inlineComposer
            )
        }

        func scheduleSlots() {
            guard !slotRefreshScheduled else { return }
            slotRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.slotRefreshScheduled = false
                self?.updateAsk()
                self?.updateTip()
            }
        }

        private func updateAsk() {
            guard let controller else { return }
            guard let request = parent.askRequest else {
                controller.installAsk(nil)
                controller.setAskHeight(0)
                return
            }
            guard let root = HostFactory.root(near: controller) else { return }
            let card = askCard(request: request)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { [weak self] height in
                    DispatchQueue.main.async {
                        self?.commitAskHeight(height)
                    }
                }
            if let askHost {
                askHost.setContent(card)
                askHost.view.backgroundColor = .clear
                controller.installAsk(askHost)
            } else {
                let hosted = HostFactory.content(card, root: root)
                hosted.sizingOptions = []
                hosted.view.backgroundColor = .clear
                askHost = hosted
                controller.installAsk(hosted)
            }
        }

        private func commitAskHeight(_ height: CGFloat) {
            let next = max(height, 0)
            if abs(parent.askHeight - next) > 0.5 {
                parent.askHeight = next
                parent.slotHeightRevision += 1
            }
            controller?.setAskHeight(next)
            controller?.view.invalidateIntrinsicContentSize()
        }

        private func commitTipHeight(_ height: CGFloat) {
            guard controller?.setBusyTipHeight(height) == true else { return }
            parent.slotHeightRevision += 1
            controller?.view.invalidateIntrinsicContentSize()
        }

        private func askCard(request: AskRequest) -> AskCard {
            AskCard(
                request: request,
                currentPage: Binding(
                    get: { self.controller?.askCurrentPage ?? 0 },
                    set: {
                        self.controller?.askCurrentPage = $0
                        self.updateAsk()
                    }
                ),
                answers: Binding(
                    get: { self.controller?.askDraftAnswers ?? [:] },
                    set: {
                        self.controller?.askDraftAnswers = $0
                        self.updateAsk()
                    }
                ),
                onSubmit: { [weak self] answers, complete in
                    self?.controller?.submitAskResponse(request: request, answers: answers, completion: complete)
                },
                onIgnoreAll: { [weak self] complete in
                    self?.controller?.submitAskResponse(request: request, answers: nil, completion: complete)
                },
                voiceInputManager: ReleaseFeatures.voiceInputEnabled ? parent.voiceInputManager : nil,
                submittedRequestID: controller?.askSubmittedRequestID,
                responseFailed: controller?.askFailed(for: request) ?? false,
                autoAdvanceController: parent.autoAdvanceController
            )
        }

        private func updateTip() {
            guard let controller else { return }
            let show = ChatInputBar.showsBusyModeSelector(
                isBusy: parent.isBusy,
                hasAskRequest: parent.askRequest != nil
            )
            guard show else {
                controller.installBusyTip(nil)
                return
            }
            guard let root = HostFactory.root(near: controller) else { return }
            // The tip claims height only while it is presented; report that so
            // the bar does not keep an empty band once the tip is learned.
            let tip = FeatureEducationTipBannerHost(
                tip: FeatureEducationTips.BusySendModeTip(),
                descriptor: FeatureEducationTips.busySendMode,
                contentInsets: EdgeInsets(top: 8, leading: 12, bottom: 2, trailing: 12)
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { [weak self] height in
                DispatchQueue.main.async {
                    self?.commitTipHeight(height)
                }
            }
            if let tipHost {
                tipHost.setContent(tip)
                tipHost.view.backgroundColor = .clear
                controller.installBusyTip(tipHost)
            } else {
                let hosted = HostFactory.content(tip, root: root)
                hosted.sizingOptions = []
                hosted.view.backgroundColor = .clear
                tipHost = hosted
                controller.installBusyTip(hosted)
            }
        }

    }
}

// MARK: - Action factories

@MainActor
extension ComposerAction {
    static func model(
        title: String,
        provider: String?,
        colors: ComposerThemeColors,
        onTap: @escaping () -> Void
    ) -> ComposerAction {
        ComposerAction(
            id: "session.toolbar.model",
            icon: provider.map { .image(ComposerProviderIconRenderer.image(provider: $0, size: 11, colors: colors)) },
            title: title,
            tint: colors.fg,
            accessibilityLabel: "Model",
            accessibilityValue: title,
            showsChevron: true,
            chrome: .toolbar,
            kind: .tap(.init(onTap))
        )
    }

    static func thinking(
        level: ThinkingLevel,
        supported: [ThinkingLevel],
        tint: UIColor,
        colors: ComposerThemeColors,
        onSelect: @escaping (ThinkingLevel) -> Void,
        onSaveDefault: (() -> Void)?
    ) -> ComposerAction {
        ComposerAction(
            id: "session.toolbar.thinking",
            icon: .symbol("sparkle"),
            title: level.compactTitle,
            tint: tint,
            accessibilityLabel: "Thinking level",
            accessibilityValue: level.displayTitle,
            showsChevron: true,
            chrome: .toolbar,
            kind: .picker(ComposerActionPopover(
                preferredWidth: 220,
                make: {
                    ComposerThinkingPickerController(
                        levels: supported,
                        selected: level,
                        colors: colors,
                        onSelect: onSelect,
                        onSaveDefault: onSaveDefault
                    )
                },
                update: { screen in
                    (screen as? ComposerThinkingPickerController)?.apply(
                        levels: supported,
                        selected: level,
                        onSelect: onSelect,
                        onSaveDefault: onSaveDefault
                    )
                }
            ))
        )
    }

    static func agent(
        title: String,
        icon: UIImage,
        colors: ComposerThemeColors,
        rows: [ComposerOptionRow],
        isLoading: Bool,
        onSelect: @escaping (String?) -> Void
    ) -> ComposerAction {
        ComposerAction(
            id: "quickSession.agentPicker",
            icon: .image(icon),
            title: title,
            tint: colors.fg,
            accessibilityLabel: title == "Pi"
                ? "Agent picker, Pi with no agent"
                : "Agent picker, current agent \(title)",
            accessibilityValue: title,
            showsChevron: true,
            chrome: .toolbar,
            kind: .picker(ComposerActionPopover(
                preferredWidth: 280,
                make: {
                    ComposerOptionListController(
                        rows: rows,
                        isLoading: isLoading,
                        emptyMessage: "No saved Agents on this server.",
                        colors: colors,
                        preferredWidth: 280,
                        onSelect: { id in onSelect(id == "pi" ? nil : id) }
                    )
                },
                update: { screen in
                    (screen as? ComposerOptionListController)?.apply(
                        rows: rows,
                        isLoading: isLoading,
                        emptyMessage: "No saved Agents on this server.",
                        onSelect: { id in onSelect(id == "pi" ? nil : id) }
                    )
                }
            ))
        )
    }

    static func workspace(
        title: String,
        icon: UIImage?,
        identifier: String,
        menu: UIMenu,
        colors: ComposerThemeColors
    ) -> ComposerAction {
        ComposerAction(
            id: identifier,
            icon: icon.map { .image($0) } ?? .symbol("folder"),
            title: title,
            tint: colors.fg,
            accessibilityLabel: "Workspace picker, current workspace \(title)",
            accessibilityValue: title,
            showsChevron: true,
            chrome: .toolbar,
            kind: .menu(menu)
        )
    }

    static func reviewChip(id: String, title: String, systemImage: String, onTap: @escaping () -> Void) -> ComposerAction {
        ComposerAction(
            id: id,
            icon: .symbol(systemImage),
            title: title,
            tint: nil,
            accessibilityLabel: title,
            accessibilityValue: nil,
            showsChevron: false,
            chrome: .chip,
            kind: .tap(.init(onTap))
        )
    }

    static func reviewCancel(onTap: @escaping () -> Void) -> ComposerAction {
        ComposerAction(
            id: "chat.reviewComment.cancel",
            icon: .symbol("xmark"),
            title: "",
            tint: nil,
            accessibilityLabel: "Cancel comment",
            accessibilityValue: nil,
            showsChevron: false,
            chrome: .cancel,
            kind: .tap(.init(onTap))
        )
    }
}

@MainActor
enum ComposerProviderIconRenderer {
    static func image(provider: String, size: CGFloat, colors: ComposerThemeColors) -> UIImage {
        let tint = UIColor(providerIconTint(
            ProviderIcon.brandColor(for: provider),
            palette: ThemeRuntimeState.currentPalette()
        ))
        if let assetName = ProviderIcon.logoAssetName(for: provider),
           let asset = UIImage(named: assetName) {
            return asset.withTintColor(tint, renderingMode: .alwaysOriginal)
        }
        let mark = ProviderIcon.mark(for: provider) as NSString
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(8, size * 0.8), weight: .heavy),
                .foregroundColor: tint,
            ]
            let textSize = mark.size(withAttributes: attributes)
            mark.draw(
                at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }
}

@MainActor
extension ComposerActionRow {
    static var previewModelThinking: ComposerActionRow {
        ComposerActionRow(
            leading: [
                ComposerAction(
                    id: "session.toolbar.model",
                    icon: nil,
                    title: "gpt-5.5",
                    tint: nil,
                    accessibilityLabel: "Model",
                    accessibilityValue: "gpt-5.5",
                    showsChevron: false,
                    kind: .tap(.init {})
                ),
                ComposerAction(
                    id: "session.toolbar.thinking",
                    icon: nil,
                    title: "max",
                    tint: UIColor(red: 0.75, green: 0.62, blue: 1, alpha: 1),
                    accessibilityLabel: "Thinking level",
                    accessibilityValue: "Max",
                    showsChevron: false,
                    kind: .tap(.init {})
                ),
            ]
        )
    }

    static func sessionToolbar(
        modelTitle: String,
        modelProvider: String?,
        thinkingLevel: ThinkingLevel,
        thinkingTint: UIColor,
        supportedThinkingLevels: [ThinkingLevel],
        colors: ComposerThemeColors,
        onModelTap: @escaping () -> Void,
        onThinkingSelect: @escaping (ThinkingLevel) -> Void,
        onSaveThinkingAsDefault: (() -> Void)?
    ) -> ComposerActionRow {
        ComposerActionRow(
            trailing: [
                .model(title: modelTitle, provider: modelProvider, colors: colors, onTap: onModelTap),
                .thinking(
                    level: thinkingLevel,
                    supported: supportedThinkingLevels,
                    tint: thinkingTint,
                    colors: colors,
                    onSelect: onThinkingSelect,
                    onSaveDefault: onSaveThinkingAsDefault
                ),
            ]
        )
    }
}


extension ComposerThemeColors {
    init(palette: ThemePalette) {
        let elevated = ThemeSurfaceStyle.resolve(.elevatedPanel, palette: palette)
        let floating = ThemeSurfaceStyle.resolve(.floatingControl, palette: palette)
        self.init(
            bg: UIColor(palette.bg),
            bgDark: UIColor(palette.bgDark),
            bgHighlight: UIColor(palette.bgHighlight),
            fg: UIColor(palette.fg),
            fgDim: UIColor(palette.fgDim),
            comment: UIColor(palette.comment),
            blue: UIColor(palette.blue),
            cyan: UIColor(palette.cyan),
            green: UIColor(palette.green),
            orange: UIColor(palette.orange),
            purple: UIColor(palette.purple),
            red: UIColor(palette.red),
            yellow: UIColor(palette.yellow),
            scrim: UIColor(palette.bgDark.opacity(0.82)),
            elevatedStroke: UIColor(elevated.stroke ?? palette.fg.opacity(0.12)),
            floatingFill: UIColor(floating.fill)
        )
    }
}

// MARK: - PendingImage

/// An image queued for sending. Holds a thumbnail for display and
/// full-resolution image data + base64 for upload.
struct PendingImage: Identifiable, Sendable {
    let id: String
    let thumbnail: UIImage
    let attachment: ImageAttachment

    private typealias EncodedImage = (data: Data, mimeType: String)

    static let autoResizeMaxDimension: CGFloat = 2_000
    static let autoResizeMaxBase64Bytes = 4_718_592
    static let autoResizeMaxDataBytes = (autoResizeMaxBase64Bytes / 4) * 3
    private static let autoResizeJPEGQualities: [CGFloat] = [0.8, 0.85, 0.7, 0.55, 0.4]

    var pendingAttachment: PendingAttachment {
        PendingAttachment(
            id: id,
            source: .image,
            displayName: "Image",
            thumbnail: thumbnail,
            imageAttachment: attachment,
            localFileData: nil,
            localMimeType: nil
        )
    }

    static func from(data: Data, mimeType: String?, image: UIImage) -> Self {
        if let sendableMimeType = sendableOriginalMimeType(data: data, declaredMimeType: mimeType) {
            return Self(
                id: UUID().uuidString,
                thumbnail: downsample(image, maxDimension: 112),
                attachment: ImageAttachment(
                    data: data.base64EncodedString(),
                    mimeType: sendableMimeType
                )
            )
        }
        return from(image)
    }

    static func from(_ image: UIImage) -> Self {
        let thumb = downsample(image, maxDimension: 112)
        let imageData = image.jpegData(compressionQuality: 1.0) ?? image.pngData() ?? Data()
        let mimeType = sniffedMimeType(data: imageData) ?? "image/jpeg"
        return Self(
            id: UUID().uuidString,
            thumbnail: thumb,
            attachment: ImageAttachment(
                data: imageData.base64EncodedString(),
                mimeType: mimeType
            )
        )
    }

    static func uploadAttachment(from attachment: ImageAttachment, autoResize: Bool) -> ImageAttachment {
        guard autoResize,
              let originalData = Data(base64Encoded: attachment.data, options: .ignoreUnknownCharacters),
              let image = UIImage(data: originalData) else {
            return attachment
        }

        let originalFitsDimensions = maxPixelDimension(for: image) <= autoResizeMaxDimension
        if originalFitsDimensions && base64ByteCount(for: originalData) <= autoResizeMaxBase64Bytes {
            return attachment
        }

        var workingImage = originalFitsDimensions
            ? image
            : downsample(image, maxDimension: autoResizeMaxDimension)
        var bestCandidate: EncodedImage?

        while true {
            for candidate in encodedCandidates(for: workingImage) {
                if let best = bestCandidate {
                    if candidate.data.count < best.data.count {
                        bestCandidate = candidate
                    }
                } else {
                    bestCandidate = candidate
                }
                if base64ByteCount(for: candidate.data) <= autoResizeMaxBase64Bytes {
                    return ImageAttachment(
                        data: candidate.data.base64EncodedString(),
                        mimeType: candidate.mimeType
                    )
                }
            }

            let currentSize = pixelSize(for: workingImage)
            let nextSize = CGSize(
                width: max(1, floor(currentSize.width * 0.75)),
                height: max(1, floor(currentSize.height * 0.75))
            )
            guard nextSize.width < currentSize.width || nextSize.height < currentSize.height else {
                break
            }
            workingImage = render(workingImage, size: nextSize)
        }

        guard let bestCandidate else { return attachment }
        return ImageAttachment(
            data: bestCandidate.data.base64EncodedString(),
            mimeType: bestCandidate.mimeType
        )
    }

    private static func sendableOriginalMimeType(data: Data, declaredMimeType: String?) -> String? {
        if let sniffed = sniffedMimeType(data: data) {
            return sniffed
        }
        switch normalizedMimeType(declaredMimeType) {
        case "image/jpeg", "image/jpg": return "image/jpeg"
        case "image/png": return "image/png"
        case "image/gif": return "image/gif"
        case "image/webp": return "image/webp"
        default: return nil
        }
    }

    private static func normalizedMimeType(_ mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        return mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func sniffedMimeType(data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        if data.count >= 12,
           data.prefix(4).elementsEqual(Array("RIFF".utf8)),
           data.dropFirst(8).prefix(4).elementsEqual(Array("WEBP".utf8)) {
            return "image/webp"
        }
        return nil
    }

    private static func encodedCandidates(for image: UIImage) -> [EncodedImage] {
        var candidates: [EncodedImage] = []
        if let pngData = image.pngData() {
            candidates.append((pngData, "image/png"))
        }
        for quality in autoResizeJPEGQualities {
            if let jpegData = image.jpegData(compressionQuality: quality) {
                candidates.append((jpegData, "image/jpeg"))
            }
        }
        return candidates
    }

    private static func base64ByteCount(for data: Data) -> Int {
        ((data.count + 2) / 3) * 4
    }

    private static func maxPixelDimension(for image: UIImage) -> CGFloat {
        let size = pixelSize(for: image)
        return max(size.width, size.height)
    }

    private static func pixelSize(for image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return image.size
    }

    private static func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = pixelSize(for: image)
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxDimension / size.width, maxDimension / size.height)
        if scale >= 1.0 { return image }
        let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        return render(image, size: newSize)
    }

    private static func render(_ image: UIImage, size: CGSize) -> UIImage {
        let renderSize = CGSize(
            width: max(1, floor(size.width)),
            height: max(1, floor(size.height))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: renderSize))
        }
    }
}
