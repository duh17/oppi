import UIKit

/// The Ask slot: the UIKit card, its viewport, and answering the request.
extension ComposerBarController {
    var askCurrentPage: Int {
        get { askClearing.currentPage }
        set {
            askClearing.currentPage = newValue
            syncComposerTextWithActiveAskQuestion()
        }
    }

    var askDraftAnswers: [String: AskAnswer] {
        get { askClearing.draftAnswers }
        set {
            askClearing.draftAnswers = newValue
            syncComposerTextWithActiveAskQuestion()
        }
    }

    var askSubmittedRequestID: String? { askClearing.submittedRequestID }

    func askFailed(for request: AskRequest) -> Bool {
        if case .failed(let id) = askClearing.submission.phase { return id == request.id }
        return false
    }

    /// Keeps the UIKit Ask card in the Ask slot in step with the host's request.
    func refreshAskCard() {
        guard let host else { return }
        let content = host.content
        guard let request = content.askRequest else {
            removeAskCard()
            return
        }
        let card = askCard ?? installAskCard()
        card.autoAdvanceController = host.askAutoAdvanceController
        card.voiceInputManager = content.voiceInputManager
        card.onPageChange = { [weak self] page in
            self?.askCurrentPage = page
        }
        card.onAnswersChange = { [weak self] answers in
            self?.askDraftAnswers = answers
        }
        card.onSubmit = { [weak self] answers, complete in
            self?.submitAskResponse(request: request, answers: answers, completion: complete)
        }
        card.onIgnoreAll = { [weak self] complete in
            self?.submitAskResponse(request: request, answers: nil, completion: complete)
        }
        card.onHeightChange = { [weak self] height in
            self?.askNaturalHeight = height
            self?.applyAskViewport()
        }
        card.apply(
            request: request,
            currentPage: askClearing.currentPage,
            answers: askClearing.draftAnswers,
            submittedRequestID: askClearing.submittedRequestID,
            responseFailed: askFailed(for: request),
            colors: content.colors,
            reduceMotion: content.reduceMotion
        )
        measureAskCard(slotWidth: askContainer.bounds.width > 1
            ? askContainer.bounds.width
            : view.bounds.width - (content.appliesOuterPadding ? 32 : 0))
    }

    private func installAskCard() -> AskCardViewController {
        let card = AskCardViewController()
        addChild(card)
        card.view.translatesAutoresizingMaskIntoConstraints = false
        askContainer.addSubview(card.view)
        NSLayoutConstraint.activate([
            card.view.leadingAnchor.constraint(equalTo: askContainer.leadingAnchor),
            card.view.trailingAnchor.constraint(equalTo: askContainer.trailingAnchor),
            card.view.topAnchor.constraint(equalTo: askContainer.topAnchor),
            card.view.bottomAnchor.constraint(equalTo: askContainer.bottomAnchor),
        ])
        card.didMove(toParent: self)
        askCard = card
        return card
    }

    private func removeAskCard() {
        guard let card = askCard else { return }
        askCard = nil
        askNaturalHeight = 0
        card.tearDown()
        card.willMove(toParent: nil)
        card.view.removeFromSuperview()
        card.removeFromParent()
    }

    /// The card's natural height at the slot's width; the slot caps it.
    func measureAskCard(slotWidth: CGFloat) {
        guard let askCard, slotWidth > 1 else { return }
        askCard.loadViewIfNeeded()
        askNaturalHeight = askCard.preferredHeight(for: slotWidth)
    }

