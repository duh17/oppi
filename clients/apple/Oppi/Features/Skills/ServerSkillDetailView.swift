import SwiftUI

/// Owns one detail request generation so a canceled or superseded response
/// cannot replace a newer resource summary or content.
@MainActor @Observable
final class ServerResourceDetailLoader<Detail> {
    private(set) var target: ServerResourceDetailNavTarget
    private(set) var detail: Detail?
    private(set) var isLoading: Bool
    private(set) var error: String?
    private(set) var usesDetailSummary: Bool

    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(initialDetail: Detail? = nil, target: ServerResourceDetailNavTarget) {
        self.target = target
        self.detail = initialDetail
        self.isLoading = initialDetail == nil
        self.usesDetailSummary = initialDetail != nil
    }

    func load(
        target: ServerResourceDetailNavTarget,
        fetch: @escaping @MainActor () async throws -> Detail
    ) {
        task?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let targetChanged = self.target != target
        self.target = target
        if targetChanged {
            detail = nil
            usesDetailSummary = false
        }
        isLoading = detail == nil
        error = nil

        task = Task { @MainActor [weak self] in
            do {
                let response = try await fetch()
                guard !Task.isCancelled,
                      let self,
                      self.generation == requestGeneration,
                      self.target == target else {
                    return
                }
                self.detail = response
                self.usesDetailSummary = true
                self.error = nil
                self.isLoading = false
                self.task = nil
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.generation == requestGeneration,
                      self.target == target else {
                    return
                }
                self.error = error.localizedDescription
                self.isLoading = false
                self.task = nil
            }
        }
    }

    /// A successful catalog mutation is authoritative until a later detail GET succeeds.
    func invalidateSummaryAfterAuthoritativeMutation() {
        usesDetailSummary = false
        error = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
        isLoading = false
    }
}

enum ServerResourceDetailLoadError: LocalizedError {
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let serverName):
            "Not connected to \(serverName)."
        }
    }
}

