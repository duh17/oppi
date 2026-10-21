import UIKit

/// Quick Session: a dimmed scrim over the app with the destination pills and
/// the chat's composer (`ChatComposerOwner`) just above the keyboard.
///
/// `AppRootViewController` mounts it over the shell while
/// `AppNavigation.showQuickSession` is set (`QuickSessionPresentation`). Its
/// state and actions live in `QuickSessionModel`; this controller draws them,
/// presents the pickers, and is the composer's `ChatComposerSource`, as the
/// chat screen is for its own composer.
///
/// This file holds the layout and lifecycle. `+Pills` draws the destination
/// row, the error, and the accessibility-size panel; `+Pickers` presents the
/// workspace, worktree, Agent, thinking, and model pickers; `+Composer` is the
/// composer's source.
///
/// Only the scrim fills edge to edge. The pills and composer stay inside the
/// safe area, so they never sit under a vertical rail on the leading or
/// trailing edge (the iPhone Duo), and their bottom follows the keyboard. When
/// they do not fit above the keyboard (an iPhone in landscape), they scroll.
/// At accessibility text sizes the Agent, model, and thinking pills leave the
/// composer's action row for a panel of their own below it.
@MainActor
final class QuickSessionViewController: UIViewController {
    let model: QuickSessionModel
    let root: AppRootEnvironment
    let close: () -> Void

    let composer = ChatComposerOwner()
    /// Rendered Agent and Pi icons the composer reuses between updates.
    let composerIcons = QuickSessionComposerIconCache()
    /// The dimmed backdrop; a tap on it closes Quick Session. The viewport and
    /// stacked panel sit over it and take their own touches, so a touch that
    /// content passes on never reaches the scrim.
    private let scrim = UIButton()
    private let viewport = UIScrollView()
    let contentStack = UIStackView()
    let errorPanel = QuickSessionErrorPanel()
    private let destinationRowContainer = UIView()
    private let destinationRow = UIStackView()
    let workspacePill = QuickSessionPillButton()
    let worktreePill = QuickSessionPillButton()
    let threadPill = QuickSessionPillButton()
    let enginePill = QuickSessionPillButton()
    let incognitoPill = QuickSessionPillButton(minimumWidth: ComposerInputMetrics.controlDiameter)
    let stackedPanel = UIView()
    private let stackedGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    let agentPill = QuickSessionPillButton()
    let modelPill = ComposerToolbarPillButton()
    let thinkingPill = ComposerToolbarPillButton()
    var viewportToKeyboard: NSLayoutConstraint?
    var viewportToStackedPanel: NSLayoutConstraint?

    let modelPicker = RouterModalPresenter()
    let workspacePicker = RouterModalPresenter()
    let worktreePicker = RouterModalPresenter()
    let agentPicker = RouterModalPresenter()
    let thinkingPicker = RouterModalPresenter()
    /// The stacked thinking pill's popover; the action row's pill presents its own.
    var showsThinkingPicker = false {
        didSet { setNeedsUpdateProperties() }
    }

    private var setupTask: Task<Void, Never>?
    private var observedFileIndexPaths: [String]??
    /// Swipe down to close, as a modal's down swipe: a draft or a viewport
    /// that is scrolled down takes the swipe to scroll back up instead.
    private lazy var dismissSwipe = HorizontalBackSwipeGestureInstaller(
        onBack: { [weak self] in self?.close() },
        direction: .down
    )
    /// A tap on the empty space around the pills closes Quick Session, as a
    /// tap on the scrim does. A tap recognizer rather than letting touches
    /// through to the scrim: a drag there still scrolls a viewport that
    /// overflows (an iPhone in landscape), where the scrim's button closed
    /// on lift.
    private lazy var emptySpaceTap = UITapGestureRecognizer(
        target: self,
        action: #selector(handleEmptySpaceTap)
    )

