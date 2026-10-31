import UIKit

/// One provider sign-in attempt as a sheet: where it stands, the sign-in
/// link, a prompt or authorization code to answer, the server's progress and
/// errors, and Cancel Sign-In (Done once it settles). Model Providers owns the
/// attempt: closing the sheet does not cancel it.
///
/// A `ListScreenController`: the base owns the list, the section headings, and
/// the rows redrawn only when their inputs change, so typing keeps the answer
/// field's selection.
@MainActor
final class ProviderSignInViewController: ListScreenController<ProviderSignInViewController.Section, ProviderSignInViewController.Item> {
    enum Section: Hashable, Sendable {
        case summary, signIn, prompt, manualCode, progress, error, notices, finish
    }

    enum Item: Hashable, Sendable {
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
        super.init(
            title: "Sign in to \(attempt.providerName)",
            listIdentifier: "server.modelProviders.signIn",
            headers: true, dismissesKeyboardOnDrag: true
        )
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    override func updateProperties() {
        // A cancel in flight must finish before the sheet can go.
        isModalInPresentation = attempt.isCancelling
        super.updateProperties()
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

    override func sections() -> [ListSection<Section, Item>] {
        let flow = attempt.flow
        var summary: [Item] = [.value("Provider"), .value("Status")]
        if attempt.serverId != visibleServerId() { summary.append(.value("Server")) }
        var sections: [ListSection<Section, Item>] = [ListSection(.summary, items: summary)]

        if let auth = flow.auth {
            var items: [Item] = [ProviderAuthFlowPresentation.signInURL(auth.url) == nil ? .linkUnavailable : .openLink]
            if auth.instructions?.isEmpty == false { items.append(.instructions) }
            sections.append(ListSection(.signIn, header: "Sign In", items: items))
        }
        if flow.status == .awaitingPrompt, let prompt = flow.prompt {
            let items: [Item]
            if let options = prompt.options, !options.isEmpty {
                items = Self.unique(options.map(\.id)).map(Item.option)
            } else {
                items = [.input, .submit]
            }
            sections.append(ListSection(.prompt, header: prompt.message, items: items))
        }
        if flow.status == .awaitingManualCode {
            sections.append(ListSection(.manualCode, header: "Authorization Code", items: [.input, .submit]))
        }
        if flow.lastProgress?.isEmpty == false {
            sections.append(ListSection(.progress, header: "Progress", items: [.progress]))
        }
        if flow.error?.isEmpty == false {
            sections.append(ListSection(.error, header: "Error", items: [.error]))
        }
        var notices: [Item] = []
        if attempt.isGone { notices.append(.gone) }
        if attempt.refreshError != nil, !attempt.isSettled { notices.append(.refreshError) }
        if attempt.actionError?.isEmpty == false { notices.append(.actionError) }
        if !notices.isEmpty {
            sections.append(ListSection(.notices, items: notices))
        }
        sections.append(ListSection(.finish, items: [.finish]))
        return sections
    }

    /// The sign-in link, the question, the code, the progress, and the error
    /// carry headings; the summary and the notices do not.
    override func showsHeader(for section: Section) -> Bool {
        switch section {
        case .signIn, .prompt, .manualCode, .progress, .error: true
        case .summary, .notices, .finish: false
        }
    }

    /// Only the Submit row changes while typing, so the field keeps its
    /// selection and the keyboard.
    override func inputs(of item: Item) -> AnyHashable {
        let flow = attempt.flow
        return switch item {
        case .value: AnyHashable([AnyHashable(statusText), AnyHashable(attempt.serverName), AnyHashable(attempt.providerName)])
        case .openLink, .linkUnavailable: AnyHashable([AnyHashable(flow.auth?.url)])
        case .instructions: AnyHashable([AnyHashable(flow.auth?.instructions)])
        case .option: AnyHashable([AnyHashable(isBusy), AnyHashable(flow.prompt?.options?.map(\.label))])
        case .input: AnyHashable([AnyHashable(isBusy), AnyHashable(flow.status.rawValue), AnyHashable(flow.prompt?.placeholder)])
        case .submit: AnyHashable([AnyHashable(canSubmit)])
        case .progress: AnyHashable([AnyHashable(flow.lastProgress)])
        case .error: AnyHashable([AnyHashable(flow.error)])
        case .refreshError: AnyHashable([AnyHashable(attempt.refreshError)])
        case .actionError: AnyHashable([AnyHashable(attempt.actionError)])
        case .finish: AnyHashable([AnyHashable(attempt.isSettled), AnyHashable(attempt.isCancelling)])
        case .gone: AnyHashable(0)
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Rows

    private lazy var field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
        self?.configureInput(cell)
    }

    // A registration must exist before the first row is dequeued.
    override func prepareRegistrations() {
        _ = field
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        item == .input
            ? collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            : cardCell(for: item, at: indexPath)
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

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        let flow = attempt.flow
        switch item {
        case .value(let title):
            ListScreen.staticRow(cell, identifier: "server.modelProviders.signIn.\(title.lowercased())")
            let value = switch title {
            case "Provider": attempt.providerName
            case "Status": statusText
            default: attempt.serverName
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.valueRow(title, value, palette: palette, style: .body)
            }
        case .openLink:
            ListScreen.buttonRow(cell, identifier: "server.modelProviders.signIn.open", label: "Open sign-in page on iPhone") { [weak self] in
                self?.openSignInPage()
            }
            cell.contentConfiguration = Self.actionContent("Open sign-in page on iPhone", systemImage: "safari", color: UIColor(palette.blue))
        case .input:
            // The text field row (`configureInput`).
            break
        case .linkUnavailable:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label("This sign-in link cannot be opened on iPhone.", style: .footnote, color: UIColor(palette.comment))
            }
        case .instructions:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.selectableText(flow.auth?.instructions ?? "", style: .footnote, color: UIColor(palette.fg))
            }
        case .option(let id):
            let label = flow.prompt?.options?.first { $0.id == id }?.label ?? id
            ListScreen.buttonRow(cell, identifier: "server.modelProviders.signIn.option.\(id)", label: label, enabled: !isBusy) { [weak self] in
                guard let attempt = self?.attempt else { return }
                Task { await attempt.submitPromptResponse(id) }
            }
            cell.contentConfiguration = Self.actionContent(label, color: UIColor(isBusy ? palette.comment : palette.blue))
        case .submit:
            let enabled = canSubmit
            ListScreen.buttonRow(cell, identifier: "server.modelProviders.signIn.submit", label: "Submit", enabled: enabled) { [weak self] in
                self?.submit()
            }
            cell.contentConfiguration = Self.actionContent("Submit", color: UIColor(enabled ? palette.blue : palette.comment))
        case .progress:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.selectableText(flow.lastProgress ?? "", style: .footnote, color: UIColor(palette.fg))
            }
        case .error:
            ListScreen.staticRow(cell, identifier: "server.modelProviders.signIn.error")
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.selectableText(flow.error ?? "", style: .body, color: UIColor(palette.red))
            }
        case .gone:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(
                    "The server no longer has this sign-in attempt. It may have expired or the server restarted.",
                    style: .footnote,
                    color: UIColor(palette.fg)
                )
            }
        case .refreshError:
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(self.attempt.refreshError, style: .footnote, color: UIColor(palette.orange))
            }
        case .actionError:
            ListScreen.staticRow(cell, identifier: "server.modelProviders.signIn.actionError")
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(self.attempt.actionError, style: .body, color: UIColor(palette.red))
            }
        case .finish:
            if attempt.isSettled {
                ListScreen.buttonRow(cell, identifier: "server.modelProviders.signIn.done", label: "Done") { [weak self] in
                    self?.onDone()
                }
                cell.contentConfiguration = Self.actionContent("Done", color: UIColor(palette.blue))
            } else {
                let cancelling = attempt.isCancelling
                let title = cancelling ? "Cancelling…" : "Cancel Sign-In"
                ListScreen.buttonRow(cell, identifier: "server.modelProviders.signIn.cancel", label: title, enabled: !cancelling) { [weak self] in
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
final class ProviderAPIKeyViewController: ListScreenController<ProviderAPIKeyViewController.Section, ProviderAPIKeyViewController.Item> {
    enum Section: Hashable, Sendable { case provider, key }
    enum Item: Hashable, Sendable { case provider, key, error }

    let provider: ProviderAuthProviderStatus
    private let root: AppRootEnvironment
    private let onSave: (String) -> Void
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
        super.init(
            title: provider.credentialType == .apiKey ? "Replace API Key" : "Set API Key",
            listIdentifier: "server.modelProviders.apiKey",
            headers: true, footers: true, dismissesKeyboardOnDrag: true
        )
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        })
        saveItem.primaryAction = UIAction(title: "Save") { [weak self] _ in self?.save() }
        saveItem.style = .done
        saveItem.accessibilityIdentifier = "server.modelProviders.apiKey.save"
    }

    override func updateProperties() {
        saveItem.isEnabled = !trimmedDraft.isEmpty
        let trailing = isSaving ? savingItem : saveItem
        if navigationItem.rightBarButtonItem !== trailing {
            navigationItem.rightBarButtonItem = trailing
        }
        isModalInPresentation = isSaving || !draft.isEmpty
        super.updateProperties()
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

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(.provider, header: "Provider", items: [.provider]),
            ListSection(
                .key,
                header: "API Key",
                footer: "The key is sent directly to your server over the existing Oppi connection and saved there.",
                items: errorMessage == nil ? [.key] : [.key, .error]
            ),
        ]
    }

    /// Only the field row and the failure line change as they are typed or
    /// saved; the page's own symbol row does not.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .provider: AnyHashable([AnyHashable(provider.id), AnyHashable(provider.name)])
        case .error: AnyHashable([AnyHashable(errorMessage)])
        // Reconfiguring the field would drop its selection.
        case .key: AnyHashable(0)
        }
    }

    // MARK: - Rows

    private lazy var field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
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

    // A registration must exist before the first row is dequeued.
    override func prepareRegistrations() {
        _ = field
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        item == .key
            ? collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            : cardCell(for: item, at: indexPath)
    }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ListScreen.staticRow(cell)
        if item == .provider {
            var content = UIListContentConfiguration.cell()
            content.text = provider.name
            content.textProperties.color = UIColor(palette.fg)
            content.image = EntityIcon.image(.provider(provider.id), size: 18)
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
}
