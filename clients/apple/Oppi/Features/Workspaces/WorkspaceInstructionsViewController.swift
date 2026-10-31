import UIKit

/// Workspace instructions editor. The text is a draft: Save writes it, back
/// discards it. A caption says what the text does, the editor fills the page,
/// and a character count sits above the keyboard. Clear sits in the bar's
/// overflow menu.
///
/// Pushed from Workspace Settings, which already made the workspace's server
/// the active one and bound `model` to it.
@MainActor
final class WorkspaceInstructionsViewController: UIViewController, UITextViewDelegate {
    private let model: WorkspaceSettingsModel
    private let root: AppRootEnvironment

    private let captionLabel = UILabel()
    private let card = UIView()
    private let textView = UITextView()
    private let errorLabel = UILabel()
    private let countBackground = UIView()
    private let countLabel = UILabel()

    private var text: String {
        didSet { setNeedsUpdateProperties() }
    }
    private var isSaving = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    /// A save that finishes after Back must not pop whatever is on top now.
    private var isOnScreen = false

    private lazy var saveItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.save() })
        item.accessibilityLabel = String(localized: "Save")
        item.accessibilityIdentifier = "workspace.edit.instructions.save"
        return item
    }()

    init(model: WorkspaceSettingsModel, root: AppRootEnvironment) {
        self.model = model
        self.root = root
        text = model.workspace.systemPrompt ?? ""
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = String(localized: "Instructions")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self.map { [$0.clearAction] } ?? [])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var savedText: String { model.workspace.systemPrompt ?? "" }
    private var isDirty: Bool { text != savedText }

    /// Empties the editor; Save writes it.
    private var clearAction: UIAction {
        UIAction(
            title: String(localized: "Clear"),
            image: UIImage(systemName: "trash"),
            attributes: text.isEmpty ? [.destructive, .disabled] : [.destructive]
        ) { [weak self] _ in
            guard let self else { return }
            textView.text = ""
            text = ""
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        captionLabel.font = .scaled(.caption1)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.numberOfLines = 0
        captionLabel.text = String(localized: "Added after Pi\u{2019}s base prompt for every session in this workspace.")

        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        textView.backgroundColor = .clear
        textView.font = .scaledMonospaced(.body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .default
        textView.writingToolsBehavior = .complete
        textView.keyboardDismissMode = .interactive
        textView.text = text
        textView.delegate = self
        textView.accessibilityIdentifier = "workspace.edit.instructions.editor"
        textView.accessibilityLabel = title

        errorLabel.font = .scaled(.footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        errorLabel.accessibilityIdentifier = "workspace.edit.instructions.error"

        countLabel.font = .scaledMonospaced(.caption1)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textAlignment = .right

        // The error, when there is one, sits over the count; a hidden label
        // takes no room in the stack.
        let bottom = UIStackView(arrangedSubviews: [errorLabel, countLabel])
        bottom.axis = .vertical
        bottom.spacing = 8
        for view in [captionLabel, card, bottom, countBackground, textView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        card.addSubview(textView)
        for view in [countBackground, captionLabel, card, bottom] { self.view.addSubview(view) }
        view.keyboardLayoutGuide.usesBottomSafeArea = true
        let side: CGFloat = 16
        NSLayoutConstraint.activate([
            captionLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            captionLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: side),
            captionLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -side),
            card.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: captionLabel.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: captionLabel.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: captionLabel.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: captionLabel.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            countBackground.topAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            countBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            countBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            countBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.topAnchor.constraint(equalTo: card.topAnchor),
            textView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.setNeedsUpdateProperties()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil)
        setNeedsUpdateProperties()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        let style = SettingsStyle.current
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        view.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        view.backgroundColor = style.page
        captionLabel.textColor = style.value
        card.backgroundColor = style.card
        card.layer.borderColor = palette.ui.comment.withAlphaComponent(0.25).cgColor
        textView.textColor = style.title
        textView.tintColor = style.accent
        errorLabel.text = error
        errorLabel.textColor = palette.ui.red
        errorLabel.isHidden = error == nil
        countLabel.text = String(localized: "\(text.count) chars")
        countLabel.textColor = style.value
        countBackground.backgroundColor = style.card
        saveItem.isEnabled = isDirty && !isSaving
        ListScreen.setBarItems(trailing: [saveItem], leading: [], on: navigationItem)
    }

    func textViewDidChange(_ textView: UITextView) {
        text = textView.text
    }

    // MARK: - Save

    private func save() {
        guard isDirty, !isSaving else { return }
        isSaving = true
        error = nil
        view.endEditing(true)
        let text = text
        let model = model
        Task { [weak self] in
            let outcome = await model.saveInstructions(text)
            guard let self else { return }
            isSaving = false
            switch outcome {
            case .saved:
                if isOnScreen { Router.finish(self) }
            case .failed(let message):
                error = message
            case .superseded:
                break
            }
        }
    }
}