    init(root: AppRootEnvironment, onDismiss: @escaping () -> Void) {
        self.root = root
        close = onDismiss
        model = QuickSessionModel(root: root)
        super.init(nibName: nil, bundle: nil)
        model.onDismiss = onDismiss
        // Presented controllers and the composer's hosts find the app root here.
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let overlay = QuickSessionOverlayView()
        overlay.onEscape = { [weak self] in self?.close() }
        view = overlay
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildScrim()
        buildContent()
        buildStackedPanel()
        layout()
        installPresenters()
        dismissSwipe.install(on: view)
        emptySpaceTap.delegate = self
        viewport.addGestureRecognizer(emptySpaceTap)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: Self, _: UITraitCollection) in
            controller.setNeedsUpdateProperties()
            controller.composer.setNeedsUpdateProperties()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard setupTask == nil else { return }
        setupTask = Task { [weak self] in
            guard let model = self?.model else { return }
            await model.setUp(
                requestDictation: { [weak self] in
                    self?.composer.requestDictation(owner: .inboxComposer)
                },
                focusComposer: { [weak self] in
                    await self?.focusComposer()
                }
            )
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for presenter in presenters { presenter.sync() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Scroll only when the pills and composer do not fit above the keyboard.
        let overflows = contentStack.frame.height > viewport.bounds.height + 0.5
        if viewport.isScrollEnabled != overflows {
            viewport.isScrollEnabled = overflows
            viewport.showsVerticalScrollIndicator = overflows
        }
    }

    /// Quick Session is closing: stop its work, close what it presented, and
    /// hand back the microphone.
    func tearDown() {
        setupTask?.cancel()
        model.showModelPicker = false
        model.showWorkspacePicker = false
        model.showWorktreePicker = false
        model.showAgentPicker = false
        model.showExpandedComposer = false
        showsThinkingPicker = false
        // Run the cleared requests now, while this controller and the
        // composer are still in the window: their presenters dismiss the
        // pickers and the expanded composer only from a pass that sees them.
        updatePropertiesIfNeeded()
        composer.updatePropertiesIfNeeded()
        model.tearDown()
    }

    // MARK: - Updates

    var colors: ComposerThemeColors {
        ComposerThemeColors(palette: root.themeStore.activeThemeID.palette)
    }

    var thinkingTint: UIColor {
        UIColor(root.themeStore.appTheme.thinking.color(for: model.effectiveThinkingLevel))
    }

    var stacksActionControls: Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    override func updateProperties() {
        super.updateProperties()
        let colors = colors
        updateErrorPanel(colors: colors)
        updateDestinationRow(colors: colors)
        updateStackedPanel(colors: colors)
        // Until set up, the composer takes no touches; the viewport around it
        // still does, so nothing reaches the scrim.
        contentStack.isUserInteractionEnabled = model.isInitialized
        model.syncLoads()
        observeFileIndex()
        updatePresenters(colors: colors)
    }

    /// The first @ query can arrive before /paths finishes loading.
    private func observeFileIndex() {
        let paths = model.selectedServerConnection()?.fileIndexStore.paths
        guard let observed = observedFileIndexPaths else {
            observedFileIndexPaths = .some(paths)
            return
        }
        guard observed != paths else { return }
        observedFileIndexPaths = .some(paths)
        model.fileIndexPathsDidChange()
    }

    // MARK: - Building

    private func buildScrim() {
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.34)
        // VoiceOver leaves Quick Session with the escape gesture or the
        // Dismiss action; the scrim stays out of its way.
        scrim.isAccessibilityElement = false
        scrim.accessibilityIdentifier = "quickSession.overlay"
        scrim.addAction(UIAction { [weak self] _ in self?.close() }, for: .primaryActionTriggered)
        scrim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrim)
    }

    private func buildContent() {
        viewport.accessibilityIdentifier = "quickSession.viewport"
        viewport.contentInsetAdjustmentBehavior = .never
        viewport.keyboardDismissMode = .none
        viewport.alwaysBounceVertical = false
        viewport.isScrollEnabled = false
        viewport.showsVerticalScrollIndicator = false
        viewport.backgroundColor = .clear
        viewport.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewport)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 8
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(contentStack)

        errorPanel.isHidden = true
        errorPanel.onChooseWorkspace = { [weak self] in self?.model.showWorkspacePicker = true }
        errorPanel.onOpenAgents = { [weak self] in
            guard let self else { return }
            self.close()
            self.root.navigation.openWorkspaceUtility(.agents)
        }
        contentStack.addArrangedSubview(errorPanel)

        // Workspace and worktree sit above the capsule so destination is
        // chosen before compose. Agent/model/thinking stay in the action row.
        destinationRow.axis = .horizontal
        destinationRow.alignment = .center
        destinationRow.spacing = 6
        destinationRow.translatesAutoresizingMaskIntoConstraints = false
        workspacePill.accessibilityIdentifier = "quickSession.workspacePicker"
        workspacePill.setTitleCompressionResistance(.defaultHigh)
        workspacePill.addAction(UIAction { [weak self] _ in self?.model.showWorkspacePicker.toggle() }, for: .primaryActionTriggered)
        worktreePill.accessibilityIdentifier = "quickSession.worktreePicker"
        worktreePill.addAction(UIAction { [weak self] _ in self?.model.showWorktreePicker.toggle() }, for: .primaryActionTriggered)
        threadPill.accessibilityIdentifier = "quickSession.threadParent"
        threadPill.accessibilityHint = "Removes the thread so the session starts on its own"
        threadPill.addAction(UIAction { [weak self] _ in self?.model.clearThreadParent() }, for: .primaryActionTriggered)
        enginePill.accessibilityIdentifier = "quickSession.durableEngine"
        enginePill.addAction(UIAction { [weak self] _ in self?.model.toggleEngine() }, for: .primaryActionTriggered)
        incognitoPill.accessibilityIdentifier = "quickSession.incognito"
        incognitoPill.accessibilityLabel = "Incognito"
        incognitoPill.accessibilityHint = "An incognito session keeps no history and is deleted when you leave it"
        incognitoPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        incognitoPill.addAction(UIAction { [weak self] _ in self?.model.toggleIncognito() }, for: .primaryActionTriggered)
        for pill in [workspacePill, worktreePill, threadPill, enginePill, incognitoPill] {
            destinationRow.addArrangedSubview(pill)
        }
        destinationRowContainer.addSubview(destinationRow)
        NSLayoutConstraint.activate([
            destinationRow.leadingAnchor.constraint(equalTo: destinationRowContainer.leadingAnchor, constant: 16),
            destinationRow.trailingAnchor.constraint(lessThanOrEqualTo: destinationRowContainer.trailingAnchor, constant: -16),
            destinationRow.topAnchor.constraint(equalTo: destinationRowContainer.topAnchor),
            destinationRow.bottomAnchor.constraint(equalTo: destinationRowContainer.bottomAnchor),
        ])
        contentStack.addArrangedSubview(destinationRowContainer)

        composer.source = self
        addChild(composer)
        contentStack.addArrangedSubview(composer.view)
        composer.didMove(toParent: self)
    }

    private func buildStackedPanel() {
        stackedPanel.isHidden = true
        stackedPanel.translatesAutoresizingMaskIntoConstraints = false
        stackedGlass.clipsToBounds = true
        stackedGlass.layer.cornerRadius = 20
        stackedGlass.layer.cornerCurve = .continuous
        stackedGlass.translatesAutoresizingMaskIntoConstraints = false
        stackedPanel.addSubview(stackedGlass)

        agentPill.accessibilityIdentifier = "quickSession.agentPicker"
        agentPill.addAction(UIAction { [weak self] _ in self?.model.showAgentPicker.toggle() }, for: .primaryActionTriggered)
        modelPill.accessibilityIdentifier = "session.toolbar.model"
        modelPill.accessibilityLabel = "Model"
        modelPill.addAction(UIAction { [weak self] _ in self?.model.showModelPicker = true }, for: .primaryActionTriggered)
        thinkingPill.accessibilityIdentifier = "session.toolbar.thinking"
        thinkingPill.accessibilityLabel = "Thinking level"
        thinkingPill.addAction(UIAction { [weak self] _ in self?.showsThinkingPicker = true }, for: .primaryActionTriggered)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        let toolbar = ComposerPillStackView(arrangedSubviews: [spacer, modelPill, thinkingPill])
        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.spacing = 6
        let agentRow = UIStackView(arrangedSubviews: [agentPill])
        agentRow.alignment = .leading
        agentRow.axis = .vertical
        let column = UIStackView(arrangedSubviews: [agentRow, toolbar])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        stackedPanel.addSubview(column)
        NSLayoutConstraint.activate([
            stackedGlass.leadingAnchor.constraint(equalTo: stackedPanel.leadingAnchor),
            stackedGlass.trailingAnchor.constraint(equalTo: stackedPanel.trailingAnchor),
            stackedGlass.topAnchor.constraint(equalTo: stackedPanel.topAnchor),
            stackedGlass.bottomAnchor.constraint(equalTo: stackedPanel.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: stackedPanel.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: stackedPanel.trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: stackedPanel.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: stackedPanel.bottomAnchor, constant: -8),
        ])
        view.addSubview(stackedPanel)
    }

    private func layout() {
        let safe = view.safeAreaLayoutGuide
        let keyboard = view.keyboardLayoutGuide
        // Fit the content; past the space above the keyboard, scroll it.
        let fitsContent = viewport.heightAnchor.constraint(equalTo: contentStack.heightAnchor)
        fitsContent.priority = .defaultHigh
        let toKeyboard = viewport.bottomAnchor.constraint(equalTo: keyboard.topAnchor)
        let toStackedPanel = viewport.bottomAnchor.constraint(equalTo: stackedPanel.topAnchor)
        viewportToKeyboard = toKeyboard
        viewportToStackedPanel = toStackedPanel
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            viewport.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            viewport.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: 12),
            fitsContent,
            toKeyboard,

            contentStack.leadingAnchor.constraint(equalTo: viewport.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: viewport.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: viewport.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: viewport.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: viewport.frameLayoutGuide.widthAnchor),

            stackedPanel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            stackedPanel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            stackedPanel.bottomAnchor.constraint(equalTo: keyboard.topAnchor, constant: -8),
        ])
    }

    /// Popovers anchor to their pill: each pill is the view of a child
    /// controller its presenter presents from.
    private func installPresenters() {
        modelPicker.anchor = self
        workspacePicker.anchor = anchor(for: workspacePill)
        worktreePicker.anchor = anchor(for: worktreePill)
        agentPicker.anchor = anchor(for: agentPill)
        thinkingPicker.anchor = anchor(for: thinkingPill)
    }

    private func anchor(for pill: UIView) -> UIViewController {
        let anchor = QuickSessionPillAnchor(pill: pill)
        addChild(anchor)
        anchor.loadViewIfNeeded()
        anchor.didMove(toParent: self)
        return anchor
    }

    // MARK: - Empty-space tap

    @objc private func handleEmptySpaceTap() {
        close()
    }

    // MARK: - Focus

    /// Raises the keyboard in the composer, then moves VoiceOver there.
    private func focusComposer() async {
        composer.requestFocus()
        // The text view takes first responder in the bar's apply pass; posting
        // the screen change before it has would point VoiceOver at a field
        // that is not yet focused. Two yields let that pass and the
        // accessibility tree catch up.
        await Task.yield()
        await Task.yield()
        guard let input = composer.view.quickSessionDescendant(accessibilityIdentifier: "chat.input") else { return }
        UIAccessibility.post(notification: .screenChanged, argument: input)
    }
}

