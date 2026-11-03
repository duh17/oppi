import UIKit

/// One Pi extension or plugin on one server (route `.serverResourceDetail`, kind
/// `.extension`): its status and load errors first, its server default switch
/// (fixed on for a runtime built-in, which the footer says), an About card (its
/// type, where it comes from, and a plugin's runtimes), and what it contributes:
/// one Tools section (split by the sessions each reaches when it is both kinds),
/// a Pi extension's commands, a plugin's hooks by task, prompt sections, wraps
/// and tasks, all from the row's protocol fields. A tool with a definition opens
/// its page (`ServerExtensionToolViewController`); a prompt section with text
/// opens it in the reader, and one written per conversation says so and opens
/// nothing. An extension with a
/// user-editable host file also carries the compact Oppi bar, the shared guided
/// composer on this screen's server, which starts a session for that file.
///
/// A `ServerResourceDetailScreenController`: the base owns the server switch,
/// the detail load, the switch's save, and the whole-screen state. The catalog
/// row shows at once; the detail request adds the contributions, and a newer
/// detail summary wins over a stale catalog row until a mutation settles.
@MainActor
final class ServerExtensionDetailViewController: ServerResourceDetailScreenController<
    ServerExtensionSummary, ServerExtensionDetail,
    ServerExtensionDetailViewController.Section, ServerExtensionDetailViewController.Item
