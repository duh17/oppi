import UIKit

/// One provider sign-in attempt as a sheet: where it stands, the sign-in
/// link, a prompt or authorization code to answer, the server's progress and
/// errors, and Cancel Sign-In (Done once it settles). Model Providers owns the
/// attempt: closing the sheet does not cancel it.
@MainActor
final class ProviderSignInViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable {
        case summary, signIn, prompt, manualCode, progress, error, notices, finish
    }

    private enum Item: Hashable {
        case value(String)
        case openLink
        case linkUnavailable
        case instructions
        case option(String)
        case input
        case submit
        case progress
        case error
        case gone
        case refreshError
        case actionError
        case finish
    }

    let attempt: ProviderAuthFlowAttempt
    private let root: AppRootEnvironment
    /// The visible server's id: another server's attempt names its server.
    private let visibleServerId: () -> String?
    private let onDone: () -> Void
    private let onCancel: () -> Void
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var changedRows = ChangedRows<Item>()

    init(
        attempt: ProviderAuthFlowAttempt,
        root: AppRootEnvironment,
        visibleServerId: @escaping () -> String?,
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.attempt = attempt
        self.root = root
        self.visibleServerId = visibleServerId
        self.onDone = onDone
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
        title = "Sign in to \(attempt.providerName)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "server.modelProviders.signIn"
        ModelProvidersList.pinReadable(collectionView, in: view, maxWidth: IPadReadableContentWidth.form)
        installDataSource()
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        // A cancel in flight must finish before the sheet can go.
        isModalInPresentation = attempt.isCancelling
        applySnapshot()
    }

    // MARK: - List

    private var statusText: String {
        attempt.isGone ? "No longer on the server" : ProviderAuthFlowPresentation.statusText(attempt.flow.status)
    }

    private var isBusy: Bool { attempt.isCancelling || attempt.isSubmitting }

    private var canSubmit: Bool {
        guard !isBusy else { return false }
        switch attempt.flow.status {
        case .awaitingPrompt:
            return !attempt.input.isEmpty || attempt.flow.prompt?.allowEmpty == true
        case .awaitingManualCode:
            return !attempt.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return false
        }
    }

    private func applySnapshot() {
        guard let dataSource else { return }
        let flow = attempt.flow
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.summary])
        var summary: [Item] = [.value("Provider"), .value("Status")]
        if attempt.serverId != visibleServerId() { summary.append(.value("Server")) }
        snapshot.appendItems(summary, toSection: .summary)

        if let auth = flow.auth {
            snapshot.appendSections([.signIn])
            var items: [Item] = [ProviderAuthFlowPresentation.signInURL(auth.url) == nil ? .linkUnavailable : .openLink]
            if auth.instructions?.isEmpty == false { items.append(.instructions) }
            snapshot.appendItems(items, toSection: .signIn)
        }
        if flow.status == .awaitingPrompt, let prompt = flow.prompt {
            snapshot.appendSections([.prompt])
            if let options = prompt.options, !options.isEmpty {
                snapshot.appendItems(Self.unique(options.map(\.id)).map(Item.option), toSection: .prompt)
            } else {
                snapshot.appendItems([.input, .submit], toSection: .prompt)
            }
        }
        if flow.status == .awaitingManualCode {
            snapshot.appendSections([.manualCode])
            snapshot.appendItems([.input, .submit], toSection: .manualCode)
        }
        if flow.lastProgress?.isEmpty == false {
            snapshot.appendSections([.progress])
            snapshot.appendItems([.progress], toSection: .progress)
        }
        if flow.error?.isEmpty == false {
            snapshot.appendSections([.error])
            snapshot.appendItems([.error], toSection: .error)
        }
        var notices: [Item] = []
        if attempt.isGone { notices.append(.gone) }
        if attempt.refreshError != nil, !attempt.isSettled { notices.append(.refreshError) }
        if attempt.actionError?.isEmpty == false { notices.append(.actionError) }
        if !notices.isEmpty {
            snapshot.appendSections([.notices])
            snapshot.appendItems(notices, toSection: .notices)
        }
        snapshot.appendSections([.finish])
        snapshot.appendItems([.finish], toSection: .finish)

        // Only the rows whose inputs changed: a reconfigured field would drop
        // its selection, and typing changes only the Submit row.
        let current = dataSource.snapshot()
        let themeID = root.themeStore.activeThemeID
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { AnyHashable([AnyHashable(themeID)] + rowInputs($0)) }
        snapshot.reconfigureItems(changed.filter { current.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
        // The prompt's question is its header; a chained prompt replaces it in
        // place, and supplementary views do not reconfigure.
        if let section = snapshot.indexOfSection(.prompt),
           let header = collectionView.supplementaryView(
               forElementKind: UICollectionView.elementKindSectionHeader,
               at: IndexPath(item: 0, section: section)
           ) as? UICollectionViewListCell,
           var content = header.contentConfiguration as? UIListContentConfiguration,
           content.text != flow.prompt?.message {
            content.text = flow.prompt?.message
            header.contentConfiguration = content
        }
    }

    private func rowInputs(_ item: Item) -> [AnyHashable] {
        let flow = attempt.flow
        return switch item {
        case .value: [statusText, attempt.serverName, attempt.providerName]
        case .openLink, .linkUnavailable: [flow.auth?.url]
        case .instructions: [flow.auth?.instructions]
        case .option: [isBusy, flow.prompt?.options?.map(\.label)]
        case .input: [isBusy, flow.status.rawValue, flow.prompt?.placeholder]
        case .submit: [canSubmit]
        case .progress: [flow.lastProgress]
        case .error: [flow.error]
        case .gone: []
        case .refreshError: [attempt.refreshError]
        case .actionError: [attempt.actionError]
        case .finish: [attempt.isSettled, attempt.isCancelling]
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
            self?.configureInput(cell)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = switch self?.dataSource?.sectionIdentifier(for: indexPath.section) {
            case .signIn: "Sign In"
            case .prompt: self?.attempt.flow.prompt?.message
            case .manualCode: "Authorization Code"
            case .progress: "Progress"
            case .error: "Error"
            default: nil
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            if item == .input {
                return collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            }
            return collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func configureInput(_ cell: SSHTerminalTextFieldCell) {
        let isPrompt = attempt.flow.status == .awaitingPrompt
        let palette = palette
        cell.configure(
            text: attempt.input,
            placeholder: isPrompt
                ? attempt.flow.prompt?.placeholder ?? "Enter response"
                : "Paste authorization code or redirect URL",
            identifier: "server.modelProviders.signIn.input",
            keyboard: isPrompt ? .default : .URL,
            textColor: UIColor(palette.fg),
            enabled: !isBusy,
            returnKey: .go,
            onReturn: { [weak self] in self?.submit() },
            onChange: { [weak self] text in self?.attempt.input = text }
        )
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        let flow = attempt.flow
        ControlScreenList.background(cell, grouped: true, palette: palette)
        switch item {
        case .value(let title):
            ControlScreenList.staticRow(cell, identifier: "server.modelProviders.signIn.\(title.lowercased())")
            let value = switch title {
            case "Provider": attempt.providerName
            case "Status": statusText
            default: attempt.serverName
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.valueRow(title, value, palette: palette, style: .body)
            }
        case .openLink:
            ControlScreenList.buttonRow(cell, identifier: "server.modelProviders.signIn.open", label: "Open sign-in page on iPhone") { [weak self] in
                self?.openSignInPage()
            }
            cell.contentConfiguration = Self.actionContent("Open sign-in page on iPhone", systemImage: "safari", color: UIColor(palette.blue))
        case .input:
            // The text field row (`configureInput`).
            break
        case .linkUnavailable:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label("This sign-in link cannot be opened on iPhone.", style: .footnote, color: UIColor(palette.comment))
            }
        case .instructions:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.selectableText(flow.auth?.instructions ?? "", style: .footnote, color: UIColor(palette.fg))
            }
        case .option(let id):
            let label = flow.prompt?.options?.first { $0.id == id }?.label ?? id
            ControlScreenList.buttonRow(cell, identifier: "server.modelProviders.signIn.option.\(id)", label: label, enabled: !isBusy) { [weak self] in
                guard let attempt = self?.attempt else { return }
                Task { await attempt.submitPromptResponse(id) }
            }
            cell.contentConfiguration = Self.actionContent(label, color: UIColor(isBusy ? palette.comment : palette.blue))
        case .submit:
            let enabled = canSubmit
            ControlScreenList.buttonRow(cell, identifier: "server.modelProviders.signIn.submit", label: "Submit", enabled: enabled) { [weak self] in
                self?.submit()
            }
            cell.contentConfiguration = Self.actionContent("Submit", color: UIColor(enabled ? palette.blue : palette.comment))
        case .progress:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.selectableText(flow.lastProgress ?? "", style: .footnote, color: UIColor(palette.fg))
            }
        case .error:
            ControlScreenList.staticRow(cell, identifier: "server.modelProviders.signIn.error")
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.selectableText(flow.error ?? "", style: .body, color: UIColor(palette.red))
            }
        case .gone:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(
                    "The server no longer has this sign-in attempt. It may have expired or the server restarted.",
                    style: .footnote,
                    color: UIColor(palette.fg)
                )
            }
        case .refreshError:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(self.attempt.refreshError, style: .footnote, color: UIColor(palette.orange))
            }
        case .actionError:
            ControlScreenList.staticRow(cell, identifier: "server.modelProviders.signIn.actionError")
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(self.attempt.actionError, style: .body, color: UIColor(palette.red))
            }
        case .finish:
            if attempt.isSettled {
                ControlScreenList.buttonRow(cell, identifier: "server.modelProviders.signIn.done", label: "Done") { [weak self] in
                    self?.onDone()
                }
                cell.contentConfiguration = Self.actionContent("Done", color: UIColor(palette.blue))
            } else {
                let cancelling = attempt.isCancelling
                let title = cancelling ? "Cancelling…" : "Cancel Sign-In"
                ControlScreenList.buttonRow(cell, identifier: "server.modelProviders.signIn.cancel", label: title, enabled: !cancelling) { [weak self] in
                    self?.onCancel()
                }
                cell.contentConfiguration = Self.actionContent(title, color: UIColor(cancelling ? palette.comment : palette.red))
                if cancelling {
                    let spinner = UIActivityIndicatorView(style: .medium)
                    spinner.startAnimating()
                    cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .leading()))]
                }
            }
        }
    }

    private static func actionContent(_ title: String, systemImage: String? = nil, color: UIColor) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.color = color
        if let systemImage {
            content.image = UIImage(systemName: systemImage)
            content.imageProperties.tintColor = color
        }
        return content
    }

    // MARK: - Actions

    private func submit() {
        guard canSubmit else { return }
        let attempt = attempt
        view.endEditing(true)
        if attempt.flow.status == .awaitingPrompt {
            let value = attempt.input
            Task { await attempt.submitPromptResponse(value) }
        } else {
            Task { await attempt.submitManualCode() }
        }
    }

    private func openSignInPage() {
        guard let auth = attempt.flow.auth, let url = ProviderAuthFlowPresentation.signInURL(auth.url) else { return }
        root.opener.open(.webLink(url))
    }
}

