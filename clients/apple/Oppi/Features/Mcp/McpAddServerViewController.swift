import UIKit

/// Add an MCP server to one scope's `mcp.json`, as a sheet: an HTTP
/// (streamable) or stdio transport, its exposure, and the fields that
/// transport takes. The global list and each workspace list add only to their
/// own scope. Add closes the sheet once the host has the entry; a failure
/// stays here.
@MainActor
final class McpAddServerViewController: UIViewController, UICollectionViewDelegate {
    private enum Mode: Int {
        case url, command
    }

    private enum Section: Hashable {
        case configuration, http, oauth, stdio, error, saving
    }

    private enum Item: Hashable {
        case host, name, scope, transport, exposure
        case url, headers
        case clientId, clientSecret, callbackPort
        case command, arguments, cwd, environment
        case error, saving
    }

    private let client: APIClient
    /// The list this sheet was opened from.
    private let scope: McpScopeSnapshot
    private let serverName: String
    private let root: AppRootEnvironment
    private let onAdded: () -> Void
    private let collectionView = ControlScreenList.makeCollectionView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var changedRows = ChangedRows<Item>()
    private let addItem = UIBarButtonItem()
    private let cancelItem = UIBarButtonItem(systemItem: .cancel)

    private static let secretReferenceFooter =
        "Use ${NAME} references instead of literal secrets. For example: API_KEY=${TOOLS_KEY}, or Authorization=Bearer ${TOKEN}. Values are resolved on the host; literal values are redacted when read back."

    private var mode = Mode.url {
        didSet {
            guard mode != oldValue else { return }
            pairs = ""
            setNeedsUpdateProperties()
        }
    }
    private var exposure = McpExposure.codemode {
        didSet { setNeedsUpdateProperties() }
    }
    private var saving = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var error: String? {
        didSet { setNeedsUpdateProperties() }
    }
    // Typed text. Rows never redraw from these while a field has the keyboard.
    private var name = "" { didSet { setNeedsUpdateProperties() } }
    private var url = "" { didSet { setNeedsUpdateProperties() } }
    private var command = "" { didSet { setNeedsUpdateProperties() } }
    private var arguments = ""
    private var cwd = ""
    /// Headers (HTTP) or environment (stdio): one `KEY=VALUE` per line.
    private var pairs = ""
    private var clientId = ""
    private var clientSecret = ""
    private var callbackPort = ""

    init(
        client: APIClient,
        scope: McpScopeSnapshot,
        serverName: String,
        root: AppRootEnvironment,
        onAdded: @escaping () -> Void
    ) {
        self.client = client
        self.scope = scope
        self.serverName = serverName
        self.root = root
        self.onAdded = onAdded
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        title = "Add MCP Server"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    private var canAdd: Bool {
        !saving && !name.isEmpty && (mode == .url ? !url.isEmpty : !command.isEmpty)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(
            ControlScreenList.layout(appearance: .insetGrouped, headers: true, footers: true),
            animated: false
        )
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "mcp.add.list"
        SettingsListStyle.pin(collectionView, in: view)
        installDataSource()

        cancelItem.primaryAction = UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        }
        cancelItem.accessibilityLabel = "Cancel"
        navigationItem.leftBarButtonItem = cancelItem
        addItem.title = "Add"
        addItem.style = .prominent
        addItem.primaryAction = UIAction(title: "Add") { [weak self] _ in self?.add() }
        addItem.accessibilityLabel = "Add"
        addItem.accessibilityIdentifier = "mcp.add.save"
        navigationItem.rightBarButtonItem = addItem
    }

    override func updateProperties() {
        super.updateProperties()
        ControlScreenList.applyTheme(root.themeStore, to: self, collectionView: collectionView)
        addItem.isEnabled = canAdd
        cancelItem.isEnabled = !saving
        // A save in flight keeps the sheet up, as a swipe-down would lose it.
        isModalInPresentation = saving
        applySnapshot()
    }