> {
    enum Section: Hashable, Sendable {
        case summary, serverDefault, about, status, loading, commands, promptSections
        /// The tools of one origin.
        case tools(ServerExtensionToolOrigin)
        /// One group of what a plugin contributes, by its title.
        case plugin(String)
    }

    /// A row of the About card.
    enum AboutRow: String, Hashable, Sendable {
        case type, from, runsIn
    }

    enum Item: Hashable, Sendable {
        case title
        case enabled
        case mutationError
        case about(AboutRow)
        case status
        case loadError(String)
        /// A failed plugin reload left its previous code running.
        case kept
        case warning(String)
        /// One tool by its origin and name: a plugin and its package's classic
        /// extension may both have a tool of one name.
        case tool(ServerExtensionToolOrigin, String)
        /// One of the plugin's prompt sections, by name, from the detail.
        case promptSection(String)
        case command(String)
        /// One line of a plugin group: the group's title, then the line.
        case pluginLine(String, String)
    }

    /// The compact Oppi bar, made once the screen has its server and an
    /// editable extension.
    private var composer: GuidedControlComposerController?

    /// `connection`: the extension's server when the caller already has it
    /// ready; nil makes it the active server first.
    init(target: ServerResourceDetailNavTarget, root: AppRootEnvironment, connection: ServerConnection? = nil) {
        let resourceId = target.resourceId
        let serverId = target.serverId
        super.init(
            target: target,
            root: root,
            connection: connection,
            page: ServerResourceDetailPage(
                title: "Extension",
                listIdentifier: "server.extension.list",
                loadingCaption: String(localized: "Loading extension…"),
                failureTitle: String(localized: "Couldn't Load Contents"),
                catalog: .extensions,
                catalogRow: { $0.extensions(forServer: serverId).first { $0.id == resourceId } },
                mutationKey: .normalExtension(resourceId),
                fetch: { api, _ in try await api.getServerExtension(id: resourceId) },
                sendEnabled: { enabled, api, store in
                    await store.setExtensionEnabled(id: resourceId, enabled: enabled, serverId: serverId, api: api)
                }
            )
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer?.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        updateComposer()
    }

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        guard let state else { return [] }
        // Load errors first: what failed matters more than where it came from.
        var sections: [ListSection<Section, Item>] = [
            ListSection(.summary, items: [.title]),
            ListSection(.status, header: "Status", items: statusItems),
            ListSection(
                .serverDefault,
                header: "Server Default",
                footer: state.summary.plugin?.required == true
                    ? String(localized: "Part of the durable session runtime, so it’s always on in durable sessions.")
                    : "New sessions use this setting. Reload an active session to apply it now.",
                items: state.mutationError == nil ? [.enabled] : [.enabled, .mutationError]
            ),
            ListSection(.about, header: "About", items: aboutItems),
        ]
        // The contributions' place: the kit's compact loading row until the detail
        // arrives, and its one failed row with Retry when the request failed.
        if let row = stateRow(hasContent: state.detail != nil, isLoading: isLoading, failure: loadFailure) {
            sections.append(ListSection(.loading, items: [], state: row))
        }
        for group in toolGroups {
            sections.append(ListSection(
                .tools(group.origin),
                header: group.title,
                items: group.tools.map { Item.tool(group.origin, $0.name) }
            ))
        }
        if let commands = state.detail?.contributedCommands, !commands.isEmpty {
            sections.append(ListSection(
                .commands, header: "Commands", items: Self.unique(commands).map(Item.command)
            ))
        }
        let promptSections = state.detail?.promptSections ?? []
        if !promptSections.isEmpty {
            sections.append(ListSection(
                .promptSections,
                header: "Prompt Sections",
                items: Self.unique(promptSections.map(\.name)).map(Item.promptSection)
            ))
        }
        if let plugin = state.summary.plugin {
            // A server that sends the sections themselves lists them above; an older
            // one sends only their names, listed with the plugin's other groups.
            let groups = ServerExtensionListPresentation.pluginSections(
                for: plugin, listsSections: state.detail?.promptSections == nil
            )
            for group in groups {
                sections.append(ListSection(
                    .plugin(group.title),
                    header: group.title,
                    items: Self.unique(group.lines).map { Item.pluginLine(group.title, $0) }
                ))
            }
        }
        return sections
    }

    /// Type and From always; Runs In only for a plugin with runtimes.
    private var aboutItems: [Item] {
        let runsIn = ServerExtensionListPresentation.runtimesLabel(for: state?.summary.plugin) != nil
        return [.about(.type), .about(.from)] + (runsIn ? [.about(.runsIn)] : [])
    }

    private var toolGroups: [ServerExtensionToolGroup] {
        guard let state else { return [] }
        return ServerExtensionListPresentation.toolGroups(summary: state.summary, detail: state.detail)
    }

    /// A tool row's drawn row, found by its item when the row is configured.
    private func toolRow(_ origin: ServerExtensionToolOrigin, _ name: String) -> ServerExtensionToolRow? {
        toolGroups.first { $0.origin == origin }?.tools.first { $0.name == name }
    }

    /// What Pi makes of the extension — its state, why it could not load it, and
    /// each warning once (a diffable list traps on a repeated row). These are
    /// facts about the extension, not a failed request.
    private var statusItems: [Item] {
        guard let state else { return [] }
        let summary = state.summary
        var items: [Item] = [.status]
        if let reason = summary.loadError ?? unreadableReason(summary) { items.append(.loadError(reason)) }
        if summary.plugin?.kept == true { items.append(.kept) }
        return items + Self.unique(summary.warnings).map(Item.warning)
    }

    /// Why Pi could not load the extension it listed, when it says nothing itself.
    private func unreadableReason(_ summary: ServerExtensionSummary) -> String? {
        summary.state == .error || summary.state == .unknown
            ? String(localized: "Pi could not load this extension.")
            : nil
    }

    override func hasContent() -> Bool { state?.detail != nil }

    override func loadingCaption() -> String? { String(localized: "Loading contributions…") }

    /// The group headings are the ones this page wrote, so only the sections
    /// with one show it.
    override func showsHeader(for section: Section) -> Bool {
        section != .summary && section != .loading
    }

    /// What a row draws from, besides its own identity: a replaced switch would
    /// drop a save in flight.
    override func inputs(of item: Item) -> AnyHashable {
        guard let state else { return AnyHashable(0) }
        let summary = state.summary
        return switch item {
        case .title: resourceRowInputs(.title)
        case .enabled: resourceRowInputs(.serverDefault)
        case .mutationError: resourceRowInputs(.mutationError)
        case .status: resourceRowInputs(.status)
        case .loadError(let reason): AnyHashable(reason)
        case .about: AnyHashable([
            AnyHashable(summary.packageName), AnyHashable(summary.provenance.label), AnyHashable(summary.kind),
            AnyHashable(summary.source), AnyHashable(summary.kinds), AnyHashable(summary.path),
            AnyHashable(summary.plugin?.runtimes),
        ])
        case .pluginLine(let group, let line): AnyHashable([group, line])
        case .tool(let origin, let name): AnyHashable(toolRow(origin, name))
        case .promptSection(let name): AnyHashable(promptSection(name))
        case .command(let name):
            // A contribution name is selectable text: a pass that redrew the row
            // would drop a selection or the copy menu, so it is keyed by it.
            AnyHashable(name)
        // A warning or loading row holds nothing a reconfigure would
        // disturb, so the kit's default draws it again.
        default: super.inputs(of: item)
        }
    }

    // MARK: - Rows

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        guard let state else { return }
        let summary = state.summary
        switch item {
        case .title:
            ListScreen.staticRow(cell, identifier: "server.extension.title")
            let description = summary.description.flatMap { $0.isEmpty ? nil : $0 }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 12, leading: 0, bottom: 12, trailing: 0)) {
                var views = [ControlRowViews.label(
                    summary.name, style: .title2, weight: .bold, color: palette.ui.fg
                )]
                if let description {
                    views.append(ControlRowViews.label(description, style: .body, color: palette.ui.comment))
                }
                return ControlRowViews.stack(views, spacing: 6)
            }
        case .enabled:
            serverDefaultRow(
                cell, identifier: "server.extension.enabled", savingIdentifier: "server.extension.saving"
            )
        case .mutationError:
            ListScreen.staticRow(cell, identifier: "server.extension.mutationError")
            let message = mutationFailureMessage
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.symbolLabel(
                    message,
                    systemImage: "exclamationmark.triangle.fill",
                    style: .footnote,
                    color: palette.ui.orange
                )
            }
        case .about(let row):
            ListScreen.staticRow(cell, identifier: "server.extension.about.\(row.rawValue)")
            let (title, value, path): (String, String, String?) = switch row {
            case .type: ("Type", ServerExtensionListPresentation.typeLabel(for: summary), nil)
            case .from: ("From", ServerExtensionListPresentation.fromLabel(for: summary), summary.path)
            case .runsIn: ("Runs In", ServerExtensionListPresentation.runtimesLabel(for: summary.plugin) ?? "", nil)
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                let valueRow = ControlRowViews.valueRow(title, value, palette: palette, style: .body)
                guard let path, !path.isEmpty else { return valueRow }
                // The path under the label: long, so it wraps the row's width.
                let pathText = ControlRowViews.selectableText(path, style: .footnote, color: palette.ui.comment)
                pathText.accessibilityLabel = String(localized: "Path")
                pathText.accessibilityValue = path
                return ControlRowViews.stack([valueRow, pathText], spacing: 4)
            }
        case .status:
            ListScreen.staticRow(cell, identifier: "server.extension.status")
            let isIssue = summary.state == .error || summary.state == .unknown
            let icon = isIssue ? "exclamationmark.triangle.fill" : (summary.state == .on ? "checkmark.circle" : "minus.circle")
            let label = ServerExtensionListPresentation.stateLabel(for: summary.state)
            cell.contentConfiguration = ControlViewContent {
                let row = ControlRowViews.symbolLabel(label, systemImage: icon, style: .body, color: palette.ui.fg)
                row.accessibilityLabel = label
                return row
            }
        case .loadError(let reason):
            ListScreen.staticRow(cell, identifier: "server.extension.loadError")
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(reason, style: .footnote, color: palette.ui.orange)
            }
        case .kept:
            ListScreen.staticRow(cell, identifier: "server.extension.kept")
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.symbolLabel(
                    "The reload failed, so its previous code still runs.",
                    systemImage: "clock.arrow.circlepath",
                    style: .footnote,
                    color: palette.ui.fg
                )
            }
        case .warning(let warning):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.symbolLabel(
                    warning,
                    systemImage: "exclamationmark.circle",
                    style: .footnote,
                    color: palette.ui.fg
                )
            }
        case .tool(let origin, let name):
            let row = toolRow(origin, name)
            // A tool opens its page only when the server sent its definition.
            let open: (() -> Void)? = row?.definition == nil ? nil : { [weak self] in self?.openTool(origin, name) }
            titledRow(
                cell, identifier: "server.extension.tool.\(origin.rawValue).\(name)",
                title: name, subtitle: row?.summary, open: open
            )
        case .promptSection(let name):
            let section = promptSection(name)
            if let text = section?.text {
                titledRow(
                    cell, identifier: "server.extension.section.\(name)",
                    title: name, subtitle: ServerExtensionListPresentation.firstLine(of: text)
                ) { [weak self] in self?.openSection(name) }
            } else {
                // Nothing to open: the text is written for each conversation.
                titledRow(
                    cell, identifier: "server.extension.section.\(name)",
                    title: name, subtitle: String(localized: "Written for each conversation from its workspace."), open: nil
                )
            }
        case .command(let name), .pluginLine(_, let name):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.selectableText(name, style: .body, color: palette.ui.fg)
            }
        }
    }

    /// A name over a one- or two-line subtitle. With `open` it is one button with a
    /// disclosure chevron that runs it; without, one read-only element.
    private func titledRow(
        _ cell: SidebarListCell,
        identifier: String,
        title: String,
        subtitle: String?,
        open: (() -> Void)?
    ) {
        let palette = palette
        if let open {
            ListScreen.buttonRow(cell, identifier: identifier, label: title, value: subtitle, action: open)
            cell.accessories = [.disclosureIndicator()]
        } else {
            ListScreen.staticRow(cell, identifier: identifier)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = title
            cell.accessibilityValue = subtitle
        }
        cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
            var views: [UIView] = [ControlRowViews.label(title, style: .body, color: palette.ui.fg)]
            if let subtitle {
                views.append(ControlRowViews.label(subtitle, style: .footnote, color: palette.ui.comment, lines: 2))
            }
            return ControlRowViews.stack(views, spacing: 2)
        }
    }

    private func promptSection(_ name: String) -> ServerPromptSection? {
        state?.detail?.promptSections?.first { $0.name == name }
    }

    // MARK: - Actions

    /// Resolved from the row's item when it runs, so a reloaded detail opens its own copy.
    private func openTool(_ origin: ServerExtensionToolOrigin, _ name: String) {
        guard let definition = toolRow(origin, name)?.definition else { return }
        Router.push(ServerExtensionToolViewController(tool: definition, root: root), from: self)
    }

    private func openSection(_ name: String) {
        guard let text = promptSection(name)?.text else { return }
        Router.push(ServerExtensionReaderViewController.section(named: name, text: text, root: root), from: self)
    }

    // MARK: - Oppi bar

    /// The bar revises the extension's host file, so it exists only for an
    /// extension with one (`ServerExtensionListPresentation.editablePath`),
    /// on this screen's server.
    private func updateComposer() {
        guard let connection, let state, let path = ServerExtensionListPresentation.editablePath(for: state.summary) else {
            composer?.setHidden(true)
            return
        }
        let composer = composer ?? makeComposer(connection)
        composer.model.updateTarget(id: path, name: state.summary.name, path: path)
        composer.setHidden(false)
    }

    private func makeComposer(_ connection: ServerConnection) -> GuidedControlComposerController {
        let composer = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .extensions,
                intent: .revise,
                presentation: .compact,
                placeholder: "Describe a change…"
            ),
            root: root,
            connection: { connection }
        )
        composer.install(in: self)
        self.composer = composer
        return composer
    }
}
