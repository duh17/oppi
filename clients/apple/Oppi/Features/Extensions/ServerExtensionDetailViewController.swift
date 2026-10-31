import UIKit

/// One Pi extension on one server (route `.serverResourceDetail`, kind
/// `.extension`): its server default switch, where it comes from, its status
/// with Retry, and the tools and commands it contributes. An extension with a
/// user-editable host file also carries the compact Oppi bar, the shared guided
/// composer on this screen's server, which starts a session for that file.
///
/// A `ServerResourceDetailScreenController`: the base owns the server switch,
/// the detail load, the switch's save, and the whole-screen state. The catalog
/// row shows at once; the detail request adds the contributions, and a newer
/// detail summary wins over a stale catalog row until a mutation settles
/// (`resolvedServerExtensionDetailSummary`).
@MainActor
final class ServerExtensionDetailViewController: ServerResourceDetailScreenController<
    ServerExtensionSummary, ServerExtensionDetail,
    ServerExtensionDetailViewController.Section, ServerExtensionDetailViewController.Item
> {
    enum Section: Hashable, Sendable {
        case summary, serverDefault, source, status, loading, tools, commands
    }

    enum Item: Hashable, Sendable {
        case title
        case enabled
        case mutationError
        case detail(String)
        case status
        case loadError
        case warning(String)
        case retry
        case loadingContributions
        case tool(String)
        case command(String)
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
                unavailableTitle: String(localized: "Extension Unavailable"),
                expectedKind: .extension,
                catalog: .extensions,
                mutationKey: .normalExtension(resourceId),
                fetch: { api, _ in try await api.getServerExtension(id: resourceId) },
                sendEnabled: { enabled, api, store in
                    await store.setExtensionEnabled(id: resourceId, enabled: enabled, serverId: serverId, api: api)
                }
            )
        )
    }

    override func summary(in store: ServerResourceStore) -> ServerExtensionSummary? {
        resolvedServerExtensionDetailSummary(
            catalogSummary: store.extensions(forServer: target.serverId).first { $0.id == target.resourceId },
            freshDetail: usesDetailSummary ? detail : nil
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
        var sections: [ListSection<Section, Item>] = [
            ListSection(.summary, items: [.title]),
            ListSection(
                .serverDefault,
                header: "Server Default",
                footer: "New sessions use this setting. Reload an active session to apply it now.",
                items: state.mutationError == nil ? [.enabled] : [.enabled, .mutationError]
            ),
            ListSection(.source, header: "Source", items: sourceItems),
            ListSection(.status, header: "Status", items: statusItems),
        ]
        if state.isLoading && state.detail == nil {
            sections.append(ListSection(.loading, items: [.loadingContributions]))
        }
        if let tools = state.detail?.contributedTools, !tools.isEmpty {
            sections.append(ListSection(.tools, header: "Contributed Tools", items: Self.unique(tools).map(Item.tool)))
        }
        if let commands = state.detail?.contributedCommands, !commands.isEmpty {
            sections.append(ListSection(
                .commands, header: "Contributed Commands", items: Self.unique(commands).map(Item.command)
            ))
        }
        return sections
    }

    private var sourceItems: [Item] {
        var items = [Item]()
        if state?.summary.packageName != nil { items.append(.detail("Package")) }
        return items + [.detail("Provenance"), .detail("Kind"), .detail("Scope")]
    }

    /// The load's state and what it found: the retry under either a row error
    /// or a failed load, and each warning once (a diffable list traps on a
    /// repeated row).
    private var statusItems: [Item] {
        guard let state else { return [] }
        let summary = state.summary
        var items: [Item] = [.status]
        if summary.loadError ?? state.loadError != nil { items.append(.loadError) }
        items += Self.unique(summary.warnings).map(Item.warning)
        if summary.state == .error || state.loadError != nil { items.append(.retry) }
        return items
    }

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
        case .loadError: resourceRowInputs(.loadError)
        case .detail: AnyHashable([
            AnyHashable(summary.packageName), AnyHashable(summary.provenance.label), AnyHashable(summary.kind),
        ])
        case .tool(let name), .command(let name):
            // A contribution name is selectable text: a pass that redrew the row
            // would drop a selection or the copy menu, so it is keyed by it.
            AnyHashable(name)
        // A warning, Retry, or loading row holds nothing a reconfigure would
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
                    summary.name, style: .title2, weight: .bold, color: UIColor(palette.fg)
                )]
                if let description {
                    views.append(ControlRowViews.label(description, style: .body, color: UIColor(palette.comment)))
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
                    color: UIColor(palette.orange)
                )
            }
        case .detail(let title):
            ListScreen.staticRow(cell, identifier: "server.extension.source.\(title.lowercased())")
            let value = switch title {
            case "Package": summary.packageName ?? ""
            case "Provenance": summary.provenance.label
            case "Kind": ServerExtensionListPresentation.kindLabel(for: summary.kind)
            default: "Server default"
            }
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.valueRow(title, value, palette: palette, style: .body)
            }
        case .status:
            ListScreen.staticRow(cell, identifier: "server.extension.status")
            let isIssue = summary.state == .error || summary.state == .unknown
            let icon = isIssue ? "exclamationmark.triangle.fill" : (summary.state == .on ? "checkmark.circle" : "minus.circle")
            let label = ServerExtensionListPresentation.stateLabel(for: summary.state)
            cell.contentConfiguration = ControlViewContent {
                let row = ControlRowViews.symbolLabel(label, systemImage: icon, style: .body, color: UIColor(palette.fg))
                row.accessibilityLabel = label
                return row
            }
        case .loadError:
            ListScreen.staticRow(cell, identifier: "server.extension.loadError")
            let error = summary.loadError ?? state.loadError ?? ""
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(error, style: .footnote, color: UIColor(palette.orange))
            }
        case .warning(let warning):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.symbolLabel(
                    warning,
                    systemImage: "exclamationmark.circle",
                    style: .footnote,
                    color: UIColor(palette.fg)
                )
            }
        case .retry:
            ListScreen.buttonRow(cell, identifier: "server.extension.retry", label: "Retry") { [weak self] in
                self?.setNeedsLoad()
            }
            var content = UIListContentConfiguration.cell()
            content.text = "Retry"
            content.textProperties.color = UIColor(palette.blue)
            cell.contentConfiguration = content
        case .loadingContributions:
            ListScreen.stateRow(cell, .loading(String(localized: "Loading contributions…")), palette: palette)
        case .tool(let name), .command(let name):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
                ControlRowViews.selectableText(name, style: .body, color: UIColor(palette.fg))
            }
        }
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

/// A successful detail response is newer than the catalog row that opened it.
/// This lets Retry clear stale row errors without changing catalog ownership.
func resolvedServerExtensionDetailSummary(
    catalogSummary: ServerExtensionSummary?,
    freshDetail: ServerExtensionDetail?
) -> ServerExtensionSummary? {
    freshDetail?.summary ?? catalogSummary
}
