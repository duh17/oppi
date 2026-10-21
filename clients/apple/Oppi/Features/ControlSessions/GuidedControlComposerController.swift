import UIKit

/// The guided control-session composer: the launch error, the staged
/// review-comment pill, and the chat's composer (`ChatComposerOwner`), with the
/// workspace, model, and thinking pills in its action row. At accessibility
/// text sizes those pills do not fit the row and sit in a panel below it.
///
/// A screen embeds it as a child pinned above the keyboard (Agents, Schedules,
/// Custom Themes, the guided session sheet). Its state and launch live in
/// `GuidedControlComposerModel`; this controller draws them, presents the model
/// picker and the comment stash, and is the composer's `ChatComposerSource`
/// (`+Source`).
@MainActor
final class GuidedControlComposerController: UIViewController {
    let model: GuidedControlComposerModel
    let root: AppRootEnvironment

    let composer = ChatComposerOwner()
    private let stack = UIStackView()
    private let errorLabel = UILabel()
    private let errorRow = UIView()
    private let screenErrorLabel = UILabel()
    private let screenErrorRow = UIView()
    private var screenError: String?
    /// The staged-comment pill and, while open, its drawer.
    private let reviewStrip = UIStackView()
    private let reviewPill = ReviewCommentStripPillView()
    private let reviewDrawer = ReviewCommentStashDrawerView()
    private let stackedPanel = UIStackView()
    private let stackedWorkspacePill = ComposerToolbarPillButton()
    private let stackedModelPill = ComposerToolbarPillButton()
    private let stackedThinkingPill = ComposerToolbarPillButton()

    private let modelPicker = RouterModalPresenter()
    private let commentStash = RouterModalPresenter()