    // MARK: - List

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.configuration])
        snapshot.appendItems([.host, .name, .scope, .transport, .exposure], toSection: .configuration)
        switch mode {
        case .url:
            snapshot.appendSections([.http, .oauth])
            snapshot.appendItems([.url, .headers], toSection: .http)
            snapshot.appendItems([.clientId, .clientSecret, .callbackPort], toSection: .oauth)
        case .command:
            snapshot.appendSections([.stdio])
            snapshot.appendItems([.command, .arguments, .cwd, .environment], toSection: .stdio)
        }
        if error != nil {
            snapshot.appendSections([.error])
            snapshot.appendItems([.error], toSection: .error)
        }
        if saving {
            snapshot.appendSections([.saving])
            snapshot.appendItems([.saving], toSection: .saving)
        }

        // Only the rows whose inputs changed: typing never redraws a field, so
        // it keeps the keyboard and its selection.
        let current = dataSource.snapshot()
        let themeID = root.themeStore.activeThemeID
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) {
            AnyHashable([AnyHashable(themeID)] + rowInputs($0))
        }
        snapshot.reconfigureItems(changed.filter { current.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshVisibleFooters()
    }

    private func rowInputs(_ item: Item) -> [AnyHashable] {
        switch item {
        case .transport: [mode.rawValue]
        case .exposure: [exposure.rawValue, saving]
        case .error: [error]
        case .host, .scope, .saving: []
        case .name, .url, .headers, .clientId, .clientSecret, .callbackPort, .command, .arguments, .cwd, .environment:
            [saving]
        }
    }

    private func installDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, item in
            self?.configureField(cell, item: item)
        }
        let editor = UICollectionView.CellRegistration<SettingsTextViewRowCell, Item> { [weak self] cell, _, item in
            self?.configureEditor(cell, item: item)
        }
        let menu = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(
                title: "Exposure",
                identifier: "mcp.add.exposure",
                options: McpExposure.allCases.map { option in
                    (title: option.title, selected: option == exposure, action: { [weak self] in
                        guard let self, !saving else { return }
                        exposure = option
                    })
                }
            )
        }
        let segmented = UICollectionView.CellRegistration<AgentNativeEditSegmentedCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(
                titles: ["HTTP", "stdio"],
                selectedIndex: mode.rawValue,
                identifier: "mcp.add.transport"
            ) { [weak self] index in
                self?.mode = Mode(rawValue: index) ?? .url
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = switch self?.dataSource?.sectionIdentifier(for: indexPath.section) {
            case .configuration: "Configuration"
            case .http: "Streamable HTTP"
            case .oauth: "Optional OAuth Client"
            case .stdio: "Standard Input / Output"
            default: nil
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            self?.configureFooter(view, at: indexPath)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .name, .url, .clientId, .clientSecret, .callbackPort, .command, .cwd:
                collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            case .headers, .arguments, .environment:
                collectionView.dequeueConfiguredReusableCell(using: editor, for: indexPath, item: item)
            case .transport:
                collectionView.dequeueConfiguredReusableCell(using: segmented, for: indexPath, item: item)
            case .exposure:
                collectionView.dequeueConfiguredReusableCell(using: menu, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configureFooter(_ view: UICollectionViewListCell, at indexPath: IndexPath) {
        var content = UIListContentConfiguration.footer()
        switch dataSource?.sectionIdentifier(for: indexPath.section) {
        case .configuration:
            var lines = [exposure.explanation]
            if let trust = scope.projectTrust {
                lines.append("Saved to this workspace\u{2019}s .pi/mcp.json. Project trust: \(trust.title.lowercased()).")
            }
            content.text = lines.joined(separator: "\n")
        case .http:
            content.text = Self.secretReferenceFooter
        case .stdio:
            let warning = NSMutableAttributedString(string: Self.secretReferenceFooter + "\n")
            warning.append(NSAttributedString(
                string: "Adding a command authorizes Pi to run it on the host when the scope is trusted and the server is enabled.",
                attributes: [.foregroundColor: UIColor(palette.orange)]
            ))
            content.attributedText = warning
        default:
            break
        }
        content.textProperties.numberOfLines = 0
        view.contentConfiguration = content
    }

    /// The exposure's explanation changes with the picker, and supplementary
    /// views do not reconfigure.
    private func refreshVisibleFooters() {
        let kind = UICollectionView.elementKindSectionFooter
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                as? UICollectionViewListCell else { continue }
            configureFooter(view, at: indexPath)
        }
    }

    // MARK: - Rows

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ControlScreenList.background(cell, grouped: true, palette: palette)
        switch item {
        case .host:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = McpRowContent.value("Host", serverName)
        case .scope:
            ControlScreenList.staticRow(cell, identifier: "mcp.add.scope")
            cell.contentConfiguration = McpRowContent.value("Scope", scope.title)
        case .exposure:
            break
        case .error:
            ControlScreenList.staticRow(cell, identifier: "mcp.add.error")
            let message = error
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(message, style: .body, color: UIColor(palette.red))
            }
        case .saving:
            ControlScreenList.staticRow(cell)
            cell.contentConfiguration = ControlScreenList.loading("Adding server…")
            ControlScreenList.background(cell, grouped: false, palette: palette)
        default:
            break
        }
    }

    private func configureField(_ cell: SSHTerminalTextFieldCell, item: Item) {
        let textColor = UIColor(palette.fg)
        func field(
            _ text: String,
            _ placeholder: String,
            _ identifier: String,
            keyboard: UIKeyboardType = .default,
            onChange: @escaping (String) -> Void
        ) {
            cell.configure(
                text: text,
                placeholder: placeholder,
                identifier: identifier,
                keyboard: keyboard,
                textColor: textColor,
                enabled: !saving,
                onChange: onChange
            )
        }
        switch item {
        case .name:
            field(name, "Server name", "mcp.add.name") { [weak self] in self?.name = $0 }
        case .url:
            field(url, "https://example.com/mcp", "mcp.add.url", keyboard: .URL) { [weak self] in self?.url = $0 }
        case .clientId:
            field(clientId, "Client ID", "mcp.add.clientId") { [weak self] in self?.clientId = $0 }
        case .clientSecret:
            field(clientSecret, "Client secret reference: ${NAME}", "mcp.add.clientSecret") { [weak self] in
                self?.clientSecret = $0
            }
        case .callbackPort:
            field(callbackPort, "Callback port (automatic if empty)", "mcp.add.callbackPort", keyboard: .numberPad) { [weak self] in
                self?.callbackPort = $0
            }
        case .command:
            field(command, "Executable (not a shell command)", "mcp.add.command") { [weak self] in self?.command = $0 }
        case .cwd:
            field(cwd, "Working directory (optional)", "mcp.add.cwd") { [weak self] in self?.cwd = $0 }
        default:
            break
        }
    }

    private func configureEditor(_ cell: SettingsTextViewRowCell, item: Item) {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let insets = SettingsTextViewRowCell.verticalInsets
        func editor(
            _ text: String,
            _ placeholder: String,
            _ identifier: String,
            onChange: @escaping (String) -> Void
        ) {
            cell.configure(
                text: text,
                placeholder: placeholder,
                identifier: identifier,
                accessibilityLabel: placeholder,
                minHeight: lineHeight * 3 + insets,
                maxHeight: lineHeight * 8 + insets,
                onChange: onChange,
                onCaretMove: { [weak self] in self?.scrollCaretVisible(in: $0) }
            )
            cell.textView.textColor = UIColor(palette.fg)
            cell.textView.isEditable = !saving
            cell.textView.autocapitalizationType = .none
            cell.textView.autocorrectionType = .no
        }
        switch item {
        case .headers:
            editor(pairs, "Headers: one KEY=VALUE per line", "mcp.add.headers") { [weak self] in self?.pairs = $0 }
        case .arguments:
            editor(arguments, "Arguments: one per line (no secrets)", "mcp.add.arguments") { [weak self] in
                self?.arguments = $0
            }
        case .environment:
            editor(pairs, "Environment: one KEY=VALUE per line", "mcp.add.environment") { [weak self] in
                self?.pairs = $0
            }
        default:
            break
        }
    }

    /// Keeps the caret in view as a growing editor pushes below the keyboard.
    private func scrollCaretVisible(in textView: UITextView) {
        guard let range = textView.selectedTextRange else { return }
        let caret = textView.convert(textView.caretRect(for: range.end), to: collectionView)
        collectionView.scrollRectToVisible(caret.insetBy(dx: 0, dy: -12), animated: false)
    }

    // MARK: - Add

    private func add() {
        guard canAdd else { return }
        view.endEditing(true)
        var values: [String: String] = [:]
        for line in pairs.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "="), separator != line.startIndex else {
                error = "Use KEY=VALUE on each line."
                return
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, values[key] == nil else {
                error = "Keys must be non-empty and unique."
                return
            }
            values[key] = String(line[line.index(after: separator)...])
        }
        var input = McpAddServerRequest(name: name, exposure: exposure.configurationValue)
        if mode == .url {
            input.url = url
            input.headers = values.isEmpty ? nil : values
            var oauth = McpServerConfig.OAuth()
            oauth.clientId = clientId.isEmpty ? nil : clientId
            oauth.clientSecret = clientSecret.isEmpty ? nil : clientSecret
            if !callbackPort.isEmpty {
                guard let port = Int(callbackPort), (1...65535).contains(port) else {
                    error = "Enter a callback port between 1 and 65535."
                    return
                }
                oauth.callbackPort = port
            }
            if oauth.clientId != nil || oauth.clientSecret != nil || oauth.callbackPort != nil { input.oauth = oauth }
        } else {
            input.command = command
            input.args = arguments.isEmpty ? nil : arguments.components(separatedBy: "\n")
            input.cwd = cwd.isEmpty ? nil : cwd
            input.env = values.isEmpty ? nil : values
        }
        saving = true
        error = nil
        let client = client
        let scopeId = scope.id
        let onAdded = onAdded
        Task { [weak self] in
            do {
                try await client.addMcpServer(scopeId: scopeId, input)
                onAdded()
                self?.saving = false
                if let self { Router.finish(self) }
            } catch {
                self?.error = error.localizedDescription
                self?.saving = false
            }
        }
    }
}
