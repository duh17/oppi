import SwiftUI

struct ServerSkillsView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var searchText = ""

    private var activeServerId: String? {
        coordinator.activeServerId
    }

    private var selectedServer: PairedServer? {
        if let activeServerId,
           let server = serverStore.servers.first(where: { $0.id == activeServerId }) {
            return server
        }
        return serverStore.servers.first
    }

    private var activeConnection: ServerConnection? {
        activeServerId.flatMap { coordinator.connection(for: $0) }
    }

    private var store: ServerResourceStore? {
        activeConnection?.serverResourceStore
    }

    private var presentation: ServerSkillListPresentation {
        ServerSkillListPresentation(
            skills: activeServerId.flatMap { store?.skills(forServer: $0) } ?? [],
            query: searchText
        )
    }

    private var catalogState: ServerSkillCatalogPresentationState {
        guard let activeServerId, let store else {
            return .unavailable
        }
        let sync = store.syncState(for: .skills, serverId: activeServerId)
        return .resolve(
            hasLoaded: store.hasLoadedSkills(forServer: activeServerId),
            isSyncing: sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasVisibleRows: !presentation.visibleSkills.isEmpty,
            isFilteredNoResults: presentation.isFilteredNoResults
        )
    }

    var body: some View {
        List {
            if let selectedServer {
                Section {
                    ServerCatalogServerRow(selectedServer: selectedServer) { server in
                        searchText = ""
                        await refresh(serverId: server.id)
                    }
                    .listRowBackground(theme.bg.primary)
                }
            }

            if catalogState == .cachedOffline, let selectedServer {
                Section {
                    Label(
                        "Showing cached settings for \(selectedServer.name). Pull to retry.",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("skills.cachedWarning")
                    .listRowBackground(theme.bg.primary)
                }
            }

            switch catalogState {
            case .firstLoad:
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading skills…")
                        Spacer()
                    }
                    .frame(minHeight: 88)
                    .listRowBackground(theme.bg.primary)
                }

            case .unavailable:
                Section {
                    unavailableState
                        .listRowBackground(theme.bg.primary)
                }

            case .empty:
                Section {
                    ContentUnavailableView(
                        "No Skills Found",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("Pi did not resolve any skills on \(selectedServer?.name ?? "this server").")
                    )
                    .listRowBackground(theme.bg.primary)
                }

            case .filteredNoResults:
                Section {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No skills match “\(presentation.query)”.")
                    )
                    .listRowBackground(theme.bg.primary)
                }

            case .cachedOffline, .content:
                ForEach(presentation.sections, id: \.kind) { section in
                    Section(section.kind.rawValue) {
                        ForEach(section.skills) { skill in
                            skillRow(skill)
                                .listRowBackground(theme.bg.primary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search skills")
        .refreshable {
            if let activeServerId {
                await refresh(serverId: activeServerId)
            }
        }
        .task(id: activeServerId) {
            guard let activeServerId else { return }
            await refresh(serverId: activeServerId)
        }
    }

    private var unavailableState: some View {
        ContentUnavailableView {
            Label("Skills Unavailable", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text("The selected server has no cached Skills catalog.")
        } actions: {
            Button("Retry") {
                guard let activeServerId else { return }
                Task { await refresh(serverId: activeServerId) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("skills.retry")
        }
    }

    private func skillRow(_ skill: ServerSkillSummary) -> some View {
        Button {
            guard let activeServerId else { return }
            navigation.openServerResourceDetail(ServerResourceDetailNavTarget(
                serverId: activeServerId,
                kind: .skill,
                resourceId: skill.id
            ))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.title3)
                    .foregroundStyle(.themeBlue)
                    .frame(width: 28)
                    .frame(minHeight: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.subheadline)
                            .foregroundStyle(.themeComment)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let packageName = skill.packageName {
                        Text(packageName)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(skill.provenance.label)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    resourceState(skill.state)
                }

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ServerSkillListPresentation.accessibilityLabel(for: skill))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("skills.row.\(skill.id)")
    }

    private func resourceState(_ state: ServerSkillState) -> some View {
        let label = ServerSkillListPresentation.stateLabel(for: state)
        return Label(
            label,
            systemImage: state == .error || state == .unknown
                ? "exclamationmark.triangle.fill"
                : (state == .enabled ? "checkmark.circle" : "minus.circle")
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(state == .error || state == .unknown ? .themeOrange : .themeComment)
        .accessibilityLabel(label)
    }

    private func refresh(serverId: String) async {
        guard let connection = coordinator.connection(for: serverId),
              let api = connection.apiClient else { return }
        connection.serverResourceStore.switchServer(to: serverId)
        await connection.serverResourceStore.load(serverId: serverId, api: api)
    }
}
