import SwiftUI

struct ServerResourceDetailDestinationView: View {
    let target: ServerResourceDetailNavTarget

    var body: some View {
        switch target.kind {
        case .skill:
            ServerSkillDetailScopedDestinationView(target: target)
        case .extension:
            ServerExtensionDetailScopedDestinationView(target: target)
        }
    }
}

struct ServerExtensionDetailScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: ServerResourceDetailNavTarget

    @State private var scopedConnection: ServerConnection?
    @State private var resolvedDetail: ServerExtensionDetail?
    @State private var resolutionError: String?
    @State private var resolutionGeneration: UInt64 = 0

    private var summary: ServerExtensionSummary? {
        scopedConnection?.serverResourceStore
            .extensions(forServer: target.serverId)
            .first { $0.id == target.resourceId }
            ?? resolvedDetail?.summary
    }

    var body: some View {
        Group {
            if let scopedConnection, let summary {
                if summary.isBuiltInOppi {
                    OppiExtensionDetailView(target: target)
                        .withServerScopedEnvironment(scopedConnection)
                } else {
                    ServerExtensionDetailView(target: target, initialDetail: resolvedDetail)
                        .withServerScopedEnvironment(scopedConnection)
                }
            } else if let resolutionError {
                ContentUnavailableView(
                    "Extension Unavailable",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(resolutionError)
                )
            } else {
                ProgressView("Loading extension…")
            }
        }
        .task(id: target) { await resolve() }
    }

    private func resolve() async {
        resolutionGeneration &+= 1
        let requestGeneration = resolutionGeneration
        scopedConnection = nil
        resolvedDetail = nil
        resolutionError = nil

        guard target.kind == .extension,
              await coordinator.switchToServerReady(target.serverId),
              !Task.isCancelled,
              resolutionGeneration == requestGeneration,
              let connection = coordinator.connection(for: target.serverId) else {
            return
        }
        scopedConnection = connection

        if connection.serverResourceStore.extensions(forServer: target.serverId)
            .contains(where: { $0.id == target.resourceId }) {
            return
        }

        guard let api = connection.apiClient else {
            resolutionError = "Not connected"
            return
        }
        do {
            let response = try await api.getServerExtension(id: target.resourceId)
            guard !Task.isCancelled, resolutionGeneration == requestGeneration else { return }
            resolvedDetail = response
        } catch {
            guard !Task.isCancelled, resolutionGeneration == requestGeneration else { return }
            resolutionError = error.localizedDescription
        }
    }
}