struct ServerSkillDetailScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: ServerResourceDetailNavTarget

    @State private var scopedConnection: ServerConnection?
    @State private var connectionGeneration: UInt64 = 0

    var body: some View {
        Group {
            if let scopedConnection {
                ServerSkillDetailView(target: target)
                    .withServerScopedEnvironment(scopedConnection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .foregroundStyle(.themeFg)
        .tint(.themeBlue)
        .themedScrollSurface()
        .task(id: target) { await resolveConnection() }
    }

    private func resolveConnection() async {
        connectionGeneration &+= 1
        let requestGeneration = connectionGeneration
        scopedConnection = nil
        guard target.kind == .skill,
              await coordinator.switchToServerReady(target.serverId),
              !Task.isCancelled,
              connectionGeneration == requestGeneration else {
            return
        }
        scopedConnection = coordinator.connection(for: target.serverId)
    }
}

struct ServerSkillDetailView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerResourceStore.self) private var store
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation

    let target: ServerResourceDetailNavTarget

    @State private var loader: ServerResourceDetailLoader<ServerSkillDetail>
    @State private var mutationVerb: String?

    init(target: ServerResourceDetailNavTarget) {
        self.target = target
        _loader = State(initialValue: ServerResourceDetailLoader(target: target))
    }

    private var detail: ServerSkillDetail? { loader.detail }
    private var isLoading: Bool { loader.isLoading }
    private var loadError: String? { loader.error }

    private var serverName: String {
        serverStore.server(for: target.serverId)?.name ?? "this server"
    }

    private var summary: ServerSkillSummary? {
        resolvedServerSkillDetailSummary(
            catalogSummary: store.skills(forServer: target.serverId).first { $0.id == target.resourceId },
            freshDetail: loader.usesDetailSummary ? detail : nil
        )
    }

    private var mutationKey: ServerResourceMutationKey {
        .skill(target.resourceId)
    }

    private var isPending: Bool {
        store.isMutationPending(mutationKey, serverId: target.serverId)
    }

    private var mutationsAllowed: Bool {
        store.mutationsAllowed(for: .skills, serverId: target.serverId)
    }

    var body: some View {
        List {
            if let summary {
                identitySection(summary)
                observedUsageSection
                globalEnableSection(summary)
                provenanceSection(summary)
                validationSection(summary)

                if isLoading && detail == nil {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading skill contents…")
                            Spacer()
                        }
                        .frame(minHeight: 72)
                        .themedListRowBackground()
                    }
                    .themedListRowBackground()
                }

                if let detail {
                    Section("Contents") {
                        Button {
                            navigation.openServerSkillBrowser(ServerSkillBrowserNavTarget(
                                serverId: target.serverId,
                                resourceId: target.resourceId
                            ))
                        } label: {
                            HStack(spacing: 12) {
                                Label("Browse Files", systemImage: "folder")
                                    .foregroundStyle(.themeFg)
                                Spacer(minLength: 8)
                                Text("\(detail.files.count)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.themeComment)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.themeComment)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Browse \(summary.name) files")
                        .accessibilityValue(fileCountLabel(detail.files.count))
                        .accessibilityIdentifier("skills.files.open")
                        .themedListRowBackground()
                    }
                    .themedListRowBackground()
                }

            } else if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading skill…")
                        Spacer()
                    }
                    .frame(minHeight: 100)
                    .themedListRowBackground()
                }
                .themedListRowBackground()
            } else {
                Section {
                    ContentUnavailableView {
                        Label("Skill Unavailable", systemImage: "exclamationmark.triangle.fill")
                    } description: {
                        Text(loadError ?? "The skill could not be loaded.")
                    } actions: {
                        Button("Retry") { startLoad() }
                            .buttonStyle(.borderedProminent)
                    }
                    .themedListRowBackground()
                }
                .themedListRowBackground()
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
        .foregroundStyle(.themeFg)
        .tint(.themeBlue)
        .navigationTitle(summary?.name ?? "Skill")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: target) { startLoad() }
        .onDisappear { loader.cancel() }
    }

    private func identitySection(_ summary: ServerSkillSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.themeFg)
                if !summary.description.isEmpty {
                    Text(summary.description)
                        .font(.body)
                        .foregroundStyle(.themeComment)
                }
            }
            .padding(.vertical, 4)
            .themedListRowBackground()
        }
        .themedListRowBackground()
    }

    private var observedUsageSection: some View {
        ObservedUsageSection(
            requestKey: ResourceUsageRequestKey(
                serverId: target.serverId,
                subject: ResourceUsageSubject(kind: .skill, id: target.resourceId)
            )
        ) { range, timezone in
            guard let apiClient else {
                throw ResourceUsageLoadError.notConnected
            }
            return try await apiClient.getServerSkillUsage(
                id: target.resourceId,
                range: range,
                timezone: timezone
            )
        }
    }

    private func globalEnableSection(_ summary: ServerSkillSummary) -> some View {
        Section("Server Default") {
            HStack(alignment: .center, spacing: 10) {
                Toggle("Global Enable", isOn: Binding(
                    get: { summary.state == .enabled },
                    set: { enabled in
                        mutationVerb = enabled ? "enable" : "disable"
                        Task { await setEnabled(enabled) }
                    }
                ))
                .disabled(isPending || !mutationsAllowed || summary.state == .error || summary.state == .unknown)
                .accessibilityLabel("Enable \(summary.name) on \(serverName)")

                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving")
                }
            }
            .themedListRowBackground()

            if let error = store.mutationError(for: mutationKey, serverId: target.serverId) {
                Label(
                    "Couldn’t \(mutationVerb ?? "update") \(summary.name) on \(serverName). \(error)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.themeOrange)
                .themedListRowBackground()
            }
        }
        .themedListRowBackground()
    }

    private func provenanceSection(_ summary: ServerSkillSummary) -> some View {
        Section("Source") {
            if let packageName = summary.packageName {
                LabeledContent("Package", value: packageName)
                    .themedListRowBackground()
            }
            LabeledContent("Provenance", value: summary.provenance.label)
                .themedListRowBackground()
            LabeledContent("Scope", value: "Server default")
                .themedListRowBackground()
            LabeledContent("Files", value: summary.editable ? "Editable in session" : "Read-only")
                .themedListRowBackground()
        }
        .themedListRowBackground()
    }

    private func validationSection(_ summary: ServerSkillSummary) -> some View {
        let hasError = summary.state == .error || summary.state == .unknown
        return Section("Validation") {
            Label(
                hasError ? "Error" : "Loaded",
                systemImage: hasError ? "exclamationmark.triangle.fill" : "checkmark.circle"
            )
            .themedListRowBackground()

            if let error = summary.loadError ?? loadError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.themeOrange)
                    .themedListRowBackground()
            }

            ForEach(summary.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .themedListRowBackground()
            }

            if hasError || loadError != nil {
                Button("Retry") { startLoad() }
                    .themedListRowBackground()
            }
        }
        .themedListRowBackground()
    }

    private func startLoad() {
        let apiClient = apiClient
        let serverName = serverName
        loader.load(target: target) {
            guard let apiClient else {
                throw ServerResourceDetailLoadError.notConnected(serverName)
            }
            return try await apiClient.getServerSkill(id: target.resourceId)
        }
    }

    private func setEnabled(_ enabled: Bool) async {
        guard let apiClient else { return }
        await store.setSkillEnabled(
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

    private func fileCountLabel(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
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