extension QuickSessionViewController: UIGestureRecognizerDelegate {
    /// The empty-space tap takes only a touch on the layout around the pills,
    /// never one on a pill or the composer, and only once Quick Session is set
    /// up: closing earlier cancels setup, and with it a Shortcut's text and
    /// files or a Live Voice start.
    /// A tap that stops a decelerating viewport only stops it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard model.isInitialized, !viewport.isDecelerating, let touched = touch.view else { return false }
        return [viewport, contentStack, destinationRowContainer, destinationRow].contains { $0 === touched }
    }
}

/// Quick Session's root view: modal to VoiceOver, which leaves it with the
/// escape gesture or the Dismiss action.
@MainActor
private final class QuickSessionOverlayView: UIView {
    var onEscape: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityViewIsModal = true
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Dismiss Quick Session") { [weak self] _ in
                self?.onEscape?()
                return true
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func accessibilityPerformEscape() -> Bool {
        onEscape?()
        return true
    }
}

/// A pill as the view of its own controller, so a router presenter anchors
/// the pill's popover to it.
@MainActor
private final class QuickSessionPillAnchor: UIViewController {
    private let pill: UIView

    init(pill: UIView) {
        self.pill = pill
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = pill
    }
}

private extension UIView {
    func quickSessionDescendant(accessibilityIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.quickSessionDescendant(accessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