struct ServerExtensionDetailView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerResourceStore.self) private var store
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.theme) private var theme

    let target: ServerResourceDetailNavTarget

    @State private var loader: ServerResourceDetailLoader<ServerExtensionDetail>
    @State private var mutationVerb: String?

    init(target: ServerResourceDetailNavTarget, initialDetail: ServerExtensionDetail? = nil) {
        self.target = target
        _loader = State(initialValue: ServerResourceDetailLoader(
            initialDetail: initialDetail,
            target: target
        ))
    }

    private var detail: ServerExtensionDetail? { loader.detail }
    private var isLoading: Bool { loader.isLoading }
    private var loadError: String? { loader.error }

    private var summary: ServerExtensionSummary? {
        resolvedServerExtensionDetailSummary(
            catalogSummary: store.extensions(forServer: target.serverId).first { $0.id == target.resourceId },
            freshDetail: loader.usesDetailSummary ? detail : nil
        )
    }

    private var serverName: String {
        serverStore.server(for: target.serverId)?.name ?? "this server"
    }

    private var mutationKey: ServerResourceMutationKey {
        .normalExtension(target.resourceId)
    }

    private var isPending: Bool {
        store.isMutationPending(mutationKey, serverId: target.serverId)
    }

    var body: some View {
        List {
            if let summary {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.themeFg)
                        if let description = summary.description, !description.isEmpty {
                            Text(description)
                                .font(.body)
                                .foregroundStyle(.themeComment)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(theme.bg.primary)
                }

                Section("Server Default") {
                    HStack(spacing: 10) {
                        Toggle("Global Enable", isOn: Binding(
                            get: { summary.state == .on },
                            set: { enabled in
                                mutationVerb = enabled ? "enable" : "disable"
                                Task { await setEnabled(enabled) }
                            }
                        ))
                        .disabled(
                            isPending
                                || !store.mutationsAllowed(for: .extensions, serverId: target.serverId)
                                || summary.state == .error
                                || summary.state == .unknown
                        )
                        .accessibilityLabel("Enable \(summary.name) on \(serverName)")

                        if isPending {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Saving")
                        }
                    }
                    .listRowBackground(theme.bg.primary)

                    if let error = store.mutationError(for: mutationKey, serverId: target.serverId) {
                        Label(
                            "Couldn’t \(mutationVerb ?? "update") \(summary.name) on \(serverName). \(error)",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.themeOrange)
                        .listRowBackground(theme.bg.primary)
                    }
                }

                Section("Source") {
                    if let packageName = summary.packageName {
                        LabeledContent("Package", value: packageName)
                            .listRowBackground(theme.bg.primary)
                    }
                    LabeledContent("Provenance", value: summary.provenance.label)
                        .listRowBackground(theme.bg.primary)
                    LabeledContent("Kind", value: ServerExtensionListPresentation.kindLabel(for: summary.kind))
                        .listRowBackground(theme.bg.primary)
                    LabeledContent("Scope", value: "Server default")
                        .listRowBackground(theme.bg.primary)
                }

                Section("Status") {
                    Label(
                        ServerExtensionListPresentation.stateLabel(for: summary.state),
                        systemImage: summary.state == .error || summary.state == .unknown
                            ? "exclamationmark.triangle.fill"
                            : (summary.state == .on ? "checkmark.circle" : "minus.circle")
                    )
                    .listRowBackground(theme.bg.primary)

                    if let error = summary.loadError ?? loadError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.themeOrange)
                            .listRowBackground(theme.bg.primary)
                    }

                    ForEach(summary.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .listRowBackground(theme.bg.primary)
                    }

                    if summary.state == .error || loadError != nil {
                        Button("Retry") { startLoad() }
                            .listRowBackground(theme.bg.primary)
                    }
                }

                if isLoading && detail == nil {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading contributions…")
                            Spacer()
                        }
                        .frame(minHeight: 72)
                        .listRowBackground(theme.bg.primary)
                    }
                }

                if let tools = detail?.contributedTools, !tools.isEmpty {
                    contributionSection("Contributed Tools", values: tools)
                }
                if let commands = detail?.contributedCommands, !commands.isEmpty {
                    contributionSection("Contributed Commands", values: commands)
                }

                Section {
                    Text("New sessions use this setting. Reload an active session to apply it now.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                        .listRowBackground(theme.bg.primary)
                }
            } else if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading extension…")
                        Spacer()
                    }
                    .frame(minHeight: 100)
                    .listRowBackground(theme.bg.primary)
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label("Extension Unavailable", systemImage: "exclamationmark.triangle.fill")
                    } description: {
                        Text(loadError ?? "The extension could not be loaded.")
                    } actions: {
                        Button("Retry") { startLoad() }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(theme.bg.primary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle(summary?.name ?? "Extension")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: target) { startLoad() }
        .onDisappear { loader.cancel() }
    }

    private func contributionSection(_ title: String, values: [String]) -> some View {
        Section(title) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .textSelection(.enabled)
                    .listRowBackground(theme.bg.primary)
            }
        }
    }

    private func startLoad() {
        let apiClient = apiClient
        let serverName = serverName
        loader.load(target: target) {
            guard let apiClient else {
                throw ServerResourceDetailLoadError.notConnected(serverName)
            }
            return try await apiClient.getServerExtension(id: target.resourceId)
        }
    }

    private func setEnabled(_ enabled: Bool) async {
        guard let apiClient else { return }
        await store.setExtensionEnabled(
            id: target.resourceId,
            enabled: enabled,
            serverId: target.serverId,
            api: apiClient
        )
        if store.mutationError(for: mutationKey, serverId: target.serverId) == nil {
            loader.invalidateSummaryAfterAuthoritativeMutation()
            startLoad()
        }
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