    /// `notifyHost` is false while `sizeThatFits` is already measuring the bar.
    func applyAskViewport(notifyHost: Bool = true) {
        let hasAsk = host?.content.askRequest != nil
        let focused = isInputFocused && !(host?.content.suppressKeyboard ?? false)
        let cap = focused
            ? ComposerInputMetrics.inlineAskCardMaxHeightWithKeyboard
            : ExtensionNativeSurfaceLayout.expandedMaxHeight
        let natural = hasAsk ? max(askNaturalHeight, 0) : 0
        let slot = min(natural, cap)
        let slotChanged = askHeightConstraint?.constant != slot
        if slotChanged {
            askHeightConstraint?.constant = slot
        }
        askContainer.setHiddenIfChanged(!hasAsk || slot <= 0)
        if slotChanged {
            view.invalidateIntrinsicContentSize()
            if notifyHost { host?.barHeightDidChange() }
        }
    }

    var isCurrentAskSubmitted: Bool {
        askClearing.submittedRequestID != nil && askClearing.submittedRequestID == host?.content.askRequest?.id
    }

    private var activeAskQuestionID: String? {
        guard let askRequest = host?.content.askRequest,
              askClearing.currentPage >= 0,
              askClearing.currentPage < askRequest.questions.count else {
            return nil
        }
        return askRequest.questions[askClearing.currentPage].id
    }

    var pendingAskSendTransition: ComposerPolicy.AskComposerSendTransition? {
        ComposerPolicy.askComposerSendTransition(
            request: host?.content.askRequest,
            currentPage: askClearing.currentPage,
            draftAnswers: askClearing.draftAnswers,
            text: composerDisplayText
        )
    }

    func handleAskComposerSendIfNeeded() -> Bool {
        guard !isCurrentAskSubmitted else { return true }
        guard let transition = pendingAskSendTransition else { return false }
        if transition.shouldSubmit, let askRequest = host?.content.askRequest {
            askClearing.draftAnswers = transition.answers
            submitAskResponse(request: askRequest, answers: transition.answers)
            return true
        }
        askClearing.draftAnswers = transition.answers
        host?.setText(transition.nextComposerText)
        host?.setTextBeforeRecording(nil)
        askClearing.currentPage = transition.nextPage
        applyChrome()
        return true
    }

    func submitAskResponse(
        request: AskRequest,
        answers: [String: AskAnswer]?,
        completion: @escaping AskResponseSubmission.Completion = { _ in }
    ) {
        guard host?.content.askRequest?.id == request.id else {
            completion(.completed)
            return
        }
        var submittedTextRevision: UInt64?
        askClearing.submission.submit(requestID: request.id, deliver: { complete in
            submittedTextRevision = self.askClearing.textRevision
            self.host?.setText("")
            self.host?.setTextBeforeRecording(nil)
            if let answers {
                self.host?.submitAsk(request, answers: answers, completion: complete)
            } else {
                self.host?.ignoreAsk(request, completion: complete)
            }
            FeatureEducationTips.markPromptAnswered()
            self.applyChrome()
        }, completion: { result in
            if result == .retryableFailure,
               let submittedTextRevision,
               self.askClearing.textRevision == submittedTextRevision,
               self.host?.content.text.isEmpty == true,
               let restored = ComposerPolicy.composerTextForActiveAskQuestion(
                   request: self.host?.content.askRequest,
                   activeQuestionID: self.activeAskQuestionID,
                   draftAnswers: self.askClearing.draftAnswers,
                   keepComposerClearedForSubmittedRequestID: self.askClearing.submittedRequestID
               ) {
                self.host?.setText(restored)
                self.host?.setTextBeforeRecording(nil)
            }
            completion(result)
            self.applyChrome()
        })
    }

    func syncComposerTextWithActiveAskQuestion() {
        guard let desiredText = ComposerPolicy.composerTextForActiveAskQuestion(
            request: host?.content.askRequest,
            activeQuestionID: activeAskQuestionID,
            draftAnswers: askClearing.draftAnswers,
            keepComposerClearedForSubmittedRequestID: askClearing.submittedRequestID
        ) else { return }
        guard host?.content.text != desiredText || host?.content.textBeforeRecording != nil else { return }
        host?.setText(desiredText)
        host?.setTextBeforeRecording(nil)
    }
}