/// Paste or replace a provider's API key. The key goes to the server over the
/// Oppi connection; Model Providers saves it and closes the sheet on success,
/// or shows the failure here.
@MainActor
final class ProviderAPIKeyViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable { case provider, key }
    private enum Item: Hashable { case provider, key, error }

    let provider: ProviderAuthProviderStatus
    private let root: AppRootEnvironment
    private let onSave: (String) -> Void
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private let saveItem = UIBarButtonItem()
    private let savingItem: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return UIBarButtonItem(customView: spinner)
    }()

    private var draft = "" {
        didSet { setNeedsUpdateProperties() }
    }

    /// A save is running: Save waits, and the sheet stays.
    var isSaving = false {
        didSet { setNeedsUpdateProperties() }
    }

    /// The last save's failure.
    var errorMessage: String? {
        didSet { setNeedsUpdateProperties() }
    }

    init(provider: ProviderAuthProviderStatus, root: AppRootEnvironment, onSave: @escaping (String) -> Void) {
        self.provider = provider
        self.root = root
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
        title = provider.credentialType == .apiKey ? "Replace API Key" : "Set API Key"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true, footers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "server.modelProviders.apiKey"
        ModelProvidersList.pinReadable(collectionView, in: view, maxWidth: IPadReadableContentWidth.form)
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        })
        saveItem.primaryAction = UIAction(title: "Save") { [weak self] _ in self?.save() }
        saveItem.style = .done
        saveItem.accessibilityIdentifier = "server.modelProviders.apiKey.save"
        installDataSource()
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        saveItem.isEnabled = !trimmedDraft.isEmpty
        let trailing = isSaving ? savingItem : saveItem
        if navigationItem.rightBarButtonItem !== trailing {
            navigationItem.rightBarButtonItem = trailing
        }
        isModalInPresentation = isSaving || !draft.isEmpty
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.provider, .key])
        snapshot.appendItems([.provider], toSection: .provider)
        snapshot.appendItems(errorMessage == nil ? [.key] : [.key, .error], toSection: .key)
        if dataSource.snapshot().indexOfItem(.error) != nil, errorMessage != nil {
            snapshot.reconfigureItems([.error])
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let field = collectionView.visibleCells.lazy.compactMap { ($0 as? SSHTerminalTextFieldCell)?.textField }.first
        field?.becomeFirstResponder()
    }

    private func save() {
        let key = trimmedDraft
        guard !key.isEmpty, !isSaving else { return }
        view.endEditing(true)
        onSave(key)
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            let palette = palette
            ControlScreenList.background(cell, grouped: true, palette: palette)
            ControlScreenList.staticRow(cell)
            if item == .provider {
                var content = UIListContentConfiguration.cell()
                content.text = provider.name
                content.textProperties.color = UIColor(palette.fg)
                content.image = ComposerProviderIconRenderer.image(
                    provider: provider.id,
                    size: 18,
                    colors: SessionRowStyle.for(root.themeStore.activeThemeID).colors
                )
                content.imageProperties.maximumSize = CGSize(width: 18, height: 18)
                cell.contentConfiguration = content
            } else {
                cell.accessibilityIdentifier = "server.modelProviders.apiKey.error"
                let message = errorMessage
                cell.contentConfiguration = ControlViewContent {
                    ControlRowViews.symbolLabel(
                        message ?? "",
                        systemImage: "exclamationmark.triangle.fill",
                        style: .footnote,
                        color: UIColor(palette.red)
                    )
                }
            }
        }
        let field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(
                text: draft,
                placeholder: "Paste API key",
                identifier: "server.modelProviders.apiKey.field",
                isSecure: true,
                textColor: UIColor(palette.fg),
                returnKey: .done,
                onReturn: { [weak self] in self?.save() },
                onChange: { [weak self] text in self?.draft = text }
            )
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource?.sectionIdentifier(for: indexPath.section) == .key ? "API Key" : "Provider"
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource?.sectionIdentifier(for: indexPath.section) == .key
                ? "The key is sent directly to your server over the existing Oppi connection and saved there."
                : nil
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            item == .key
                ? collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
                : collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }
}
