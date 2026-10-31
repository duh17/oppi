import UIKit

/// One Skill on one server (route `.serverResourceDetail`, kind `.skill`): its
/// server default switch, where it comes from, its validation with Retry, and
/// the file list the browser opens.
///
/// A `ServerResourceDetailScreenController`: the base owns the server switch,
/// the detail load, the switch's save, and the whole-screen state. The catalog
/// row shows at once; the detail request adds the file list, and a newer detail
/// summary wins over a stale catalog row until a mutation settles
/// (`resolvedServerSkillDetailSummary`).
@MainActor
final class ServerSkillDetailViewController: ServerResourceDetailScreenController<
    ServerSkillSummary, ServerSkillDetail, ServerSkillDetailViewController.Section, ServerSkillDetailViewController.Item
> {
    enum Section: Hashable, Sendable {
        case summary, serverDefault, source, validation, loading, contents
    }

    enum Item: Hashable, Sendable {
        case title
        case enabled
        case mutationError
        case detail(String)
        case status
        case warning(String)
        case browse
    }

    /// `connection`: the Skill's server when the caller already has it ready;
    /// nil makes it the active server first.
    init(target: ServerResourceDetailNavTarget, root: AppRootEnvironment, connection: ServerConnection? = nil) {
        let resourceId = target.resourceId
        let serverId = target.serverId
        super.init(
            target: target,
            root: root,
            connection: connection,
            page: ServerResourceDetailPage(
                title: String(localized: "Skill"),
                listIdentifier: "skills.detail.list",
                loadingCaption: String(localized: "Loading skill…"),
                failureTitle: String(localized: "Couldn't Load Skill"),
                showsConnecting: true,
                expectedKind: .skill,
                catalog: .skills,
                mutationKey: .skill(resourceId),
                fetch: { api, store in
                    let detail = try await api.getServerSkill(id: resourceId)
                    store.rememberSkillDetail(detail, serverId: serverId)
                    return detail
                },
                sendEnabled: { enabled, api, store in
                    await store.setSkillEnabled(id: resourceId, enabled: enabled, serverId: serverId, api: api)
                }
            )
        )
    }

    override func summary(in store: ServerResourceStore) -> ServerSkillSummary? {
        resolvedServerSkillDetailSummary(
            catalogSummary: store.skills(forServer: target.serverId).first { $0.id == target.resourceId },
            freshDetail: usesDetailSummary ? detail : nil
        )
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
            ListSection(.validation, header: "Validation", items: validationItems),
        ]
        // The contents' place: the kit's compact loading row until the detail
        // arrives, and its one failed row with Retry when Pi could not read the
        // Skill.
        if let row = stateRow(hasContent: state.detail != nil, isLoading: isLoading, failure: failureReason) {
            sections.append(ListSection(.loading, items: [], state: row))
        }
        if state.detail != nil {
            sections.append(ListSection(.contents, header: "Contents", items: [.browse]))
        }
        return sections
    }

    /// Why the contents are not here: the request's failure, or the Skill Pi could
    /// not read, so one row says either and retries it.
    private var failureReason: String? {
        if let loadFailure { return loadFailure.reason ?? loadFailure.title }
        guard let summary = state?.summary else { return nil }
        if let error = summary.loadError { return error }
        let hasError = summary.state == .error || summary.state == .unknown
        return hasError ? String(localized: "Pi could not read this Skill.") : nil
    }

    private var sourceItems: [Item] {
        var items = [Item]()
        if state?.summary.packageName != nil { items.append(.detail("Package")) }
        return items + [.detail("Provenance"), .detail("Scope"), .detail("Files")]
    }

    /// What the load found: the resource's state, and each warning once (a
    /// diffable list traps on a repeated row).
    private var validationItems: [Item] {
        guard let state else { return [] }
        return [.status] + Self.unique(state.summary.warnings).map(Item.warning)
    }

    /// The contents are what the detail request fetches: until they are here the
    /// list shows the compact loading row in the Contents place.
    override func hasContent() -> Bool { state?.detail != nil }

    override func loadingCaption() -> String? { String(localized: "Loading skill contents…") }

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
        case .detail: AnyHashable([
            AnyHashable(summary.packageName), AnyHashable(summary.provenance.label), AnyHashable(summary.editable),
        ])
        case .browse: AnyHashable([AnyHashable(summary.name), AnyHashable(state.detail?.files.count)])
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
            ListScreen.staticRow(cell, identifier: "skills.detail.title")
            var content = UIListContentConfiguration.subtitleCell()
            content.text = summary.name
            // Bold title2, still a text style, so it scales with the setting.
            let title2 = UIFont.preferredFont(forTextStyle: .title2)
            content.textProperties.font = title2.fontDescriptor.withSymbolicTraits(.traitBold)
                .map { UIFont(descriptor: $0, size: 0) } ?? title2
            content.textProperties.color = UIColor(palette.fg)
            if !summary.description.isEmpty {
                content.secondaryText = summary.description
                content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
                content.secondaryTextProperties.color = UIColor(palette.comment)
            }
            cell.contentConfiguration = content
        case .enabled:
            serverDefaultRow(cell, identifier: "skills.detail.enabled", savingIdentifier: "skills.detail.saving")
        case .mutationError:
            ListScreen.staticRow(cell, identifier: "skills.detail.mutationError")
            cell.contentConfiguration = Self.noteContent(
                mutationFailureMessage, systemImage: "exclamationmark.triangle.fill",
                color: UIColor(palette.orange), imageColor: UIColor(palette.orange)
            )
        case .detail(let title):
            ListScreen.staticRow(cell, identifier: "skills.detail.source.\(title.lowercased())")
            let value = switch title {
            case "Package": summary.packageName ?? ""
            case "Provenance": summary.provenance.label
            case "Scope": "Server default"
            default: summary.editable ? "Editable" : "Read-only"
            }
            var content = UIListContentConfiguration.valueCell()
            content.text = title
            content.textProperties.color = UIColor(palette.comment)
            content.secondaryText = value
            content.secondaryTextProperties.color = UIColor(palette.fg)
            cell.contentConfiguration = content
            // One element, so a path reads as a label and its value.
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = title
            cell.accessibilityValue = value
        case .status:
            ListScreen.staticRow(cell, identifier: "skills.detail.status")
            let hasError = summary.state == .error || summary.state == .unknown
            let label = hasError ? "Error" : "Loaded"
            var content = UIListContentConfiguration.cell()
            content.text = label
            content.textProperties.color = UIColor(palette.fg)
            content.image = UIImage(systemName: hasError ? "exclamationmark.triangle.fill" : "checkmark.circle")
            content.imageProperties.tintColor = UIColor(palette.fg)
            cell.contentConfiguration = content
        case .warning(let warning):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = Self.noteContent(
                warning, systemImage: "exclamationmark.circle",
                color: UIColor(palette.fg), imageColor: UIColor(palette.fg)
            )
        case .browse:
            let count = state.detail?.files.count ?? 0
            let countLabel = count == 1 ? "1 file" : "\(count) files"
            ListScreen.buttonRow(
                cell,
                identifier: "skills.files.open",
                label: "Browse \(summary.name) files",
                value: countLabel
            ) { [weak self] in
                self?.openBrowser()
            }
            var content = UIListContentConfiguration.valueCell()
            content.text = "Browse Files"
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryText = "\(count)"
            content.secondaryTextProperties.color = UIColor(palette.comment)
            content.image = UIImage(systemName: "folder")
            content.imageProperties.tintColor = UIColor(palette.blue)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
    }

    /// A footnote with a symbol: a warning, or a failed save.
    private static func noteContent(
        _ text: String,
        systemImage: String,
        color: UIColor,
        imageColor: UIColor
    ) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = text
        content.textProperties.font = .preferredFont(forTextStyle: .footnote)
        content.textProperties.color = color
        content.image = UIImage(systemName: systemImage)
        content.imageProperties.tintColor = imageColor
        return content
    }

    // MARK: - Actions

    private func openBrowser() {
        root.navigation.openServerSkillBrowser(ServerSkillBrowserNavTarget(
            serverId: target.serverId,
            resourceId: target.resourceId
        ))
    }
}

/// A successful detail response is newer than the catalog row that opened it.
/// This lets Retry clear stale row errors without changing catalog ownership.
func resolvedServerSkillDetailSummary(
    catalogSummary: ServerSkillSummary?,
    freshDetail: ServerSkillDetail?
) -> ServerSkillSummary? {
    freshDetail?.summary ?? catalogSummary
}
