import SwiftUI

struct ServerExtensionsView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var searchText = ""

    private var activeServerId: String? { coordinator.activeServerId }

    private var selectedServer: PairedServer? {
        if let activeServerId,
           let server = serverStore.servers.first(where: { $0.id == activeServerId }) {
            return server
        }
        return serverStore.servers.first
    }

    private var connection: ServerConnection? {
        activeServerId.flatMap { coordinator.connection(for: $0) }
    }

    private var store: ServerResourceStore? { connection?.serverResourceStore }

    private var presentation: ServerExtensionListPresentation {
        ServerExtensionListPresentation(
            extensions: activeServerId.flatMap { store?.extensions(forServer: $0) } ?? [],
            query: searchText
        )
    }

    private var catalogState: ServerExtensionCatalogPresentationState {
        guard let activeServerId, let store else { return .unavailable }
        let sync = store.syncState(for: .extensions, serverId: activeServerId)
        return .resolve(
            hasLoaded: store.hasLoadedExtensions(forServer: activeServerId),
            lastSyncFailed: sync.lastSyncFailed,
            hasVisibleRows: !presentation.visibleExtensions.isEmpty,
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
                    .accessibilityIdentifier("extensions.cachedWarning")
                    .listRowBackground(theme.bg.primary)
                }
            }

            switch catalogState {
            case .firstLoad:
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading extensions…")
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

            case .filteredNoResults:
                Section {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No extensions match “\(presentation.query)”.")
                    )
                    .listRowBackground(theme.bg.primary)
                }

            case .cachedOffline, .content:
                ForEach(presentation.sections, id: \.kind) { section in
                    Section(section.kind.rawValue) {
                        ForEach(section.extensions) { resource in
                            extensionRow(resource)
                                .listRowBackground(theme.bg.primary)
                        }
                    }
                }

                if presentation.hasNoPiExtensions {
                    Section {
                        ContentUnavailableView(
                            "No Pi Extensions Found",
                            systemImage: "puzzlepiece.extension",
                            description: Text("Oppi is available above as a built-in extension.")
                        )
                        .listRowBackground(theme.bg.primary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("Extensions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search extensions")
        .refreshable {
            if let activeServerId { await refresh(serverId: activeServerId) }
        }
        .task(id: activeServerId) {
            guard let activeServerId else { return }
            await refresh(serverId: activeServerId)
        }
    }

    private var unavailableState: some View {
        ContentUnavailableView {
            Label("Extensions Unavailable", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text("The selected server has no cached Extensions catalog.")
        } actions: {
            Button("Retry") {
                guard let activeServerId else { return }
                Task { await refresh(serverId: activeServerId) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("extensions.retry")
        }
    }

    private func extensionRow(_ resource: ServerExtensionSummary) -> some View {
        Button {
            guard let activeServerId else { return }
            navigation.openServerResourceDetail(ServerResourceDetailNavTarget(
                serverId: activeServerId,
                kind: .extension,
                resourceId: resource.id
            ))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: resource.kind == .builtIn ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                    .font(.title3)
                    .foregroundStyle(.themeBlue)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(resource.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let description = resource.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.themeComment)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let packageName = resource.packageName {
                        Text(packageName)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(resource.provenance.label)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    extensionState(resource.state)
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
        .accessibilityLabel(ServerExtensionListPresentation.accessibilityLabel(for: resource))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("extensions.row.\(resource.id)")
    }

    private func extensionState(_ state: ServerExtensionState) -> some View {
        let label = ServerExtensionListPresentation.stateLabel(for: state)
        return Label(
            label,
            systemImage: state == .error || state == .unknown
                ? "exclamationmark.triangle.fill"
                : (state == .on ? "checkmark.circle" : "minus.circle")
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
