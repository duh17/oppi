import UIKit

/// One Skill on one server (route `.serverResourceDetail`, kind `.skill`): its
/// server default switch, where it comes from, its validation with Retry, and
/// the file list the browser opens.
///
/// A `ServerResourceDetailScreenController`: the base owns the server switch,
/// the detail load, the switch's save, the whole-screen state, and the rows the
/// extension page shares (title, Server Default, status, load error, warnings).
/// The catalog row shows at once; the detail request adds the file list, and a
/// newer detail summary wins over a stale catalog row until a mutation settles.
@MainActor
final class ServerSkillDetailViewController: ServerResourceDetailScreenController<
    ServerSkillSummary, ServerSkillDetail, ServerSkillDetailViewController.Section, ServerSkillDetailViewController.Item
> {
    enum Section: ServerResourceDetailSection {
        case summary, serverDefault, source, validation, loading, contents
    }

    enum Item: ServerResourceDetailItem {
        case resource(ServerResourceRow)
        case detail(String)
        case browse

        var resourceRow: ServerResourceRow? {
            if case .resource(let row) = self { row } else { nil }
        }
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
                unreadableReason: String(localized: "Pi could not read this Skill."),
                failureTitle: String(localized: "Couldn't Load Contents"),
                showsConnecting: true,
                catalog: .skills,
                catalogRow: { $0.skills(forServer: serverId).first { $0.id == resourceId } },
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

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        guard let state else { return [] }
        var sections: [ListSection<Section, Item>] = [
            summarySection(),
            serverDefaultSection(),
            ListSection(.source, header: "Source", items: sourceItems),
            ListSection(.validation, header: "Validation", items: statusItems()),
        ]
        if let loading = loadingSection() { sections.append(loading) }
        if state.detail != nil {
            sections.append(ListSection(.contents, header: "Contents", items: [.browse]))
        }
        return sections
    }

    private var sourceItems: [Item] {
        var items = [Item]()
        if state?.summary.packageName != nil { items.append(.detail("Package")) }
        return items + [.detail("Provenance"), .detail("Scope"), .detail("Files")]
    }

    override func loadingCaption() -> String? { String(localized: "Loading skill contents…") }

    /// What a row draws from, besides its own identity.
    override func inputs(of item: Item) -> AnyHashable {
        guard let state else { return AnyHashable(0) }
        let summary = state.summary
        return switch item {
        case .detail: AnyHashable([
            AnyHashable(summary.packageName), AnyHashable(summary.provenance.label), AnyHashable(summary.editable),
        ])
        case .browse: AnyHashable([AnyHashable(summary.name), AnyHashable(state.detail?.files.count)])
        case .resource: super.inputs(of: item)
        }
    }

    // MARK: - Rows

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        guard let state else { return }
        let summary = state.summary
        switch item {
        case .resource:
            super.configureCard(cell, item: item)
        case .detail(let title):
            let value = switch title {
            case "Package": summary.packageName ?? ""
            case "Provenance": summary.provenance.label
            case "Scope": "Server default"
            default: summary.editable ? "Editable" : "Read-only"
            }
            resourceFactRow(
                cell, identifier: "skills.detail.source.\(title.lowercased())", title: title, value: value
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
            content.textProperties.color = palette.ui.fg
            content.secondaryText = "\(count)"
            content.secondaryTextProperties.color = palette.ui.comment
            content.image = UIImage(systemName: "folder")
            content.imageProperties.tintColor = palette.ui.blue
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
    }

    // MARK: - Actions

    private func openBrowser() {
        root.navigation.openServerSkillBrowser(ServerSkillBrowserNavTarget(
            serverId: target.serverId,
            resourceId: target.resourceId
        ))
    }
}
