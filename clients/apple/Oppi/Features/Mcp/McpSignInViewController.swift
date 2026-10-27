import UIKit

/// One MCP server's OAuth sign-in as a sheet: where it stands, the sign-in
/// link, the callback URL to paste, the host's errors, and Cancel Sign-In
/// (Done once it settles). `McpSignInOwner` owns the attempt: closing the
/// sheet never cancels it.
@MainActor
final class McpSignInViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable {
        case summary, finishing, signIn, preparing, notices, finish
    }

    private enum Item: Hashable {
        case host, status
        case finishing
        case openLink, callback, submit
        case preparing
        case flowError, actionError, refreshError, gone
        case finish
    }

    let attempt: ProviderAuthFlowAttempt
    private let owner: McpSignInOwner
    private let root: AppRootEnvironment
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var changedRows = ChangedRows<Item>()
    /// Above the keyboard while the callback field has it.
    private lazy var keyboardBar: UIToolbar = {
        let bar = UIToolbar()
        bar.sizeToFit()
        keyboardSubmit.title = "Submit Callback"
        keyboardSubmit.primaryAction = UIAction(title: "Submit Callback") { [weak self] _ in self?.submit() }
        keyboardSubmit.accessibilityIdentifier = "mcp.auth.submit.keyboard"
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), keyboardSubmit]
        return bar
    }()
    private let keyboardSubmit = UIBarButtonItem()

    init(attempt: ProviderAuthFlowAttempt, owner: McpSignInOwner, root: AppRootEnvironment) {
        self.attempt = attempt
        self.owner = owner
        self.root = root
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = "Sign In"
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction(title: "Close") { [weak owner] _ in
            owner?.showingSheet = false
        })
        close.accessibilityLabel = "Close"
        close.accessibilityIdentifier = "mcp.auth.close"
        navigationItem.leftBarButtonItem = close
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true, footers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "mcp.auth.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        // A cancel in flight must finish before the sheet can go.
        isModalInPresentation = attempt.isCancelling
        keyboardSubmit.isEnabled = owner.canSubmitCallback
        applySnapshot()
    }

    // MARK: - List

    private func applySnapshot() {
        guard let dataSource else { return }
        let flow = attempt.flow
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.summary])
        snapshot.appendItems([.host, .status], toSection: .summary)
        if !attempt.isSettled {
            if owner.callbackAccepted || attempt.isSubmitting {
                snapshot.appendSections([.finishing])
                snapshot.appendItems([.finishing], toSection: .finishing)
            } else if let auth = flow.auth {
                snapshot.appendSections([.signIn])
                var items: [Item] = []
                if ProviderAuthFlowPresentation.signInURL(auth.url) != nil { items.append(.openLink) }
                items += [.callback, .submit]
                snapshot.appendItems(items, toSection: .signIn)
            } else {
                snapshot.appendSections([.preparing])
                snapshot.appendItems([.preparing], toSection: .preparing)
            }
        }
        var notices: [Item] = []
        if flow.error != nil { notices.append(.flowError) }
        if attempt.actionError != nil { notices.append(.actionError) }
        if attempt.refreshError != nil { notices.append(.refreshError) }
        if attempt.isGone { notices.append(.gone) }
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
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) {
            AnyHashable([AnyHashable(themeID)] + rowInputs($0))
        }
        snapshot.reconfigureItems(changed.filter { current.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func rowInputs(_ item: Item) -> [AnyHashable] {
        switch item {
        case .host: [attempt.serverName]
        case .status: [attempt.flow.status.rawValue]
        case .openLink: [attempt.flow.auth?.url]
        case .submit: [owner.canSubmitCallback]
        case .flowError: [attempt.flow.error]
        case .actionError: [attempt.actionError]
        case .refreshError: [attempt.refreshError]
        case .finish: [attempt.isSettled, attempt.isCancelling]
        case .finishing, .callback, .preparing, .gone: []
        }
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
            self?.configureCallback(cell)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = switch self?.dataSource?.sectionIdentifier(for: indexPath.section) {
            case .summary: self?.attempt.providerName
            case .signIn: "Sign In"
            default: nil
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource?.sectionIdentifier(for: indexPath.section) == .signIn
                ? "After approval, the browser may fail to load 127.0.0.1. Copy its full callback URL and paste it below. You can also complete sign-in using a browser on the host."
                : nil
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            item == .callback
                ? collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
                : collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configureCallback(_ cell: SSHTerminalTextFieldCell) {
        let attempt = attempt
        cell.configure(
            text: attempt.input,
            placeholder: "Paste full callback URL",
            identifier: "mcp.auth.callback",
            keyboard: .URL,
            textColor: UIColor(palette.fg),
            returnKey: .go,
            onReturn: { [weak self] in self?.submit() },
            onChange: { attempt.input = $0 }
        )
        cell.textField.inputAccessoryView = keyboardBar
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        switch item {
        case .host:
            ControlScreenList.staticRow(cell)
            let value = attempt.serverName
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.valueRow("Host", value, palette: palette, style: .body)
            }
        case .status:
            ControlScreenList.staticRow(cell)
            let value = ProviderAuthFlowPresentation.statusText(attempt.flow.status)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.valueRow("Status", value, palette: palette, style: .body)
            }
        case .finishing:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.loading("Finishing sign-in on the host…")
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .preparing:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.loading("Preparing sign-in…")
            ControlScreenList.background(cell, grouped: false, palette: palette)
        case .openLink:
            ControlScreenList.buttonRow(cell, identifier: "mcp.auth.open", label: "Open Sign-In Page") { [weak self] in
                self?.openSignInPage()
            }
            cell.contentConfiguration = Self.actionContent("Open Sign-In Page", color: UIColor(palette.blue))
        case .callback:
            break
        case .submit:
            let enabled = owner.canSubmitCallback
            ControlScreenList.buttonRow(
                cell, identifier: "mcp.auth.submit", label: "Submit Callback", enabled: enabled
            ) { [weak self] in
                self?.submit()
            }
            cell.contentConfiguration = Self.actionContent(
                "Submit Callback", color: UIColor(enabled ? palette.blue : palette.comment)
            )
        case .flowError:
            notice(cell, attempt.flow.error, style: .body, color: UIColor(palette.red))
        case .actionError:
            notice(cell, attempt.actionError, style: .body, color: UIColor(palette.red))
        case .refreshError:
            notice(cell, attempt.refreshError, style: .body, color: UIColor(palette.orange))
        case .gone:
            notice(cell, "The host no longer has this flow. Start a new sign-in.", style: .body, color: UIColor(palette.fg))
        case .finish:
            if attempt.isSettled {
                ControlScreenList.buttonRow(cell, identifier: "mcp.auth.sheet.done", label: "Done") { [weak self] in
                    self?.owner.showingSheet = false
                }
                cell.contentConfiguration = Self.actionContent("Done", color: UIColor(palette.blue))
            } else {
                let cancelling = attempt.isCancelling
                ControlScreenList.buttonRow(
                    cell, identifier: "mcp.auth.sheet.cancel", label: "Cancel Sign-In", enabled: !cancelling
                ) { [weak self] in
                    guard let owner = self?.owner else { return }
                    Task { await owner.cancel() }
                }
                cell.contentConfiguration = Self.actionContent(
                    "Cancel Sign-In", color: UIColor(cancelling ? palette.comment : palette.red)
                )
            }
        }
    }

    private func notice(_ cell: SidebarListCell, _ text: String?, style: UIFont.TextStyle, color: UIColor) {
        ControlScreenList.staticRow(cell)
        cell.contentConfiguration = ControlViewContent {
            ControlRowViews.selectableText(text ?? "", style: style, color: color)
        }
    }

    private static func actionContent(_ title: String, color: UIColor) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.color = color
        return content
    }

    // MARK: - Actions

    private func submit() {
        guard owner.canSubmitCallback else { return }
        view.endEditing(true)
        let owner = owner
        Task { await owner.submitCallback() }
    }

    private func openSignInPage() {
        guard let auth = attempt.flow.auth, let url = ProviderAuthFlowPresentation.signInURL(auth.url) else { return }
        root.opener.open(.webLink(url))
    }
}