    init(
        configuration: GuidedControlComposerConfiguration,
        root: AppRootEnvironment,
        connection: (@MainActor () -> ServerConnection)? = nil,
        onSessionPrepared: ((WorkspaceSessionNavTarget) -> Void)? = nil
    ) {
        self.root = root
        let coordinator = root.coordinator
        model = GuidedControlComposerModel(
            configuration: configuration,
            connection: connection ?? { coordinator.activeConnection },
            navigation: root.navigation
        )
        model.onSessionPrepared = onSessionPrepared
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var colors: ComposerThemeColors {
        ComposerThemeColors(palette: root.themeStore.activeThemeID.palette)
    }

    var thinkingTint: UIColor {
        UIColor(root.themeStore.appTheme.thinking.color(for: model.thinkingLevel))
    }

    var stacksActionControls: Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    // MARK: - Embedding

    /// Adds the composer to `screen` as a child across its safe width, its
    /// bottom on the keyboard (the bottom safe area while there is none).
    func install(in screen: UIViewController) {
        screen.addChild(self)
        view.translatesAutoresizingMaskIntoConstraints = false
        screen.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: screen.view.safeAreaLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: screen.view.safeAreaLayoutGuide.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: screen.view.keyboardLayoutGuide.topAnchor),
        ])
        didMove(toParent: screen)
    }

    /// Content scrolls under the composer, as under a SwiftUI bottom safe-area
    /// inset: give `scrollView` room to scroll its end above it. Call from the
    /// screen's `viewDidLayoutSubviews()`.
    func insetContent(of scrollView: UIScrollView) {
        guard let container = view.superview else { return }
        let composerTop = view.convert(view.bounds, to: container).minY
        let covered = max(0, container.bounds.maxY - container.safeAreaInsets.bottom - composerTop)
        guard abs(scrollView.contentInset.bottom - covered) > 0.5 else { return }
        scrollView.contentInset.bottom = covered
        scrollView.verticalScrollIndicatorInsets.bottom = covered
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        buildErrorRow(screenErrorRow, label: screenErrorLabel)
        buildErrorRow(errorRow, label: errorLabel)
        errorLabel.accessibilityIdentifier = "\(model.identifierPrefix).error"
        // Only a revision of reviewed text stages comments.
        if let comments = model.configuration.stagedComments {
            buildReviewStrip(comments: comments)
        }

        composer.source = self
        addChild(composer)
        stack.addArrangedSubview(composer.view)
        composer.didMove(toParent: self)

        buildStackedPanel()

        modelPicker.anchor = self
        commentStash.anchor = self
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: Self, _: UITraitCollection) in
            controller.setNeedsUpdateProperties()
            controller.composer.setNeedsUpdateProperties()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        model.appear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for presenter in [modelPicker, commentStash] { presenter.sync() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.disappear()
    }

    // MARK: - Updates

    override func updateProperties() {
        super.updateProperties()
        let colors = colors
        if let error = model.error {
            errorLabel.attributedText = Self.errorText(error, colors: colors)
            errorRow.isHidden = false
        } else {
            errorRow.isHidden = true
        }
        if let screenError {
            screenErrorLabel.attributedText = Self.errorText(screenError, colors: colors)
            screenErrorRow.isHidden = false
        } else {
            screenErrorRow.isHidden = true
        }
        model.reconcileReviewCommentDrawer()
        updateReviewStrip()
        // The workspace pill stays usable while the composer waits for one.
        composer.view.isUserInteractionEnabled = model.acceptsInput
        updateStackedPanel(colors: colors)
        updatePresenters()
    }

    private func updatePresenters() {
        let model = model
        modelPicker.update(
            id: model.showModelPicker ? "model-picker" : nil,
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak model] in model?.showModelPicker = false },
            screen: {
                let current = model.effectiveModelId
                let connection = model.connection
                return .liveController({ [weak model] in
                    ModelPickerViewController(
                        currentModel: current,
                        chatState: connection.chatState,
                        apiClient: connection.apiClient,
                        onSelect: { model?.selectModel($0) }
                    )
                }, update: { $0.currentModel = current })
            }
        )
        let stash = model.reviewCommentStashPresentation
        commentStash.update(
            id: stash.map { AnyHashable($0.id) },
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak model] in model?.reviewCommentStashPresentation = nil },
            screen: {
                .controller({ [weak model] in
                    guard let model, let comments = model.configuration.stagedComments else {
                        preconditionFailure("The stash sheet opens only with staged comments")
                    }
                    return ReviewCommentStashViewController(
                        stash: comments,
                        editing: stash?.initialEditingComment,
                        onClose: { [weak model] in model?.reviewCommentStashPresentation = nil }
                    )
                })
            }
        )
    }

    // MARK: - Staged comments

    private func buildReviewStrip(comments: ChatReviewCommentsController) {
        reviewStrip.axis = .vertical
        reviewStrip.alignment = .fill
        reviewStrip.spacing = 8
        reviewStrip.isLayoutMarginsRelativeArrangement = true
        reviewStrip.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        let pillRow = UIStackView(arrangedSubviews: [reviewPill, UIView()])
        pillRow.axis = .horizontal
        pillRow.alignment = .center
        reviewStrip.addArrangedSubview(pillRow)
        reviewStrip.addArrangedSubview(reviewDrawer)
        reviewPill.onToggle = { [weak model] in model?.toggleReviewCommentDrawer() }
        reviewPill.onOpenFullScreen = { [weak model] in model?.presentReviewCommentStash() }
        reviewDrawer.onEdit = { [weak model] in model?.presentReviewCommentStash(editing: $0) }
        reviewDrawer.onDelete = { [weak comments] in comments?.delete($0) }
        stack.addArrangedSubview(reviewStrip)
    }

    private func updateReviewStrip() {
        guard let comments = model.configuration.stagedComments else { return }
        let presentation = model.reviewCommentPresentation
        reviewStrip.isHidden = !presentation.showsPill
        guard presentation.showsPill else { return }
        let themeID = root.themeStore.activeThemeID
        reviewPill.apply(
            count: presentation.pendingCount,
            isExpanded: model.reviewCommentDrawerExpanded,
            palette: themeID.palette
        )
        reviewDrawer.isHidden = !model.reviewCommentDrawerExpanded
        if model.reviewCommentDrawerExpanded {
            reviewDrawer.apply(comments: comments.stagedComments, themeID: themeID)
        }
    }

    /// The stacked thinking pill's popover, as the action row's pill shows
    /// its own. The picker closes itself on a choice.
    private func presentStackedThinkingPicker() {
        let picker = ComposerThinkingPickerController(
            levels: model.supportedThinkingLevels,
            selected: model.thinkingLevel,
            colors: colors,
            onSelect: { [weak model] in model?.selectThinkingLevel($0) },
            onSaveDefault: nil
        )
        Router.present(
            picker,
            presentation: .popover.arrowDirections(.down).keepsPopoverInCompactWidth(),
            from: self,
            sourceView: stackedThinkingPill
        )
    }

    // MARK: - Building

    private func buildErrorRow(_ row: UIView, label: UILabel) {
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
        ])
        row.isHidden = true
        stack.addArrangedSubview(row)
    }

    /// The screen's own error above the composer (Custom Themes and
    /// Schedules show a failed list load there).
    func setScreenError(_ message: String?, identifier: String) {
        screenErrorLabel.accessibilityIdentifier = identifier
        guard screenError != message else { return }
        screenError = message
        setNeedsUpdateProperties()
    }

    /// A warning symbol and the message in the theme's red caption.
    static func errorText(_ message: String, colors: ComposerThemeColors) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let text = NSMutableAttributedString()
        if let symbol = UIImage(
            systemName: "exclamationmark.triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(font: font)
        )?.withTintColor(colors.red, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: message))
        text.addAttributes([.font: font, .foregroundColor: colors.red], range: NSRange(location: 0, length: text.length))
        return text
    }

    private func buildStackedPanel() {
        stackedWorkspacePill.accessibilityIdentifier = "\(model.identifierPrefix).workspacePicker"
        stackedWorkspacePill.showsMenuAsPrimaryAction = true
        stackedModelPill.accessibilityIdentifier = "session.toolbar.model"
        stackedModelPill.accessibilityLabel = "Model"
        stackedModelPill.addAction(UIAction { [weak self] _ in self?.model.showModelPicker = true }, for: .primaryActionTriggered)
        stackedThinkingPill.accessibilityIdentifier = "session.toolbar.thinking"
        stackedThinkingPill.accessibilityLabel = "Thinking level"
        stackedThinkingPill.addAction(UIAction { [weak self] _ in self?.presentStackedThinkingPicker() }, for: .primaryActionTriggered)

        let workspaceRow = UIStackView(arrangedSubviews: [stackedWorkspacePill, UIView()])
        workspaceRow.axis = .horizontal
        let toolbar = UIStackView(arrangedSubviews: [stackedModelPill, stackedThinkingPill, UIView()])
        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.spacing = 6
        stackedPanel.addArrangedSubview(workspaceRow)
        stackedPanel.addArrangedSubview(toolbar)
        stackedPanel.axis = .vertical
        stackedPanel.alignment = .fill
        stackedPanel.spacing = 6
        stackedPanel.isLayoutMarginsRelativeArrangement = true
        stackedPanel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16)
        stackedPanel.isHidden = true
        for pill in [stackedWorkspacePill, stackedModelPill, stackedThinkingPill] {
            pill.heightAnchor.constraint(greaterThanOrEqualToConstant: ComposerInputMetrics.controlDiameter).isActive = true
        }
        stack.addArrangedSubview(stackedPanel)
    }

    private func updateStackedPanel(colors: ComposerThemeColors) {
        let stacks = stacksActionControls
        stackedPanel.isHidden = !stacks
        guard stacks else { return }
        let workspace = model.selectedWorkspace
        stackedWorkspacePill.apply(
            title: workspace?.name ?? "Workspace",
            icon: workspaceIcon(colors: colors) ?? UIImage(systemName: "folder"),
            tint: colors.fg,
            showsChevron: true,
            colors: colors
        )
        stackedWorkspacePill.menu = workspaceMenu()
        stackedWorkspacePill.accessibilityLabel = workspace.map { "Workspace picker, current workspace \($0.name)" }
            ?? "Workspace picker"

        let presentation = model.modelPresentation
        let modelTitle = shortModelName(model.effectiveModelId ?? presentation.pillText)
        stackedModelPill.apply(
            title: modelTitle,
            icon: presentation.pillProvider.map { ComposerProviderIconRenderer.image(provider: $0, size: 11, colors: colors) },
            tint: colors.fg,
            showsChevron: true,
            colors: colors
        )
        stackedModelPill.accessibilityValue = modelTitle

        let level = model.thinkingLevel
        stackedThinkingPill.apply(
            title: level.compactTitle,
            icon: UIImage(systemName: "sparkle"),
            tint: thinkingTint,
            showsChevron: true,
            colors: colors
        )
        stackedThinkingPill.accessibilityValue = level.displayTitle
    }

    // MARK: - Workspace

    func workspaceIcon(colors: ComposerThemeColors) -> UIImage? {
        model.selectedWorkspace.map {
            WorkspaceRuntimeIconRenderer.render(workspace: $0, size: 12, frameSize: 16, colors: colors)
        }
    }

    /// The server's workspaces, the selected one checked.
    func workspaceMenu() -> UIMenu {
        let selectedId = model.selectedWorkspace?.id
        let prefix = model.identifierPrefix
        return UIMenu(children: model.workspaces.map { workspace in
            UIAction(
                title: workspace.name,
                image: UIImage(systemName: workspace.id == selectedId ? "checkmark" : "folder"),
                identifier: UIAction.Identifier("\(prefix).workspace.\(workspace.id)")
            ) { [weak self] _ in
                self?.model.selectWorkspace(workspace)
            }
        })
    }
}