/// Presents the sign-in sheet for `McpSignInOwner`'s attempt from whichever
/// MCP screen is on top: the list holds the attempt, but a sign-in starts on a
/// server's detail, which covers the list. Each screen owns one presenter and
/// calls `sync` from `updateProperties()`; only a screen in the window
/// presents, and one sheet is up at a time.
@MainActor
final class McpSignInPresenter {
    private weak var sheet: McpSignInViewController?
    private var isScheduled = false

    func sync(owner: McpSignInOwner, root: AppRootEnvironment, from screen: UIViewController) {
        guard owner.showingSheet, owner.attempt != nil else {
            if let sheet, !sheet.isBeingDismissed { Router.finish(sheet) }
            return
        }
        guard sheet == nil, !isScheduled, screen.viewIfLoaded?.window != nil else { return }
        // A presentation needs a settled view tree, not the layout pass that asked for it.
        isScheduled = true
        Task { @MainActor [weak self, weak owner, weak screen] in
            guard let self else { return }
            isScheduled = false
            guard let owner, let screen, owner.showingSheet, let attempt = owner.attempt,
                  sheet == nil, screen.viewIfLoaded?.window != nil, !Self.isShowing(from: screen) else { return }
            let sheet = McpSignInViewController(attempt: attempt, owner: owner, root: root)
            self.sheet = sheet
            Router.present(sheet, presentation: .sheet.inNavigation(), from: screen) { [weak owner] in
                owner?.sheetDismissed()
            }
        }
    }

    /// A sheet from another MCP screen is already up.
    private static func isShowing(from screen: UIViewController) -> Bool {
        let top = Router.topPresenter(from: screen)
        return (top as? UINavigationController)?.viewControllers.first is McpSignInViewController
    }
}
