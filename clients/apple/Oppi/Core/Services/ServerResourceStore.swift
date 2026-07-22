import Foundation

/// Cache value for independently trustworthy server-global Skills and Extensions snapshots.
struct ServerResourceCatalogSnapshot: Codable, Sendable, Equatable {
    let skills: [ServerSkillSummary]
    let extensions: [ServerExtensionSummary]
    let oppiConfiguration: OppiExtensionConfiguration?
    let savedAt: Date
    let skillsLoaded: Bool
    let extensionsLoaded: Bool
    let skillsSavedAt: Date?
    let extensionsSavedAt: Date?
    /// A retained Oppi revision is display-only until a full Extensions refresh succeeds.
    let oppiRequiresAuthoritativeRefresh: Bool

    /// Source-compatible complete snapshot initializer and legacy cache shape.
    init(
        skills: [ServerSkillSummary],
        extensions: [ServerExtensionSummary],
        oppiConfiguration: OppiExtensionConfiguration,
        savedAt: Date
    ) {
        self.init(
            skills: skills,
            extensions: extensions,
            oppiConfiguration: oppiConfiguration,
            savedAt: savedAt,
            skillsLoaded: true,
            extensionsLoaded: true,
            skillsSavedAt: savedAt,
            extensionsSavedAt: savedAt,
            oppiRequiresAuthoritativeRefresh: false
        )
    }

    init(
        skills: [ServerSkillSummary],
        extensions: [ServerExtensionSummary],
        oppiConfiguration: OppiExtensionConfiguration?,
        savedAt: Date,
        skillsLoaded: Bool,
        extensionsLoaded: Bool,
        skillsSavedAt: Date?,
        extensionsSavedAt: Date?,
        oppiRequiresAuthoritativeRefresh: Bool = false
    ) {
        self.skills = skills
        self.extensions = extensions
        self.oppiConfiguration = oppiConfiguration
        self.savedAt = savedAt
        self.skillsLoaded = skillsLoaded
        self.extensionsLoaded = extensionsLoaded && oppiConfiguration != nil
        self.skillsSavedAt = skillsLoaded ? skillsSavedAt : nil
        self.extensionsSavedAt = self.extensionsLoaded ? extensionsSavedAt : nil
        self.oppiRequiresAuthoritativeRefresh = oppiRequiresAuthoritativeRefresh
    }

    private enum CodingKeys: String, CodingKey {
        case skills
        case extensions
        case oppiConfiguration
        case savedAt
        case skillsLoaded
        case extensionsLoaded
        case skillsSavedAt
        case extensionsSavedAt
        case oppiRequiresAuthoritativeRefresh
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let skills = try container.decode([ServerSkillSummary].self, forKey: .skills)
        let extensions = try container.decode([ServerExtensionSummary].self, forKey: .extensions)
        let configuration = try container.decodeIfPresent(
            OppiExtensionConfiguration.self,
            forKey: .oppiConfiguration
        )
        let savedAt = try container.decode(Date.self, forKey: .savedAt)
        let skillsLoaded = try container.decodeIfPresent(Bool.self, forKey: .skillsLoaded) ?? true
        let extensionsLoaded = try container.decodeIfPresent(Bool.self, forKey: .extensionsLoaded) ?? true
        self.init(
            skills: skills,
            extensions: extensions,
            oppiConfiguration: configuration,
            savedAt: savedAt,
            skillsLoaded: skillsLoaded,
            extensionsLoaded: extensionsLoaded,
            skillsSavedAt: try container.decodeIfPresent(Date.self, forKey: .skillsSavedAt)
                ?? (skillsLoaded ? savedAt : nil),
            extensionsSavedAt: try container.decodeIfPresent(Date.self, forKey: .extensionsSavedAt)
                ?? (extensionsLoaded ? savedAt : nil),
            oppiRequiresAuthoritativeRefresh: try container.decodeIfPresent(
                Bool.self,
                forKey: .oppiRequiresAuthoritativeRefresh
            ) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(skills, forKey: .skills)
        try container.encode(extensions, forKey: .extensions)
        try container.encodeIfPresent(oppiConfiguration, forKey: .oppiConfiguration)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encode(skillsLoaded, forKey: .skillsLoaded)
        try container.encode(extensionsLoaded, forKey: .extensionsLoaded)
        try container.encodeIfPresent(skillsSavedAt, forKey: .skillsSavedAt)
        try container.encodeIfPresent(extensionsSavedAt, forKey: .extensionsSavedAt)
        try container.encode(oppiRequiresAuthoritativeRefresh, forKey: .oppiRequiresAuthoritativeRefresh)
    }
}

enum ServerResourceCatalogKind: Hashable, Sendable {
    case skills
    case extensions
}

enum ServerResourceMutationKey: Hashable, Sendable {
    case skill(String)
    case normalExtension(String)
    case oppiEnabled
    case oppiApprovalPolicy
}

/// Independent, server-scoped state for global Pi Skills and Extensions.
///
/// This deliberately has no dependency on workspace or session stores. Every
/// operation is keyed by server fingerprint so a response for one server can
/// never overwrite another server's catalog.
@MainActor @Observable
final class ServerResourceStore {
    typealias SkillsRequest = @MainActor () async throws -> [ServerSkillSummary]
    typealias ExtensionsRequest = @MainActor () async throws -> ServerExtensionCatalog
    typealias SkillMutationRequest = @MainActor (String, Bool) async throws -> ServerSkillSummary
    typealias ExtensionMutationRequest = @MainActor (String, Bool) async throws -> ServerExtensionSummary
    typealias OppiMutationRequest = @MainActor (Bool, OppiApprovalPolicy, Int) async throws -> OppiExtensionConfiguration
    typealias OppiConfigurationRequest = @MainActor () async throws -> OppiExtensionConfiguration

    private struct Partition {
        var skills: [ServerSkillSummary] = []
        var extensions: [ServerExtensionSummary] = []
        var authoritativeOppiConfiguration: OppiExtensionConfiguration?
        var desiredOppiConfiguration: OppiExtensionConfiguration?
        var skillsLoaded = false
        var extensionsLoaded = false
        var skillsSync = ServerSyncState()
        var extensionsSync = ServerSyncState()
        var errors: [ServerResourceMutationKey: String] = [:]
        var pendingMutations: Set<ServerResourceMutationKey> = []
        var mutationGenerations: [ServerResourceMutationKey: UInt64] = [:]
        /// Authoritative rows retained while the corresponding UI row is optimistic.
        var skillRollbackValues: [String: ServerSkillSummary] = [:]
        var extensionRollbackValues: [String: ServerExtensionSummary] = [:]
        /// Per-resource ordering versions advance at optimistic start and settlement.
        /// A refresh may replace a row only when its start version is still current.
        var normalResourceVersions: [ServerResourceMutationKey: UInt64] = [:]
        var skillsGeneration: UInt64 = 0
        var extensionsGeneration: UInt64 = 0
        /// Full-CAS intent and settlement ordering; refresh never advances this version.
        var oppiOrderingVersion: UInt64 = 0
        var oppiWriteInFlight = false
        /// A 409 made the retained revision untrustworthy and the authoritative refetch failed.
        var oppiRequiresAuthoritativeRefresh = false
    }

    private let cache: TimelineCache
    private let now: @MainActor () -> Date
    private var partitions: [String: Partition] = [:]
    private(set) var activeServerId: String?

    init(
        cache: TimelineCache = .shared,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.cache = cache
        self.now = now
    }

    // MARK: - Server context and read API

    func switchServer(to serverId: String) {
        activeServerId = serverId
        ensurePartition(for: serverId)
    }

    func skills(forServer serverId: String) -> [ServerSkillSummary] {
        partitions[serverId]?.skills ?? []
    }

    func extensions(forServer serverId: String) -> [ServerExtensionSummary] {
        partitions[serverId]?.extensions ?? []
    }

    func oppiConfiguration(forServer serverId: String) -> OppiExtensionConfiguration? {
        let partition = partitions[serverId]
        return partition?.desiredOppiConfiguration ?? partition?.authoritativeOppiConfiguration
    }

    func hasLoadedSkills(forServer serverId: String) -> Bool {
        partitions[serverId]?.skillsLoaded ?? false
    }

    func hasLoadedExtensions(forServer serverId: String) -> Bool {
        partitions[serverId]?.extensionsLoaded ?? false
    }

    func syncState(for kind: ServerResourceCatalogKind, serverId: String) -> ServerSyncState {
        let partition = partitions[serverId]
        switch kind {
        case .skills:
            return partition?.skillsSync ?? ServerSyncState()
        case .extensions:
            return partition?.extensionsSync ?? ServerSyncState()
        }
    }

    func mutationsAllowed(for kind: ServerResourceCatalogKind, serverId: String) -> Bool {
        let partition = partitions[serverId]
        switch kind {
        case .skills:
            return partition?.skillsLoaded == true && partition?.skillsSync.lastSyncFailed != true
        case .extensions:
            return partition?.extensionsLoaded == true
                && partition?.extensionsSync.lastSyncFailed != true
                && partition?.oppiRequiresAuthoritativeRefresh != true
        }
    }

    func isMutationPending(_ key: ServerResourceMutationKey, serverId: String) -> Bool {
        partitions[serverId]?.pendingMutations.contains(key) ?? false
    }

    func mutationError(for key: ServerResourceMutationKey, serverId: String) -> String? {
        partitions[serverId]?.errors[key]
    }

    func requiresAuthoritativeOppiRefresh(forServer serverId: String) -> Bool {
        partitions[serverId]?.oppiRequiresAuthoritativeRefresh ?? false
    }

    // MARK: - Loading

    /// Shows a cached aggregate first, then independently refreshes Skills and Extensions.
    /// A failure in one catalog never erases or marks the other catalog offline.
    func load(
        serverId: String,
        fetchSkills: @escaping SkillsRequest,
        fetchExtensions: @escaping ExtensionsRequest
    ) async {
        ensurePartition(for: serverId)
        await loadCachedCatalogIfNeeded(serverId: serverId)

        let skillsGeneration = nextSkillsGeneration(for: serverId)
        let extensionsGeneration = nextExtensionsGeneration(for: serverId)
        // A superseding refresh may begin while an older generation is syncing.
        // Rollback must capture the underlying stable state, never that transient flag.
        let skillsSyncBeforeRefresh = Self.stableSyncState(
            partitions[serverId]?.skillsSync ?? ServerSyncState()
        )
        let extensionsSyncBeforeRefresh = Self.stableSyncState(
            partitions[serverId]?.extensionsSync ?? ServerSyncState()
        )
        let skillsStartVersions = partitions[serverId]?.normalResourceVersions ?? [:]
        let extensionsStartVersions = partitions[serverId]?.normalResourceVersions ?? [:]
        let oppiStartVersion = partitions[serverId]?.oppiOrderingVersion ?? 0
        update(serverId) {
            $0.skillsSync.markSyncStarted()
            $0.extensionsSync.markSyncStarted()
        }

        async let skillsResult = Self.capture(fetchSkills)
        async let extensionsResult = Self.capture(fetchExtensions)
        let (resolvedSkills, resolvedExtensions) = await (skillsResult, extensionsResult)

        // View-owned refresh cancellation is neither an offline result nor a
        // partial refresh. Keep the cached snapshots and their exact prior
        // freshness state, provided no newer refresh replaced this generation.
        if Task.isCancelled {
            update(serverId) {
                if $0.skillsGeneration == skillsGeneration {
                    $0.skillsSync = skillsSyncBeforeRefresh
                }
                if $0.extensionsGeneration == extensionsGeneration {
                    $0.extensionsSync = Self.syncStateAfterCancellation(
                        capturedStableState: extensionsSyncBeforeRefresh,
                        currentState: $0.extensionsSync,
                        capturedOrderingVersion: oppiStartVersion,
                        currentOrderingVersion: $0.oppiOrderingVersion
                    )
                }
            }
            return
        }

        var shouldSaveCache = false
        switch resolvedSkills {
        case .success(let skills):
            if partitions[serverId]?.skillsGeneration == skillsGeneration {
                update(serverId) {
                    let mergedSkills = Self.mergeRefreshedSkills(
                        skills,
                        into: $0,
                        startVersions: skillsStartVersions
                    )
                    $0.skills = mergedSkills
                    $0.skillsLoaded = true
                    $0.skillsSync.markSyncSucceeded(at: now())
                }
                shouldSaveCache = true
            }
        case .failure(let error):
            if partitions[serverId]?.skillsGeneration == skillsGeneration {
                update(serverId) {
                    if Self.isCancellation(error) {
                        $0.skillsSync = skillsSyncBeforeRefresh
                    } else {
                        $0.skillsSync.markSyncFailed()
                    }
                }
            }
        }

        switch resolvedExtensions {
        case .success(let catalog):
            if partitions[serverId]?.extensionsGeneration == extensionsGeneration {
                update(serverId) {
                    let preserveOppi = Self.shouldPreserveOppiDuringRefresh(
                        $0,
                        startVersion: oppiStartVersion
                    )
                    let mergedExtensions = Self.mergeRefreshedExtensions(
                        catalog.extensions,
                        into: $0,
                        startVersions: extensionsStartVersions,
                        preserveOppi: preserveOppi
                    )
                    $0.extensions = mergedExtensions
                    $0.extensionsLoaded = true
                    if !preserveOppi {
                        $0.authoritativeOppiConfiguration = catalog.oppiConfiguration
                        $0.desiredOppiConfiguration = catalog.oppiConfiguration
                        $0.oppiRequiresAuthoritativeRefresh = false
                        $0.errors.removeValue(forKey: .oppiEnabled)
                        $0.errors.removeValue(forKey: .oppiApprovalPolicy)
                    }
                    if $0.oppiRequiresAuthoritativeRefresh {
                        $0.extensionsSync.markSyncFailed()
                    } else {
                        $0.extensionsSync.markSyncSucceeded(at: now())
                    }
                    Self.applyOppiState(to: &$0)
                }
                shouldSaveCache = true
            }
        case .failure(let error):
            if partitions[serverId]?.extensionsGeneration == extensionsGeneration {
                update(serverId) {
                    if Self.isCancellation(error) {
                        $0.extensionsSync = Self.syncStateAfterCancellation(
                            capturedStableState: extensionsSyncBeforeRefresh,
                            currentState: $0.extensionsSync,
                            capturedOrderingVersion: oppiStartVersion,
                            currentOrderingVersion: $0.oppiOrderingVersion
                        )
                    } else {
                        $0.extensionsSync.markSyncFailed()
                    }
                }
            }
        }

        if shouldSaveCache {
            await saveCacheSnapshot(serverId: serverId)
        }
    }

    func load(serverId: String, api: APIClient) async {
        await load(
            serverId: serverId,
            fetchSkills: { try await api.listServerSkills() },
            fetchExtensions: { try await api.listServerExtensions() }
        )
    }

    // MARK: - Normal resource mutations

    func setSkillEnabled(
        id: String,
        enabled: Bool,
        serverId: String,
        request: @escaping SkillMutationRequest
    ) async {
        let key = ServerResourceMutationKey.skill(id)
        guard mutationsAllowed(for: .skills, serverId: serverId),
              let previous = skills(forServer: serverId).first(where: { $0.id == id }) else {
            setUnavailableMutationError(key, serverId: serverId)
            return
        }

        let mutationGeneration = beginMutation(key, serverId: serverId)
        update(serverId) {
            guard let index = $0.skills.firstIndex(where: { $0.id == id }) else { return }
            $0.skillRollbackValues[id] = previous
            $0.skills[index] = Self.skill($0.skills[index], state: enabled ? .enabled : .disabled)
        }

        let result = await Self.capture { try await request(id, enabled) }
        await completeNormalSkillMutation(
            result,
            previous: previous,
            id: id,
            key: key,
            mutationGeneration: mutationGeneration,
            serverId: serverId
        )
    }

    func setSkillEnabled(id: String, enabled: Bool, serverId: String, api: APIClient) async {
        await setSkillEnabled(
            id: id,
            enabled: enabled,
            serverId: serverId,
            request: { id, enabled in try await api.setServerSkillEnabled(id: id, enabled: enabled) }
        )
    }

    func setExtensionEnabled(
        id: String,
        enabled: Bool,
        serverId: String,
        request: @escaping ExtensionMutationRequest
    ) async {
        let key = ServerResourceMutationKey.normalExtension(id)
        guard mutationsAllowed(for: .extensions, serverId: serverId),
              let previous = extensions(forServer: serverId).first(where: { $0.id == id }),
              !previous.isBuiltInOppi else {
            setUnavailableMutationError(key, serverId: serverId)
            return
        }

        let mutationGeneration = beginMutation(key, serverId: serverId)
        update(serverId) {
            guard let index = $0.extensions.firstIndex(where: { $0.id == id }) else { return }
            $0.extensionRollbackValues[id] = previous
            $0.extensions[index] = Self.extension($0.extensions[index], state: enabled ? .on : .off)
        }

        let result = await Self.capture { try await request(id, enabled) }
        await completeNormalExtensionMutation(
            result,
            previous: previous,
            id: id,
            key: key,
            mutationGeneration: mutationGeneration,
            serverId: serverId
        )
    }

    func setExtensionEnabled(id: String, enabled: Bool, serverId: String, api: APIClient) async {
        await setExtensionEnabled(
            id: id,
            enabled: enabled,
            serverId: serverId,
            request: { id, enabled in try await api.setServerExtensionEnabled(id: id, enabled: enabled) }
        )
    }

    // MARK: - Oppi atomic configuration

    func setOppiEnabled(
        _ enabled: Bool,
        serverId: String,
        request: @escaping OppiMutationRequest,
        fetchAuthoritative: @escaping OppiConfigurationRequest
    ) async {
        await queueOppiChange(
            key: .oppiEnabled,
            serverId: serverId,
            request: request,
            fetchAuthoritative: fetchAuthoritative
        ) { configuration in
            OppiExtensionConfiguration(
                enabled: enabled,
                approvalPolicy: configuration.approvalPolicy,
                revision: configuration.revision
            )
        }
    }

    func setOppiEnabled(_ enabled: Bool, serverId: String, api: APIClient) async {
        await setOppiEnabled(
            enabled,
            serverId: serverId,
            request: { enabled, policy, revision in
                try await api.setOppiExtensionConfiguration(
                    enabled: enabled,
                    approvalPolicy: policy,
                    baseRevision: revision
                )
            },
            fetchAuthoritative: { try await api.getOppiExtensionConfiguration() }
        )
    }

    func setOppiApprovalPolicy(
        _ policy: OppiApprovalPolicy,
        serverId: String,
        request: @escaping OppiMutationRequest,
        fetchAuthoritative: @escaping OppiConfigurationRequest
    ) async {
        await queueOppiChange(
            key: .oppiApprovalPolicy,
            serverId: serverId,
            request: request,
            fetchAuthoritative: fetchAuthoritative
        ) { configuration in
            OppiExtensionConfiguration(
                enabled: configuration.enabled,
                approvalPolicy: policy,
                revision: configuration.revision
            )
        }
    }

    func setOppiApprovalPolicy(_ policy: OppiApprovalPolicy, serverId: String, api: APIClient) async {
        await setOppiApprovalPolicy(
            policy,
            serverId: serverId,
            request: { enabled, policy, revision in
                try await api.setOppiExtensionConfiguration(
                    enabled: enabled,
                    approvalPolicy: policy,
                    baseRevision: revision
                )
            },
            fetchAuthoritative: { try await api.getOppiExtensionConfiguration() }
        )
    }

    // MARK: - Test and composition helpers

    func replaceSkills(_ skills: [ServerSkillSummary], serverId: String) {
        update(serverId) {
            $0.skills = skills
            $0.skillsLoaded = true
            for skill in skills {
                Self.advanceNormalResourceVersion(.skill(skill.id), in: &$0)
            }
            $0.skillsSync.markSyncSucceeded(at: now())
        }
    }

    func replaceExtensions(
        _ extensions: [ServerExtensionSummary],
        oppiConfiguration: OppiExtensionConfiguration,
        serverId: String
    ) {
        update(serverId) {
            $0.extensions = extensions
            $0.extensionsLoaded = true
            for resource in extensions where !resource.isBuiltInOppi {
                Self.advanceNormalResourceVersion(.normalExtension(resource.id), in: &$0)
            }
            $0.extensionsSync.markSyncSucceeded(at: now())
            $0.authoritativeOppiConfiguration = oppiConfiguration
            $0.desiredOppiConfiguration = oppiConfiguration
            $0.oppiRequiresAuthoritativeRefresh = false
            $0.oppiOrderingVersion &+= 1
            Self.applyOppiState(to: &$0)
        }
    }

    // MARK: - Private loading helpers

    private func loadCachedCatalogIfNeeded(serverId: String) async {
        guard let partition = partitions[serverId],
              !partition.skillsLoaded || !partition.extensionsLoaded else {
            return
        }
        guard let snapshot = await cache.loadServerResourceCatalog(serverId: serverId) else { return }

        update(serverId) {
            if !$0.skillsLoaded, snapshot.skillsLoaded {
                $0.skills = snapshot.skills
                $0.skillsLoaded = true
                if let savedAt = snapshot.skillsSavedAt {
                    $0.skillsSync.markSyncSucceeded(at: savedAt)
                }
            }
            if !$0.extensionsLoaded,
               snapshot.extensionsLoaded,
               let configuration = snapshot.oppiConfiguration {
                $0.extensions = snapshot.extensions
                $0.extensionsLoaded = true
                $0.authoritativeOppiConfiguration = configuration
                $0.desiredOppiConfiguration = configuration
                if let savedAt = snapshot.extensionsSavedAt {
                    $0.extensionsSync.markSyncSucceeded(at: savedAt)
                }
                $0.oppiRequiresAuthoritativeRefresh = snapshot.oppiRequiresAuthoritativeRefresh
                if $0.oppiRequiresAuthoritativeRefresh {
                    $0.extensionsSync.markSyncFailed()
                }
                Self.applyOppiState(to: &$0)
            }
        }
    }

    private func saveCacheSnapshot(serverId: String) async {
        guard let initialPartition = partitions[serverId],
              initialPartition.skillsLoaded || initialPartition.extensionsLoaded else {
            return
        }

        // Merge with any trustworthy cached half that this in-memory partition has
        // not loaded. This prevents a write-through for one catalog from erasing
        // the independently persisted other catalog.
        let existing = await cache.loadServerResourceCatalog(serverId: serverId)
        guard let partition = partitions[serverId] else { return }

        var currentSkills = partition.skills
        for (id, authoritative) in partition.skillRollbackValues {
            if let index = currentSkills.firstIndex(where: { $0.id == id }) {
                currentSkills[index] = authoritative
            } else {
                currentSkills.append(authoritative)
            }
        }
        let skillsLoaded = partition.skillsLoaded || existing?.skillsLoaded == true
        let cachedSkills = partition.skillsLoaded ? currentSkills : (existing?.skills ?? [])
        let skillsSavedAt = partition.skillsLoaded
            ? (partition.skillsSync.lastSuccessfulSyncAt ?? existing?.skillsSavedAt ?? now())
            : existing?.skillsSavedAt

        var currentExtensions = partition.extensions
        for (id, authoritative) in partition.extensionRollbackValues {
            if let index = currentExtensions.firstIndex(where: { $0.id == id }) {
                currentExtensions[index] = authoritative
            } else {
                currentExtensions.append(authoritative)
            }
        }
        if let configuration = partition.authoritativeOppiConfiguration,
           let index = currentExtensions.firstIndex(where: \.isBuiltInOppi) {
            currentExtensions[index] = Self.extension(
                currentExtensions[index],
                state: configuration.enabled ? .on : .off
            )
        }
        let hasCurrentExtensions = partition.extensionsLoaded
            && partition.authoritativeOppiConfiguration != nil
        let extensionsLoaded = hasCurrentExtensions || existing?.extensionsLoaded == true
        let cachedExtensions = hasCurrentExtensions ? currentExtensions : (existing?.extensions ?? [])
        let cachedConfiguration = hasCurrentExtensions
            ? partition.authoritativeOppiConfiguration
            : existing?.oppiConfiguration
        let extensionsSavedAt = hasCurrentExtensions
            ? (partition.extensionsSync.lastSuccessfulSyncAt ?? existing?.extensionsSavedAt ?? now())
            : existing?.extensionsSavedAt
        let requiresAuthoritativeOppiRefresh = hasCurrentExtensions
            ? partition.oppiRequiresAuthoritativeRefresh
            : (existing?.oppiRequiresAuthoritativeRefresh ?? false)

        guard skillsLoaded || extensionsLoaded else { return }
        let savedAt = now()
        await cache.saveServerResourceCatalog(
            ServerResourceCatalogSnapshot(
                skills: cachedSkills,
                extensions: cachedExtensions,
                oppiConfiguration: cachedConfiguration,
                savedAt: savedAt,
                skillsLoaded: skillsLoaded,
                extensionsLoaded: extensionsLoaded,
                skillsSavedAt: skillsSavedAt,
                extensionsSavedAt: extensionsSavedAt,
                oppiRequiresAuthoritativeRefresh: requiresAuthoritativeOppiRefresh
            ),
            serverId: serverId
        )
    }

    // MARK: - Private mutation helpers

    private func completeNormalSkillMutation(
        _ result: Result<ServerSkillSummary, Error>,
        previous: ServerSkillSummary,
        id: String,
        key: ServerResourceMutationKey,
        mutationGeneration: UInt64,
        serverId: String
    ) async {
        guard partitions[serverId]?.mutationGenerations[key] == mutationGeneration else { return }
        update(serverId) { partition in
            partition.pendingMutations.remove(key)
            switch result {
            case .success(let authoritative):
                if let index = partition.skills.firstIndex(where: { $0.id == id }) {
                    partition.skills[index] = authoritative
                }
                partition.errors.removeValue(forKey: key)
            case .failure(let error):
                if let index = partition.skills.firstIndex(where: { $0.id == id }) {
                    partition.skills[index] = previous
                }
                partition.errors[key] = Self.errorText(error)
            }
            partition.skillRollbackValues.removeValue(forKey: id)
            Self.advanceNormalResourceVersion(key, in: &partition)
        }
        await saveCacheSnapshot(serverId: serverId)
    }

    private func completeNormalExtensionMutation(
        _ result: Result<ServerExtensionSummary, Error>,
        previous: ServerExtensionSummary,
        id: String,
        key: ServerResourceMutationKey,
        mutationGeneration: UInt64,
        serverId: String
    ) async {
        guard partitions[serverId]?.mutationGenerations[key] == mutationGeneration else { return }
        update(serverId) { partition in
            partition.pendingMutations.remove(key)
            switch result {
            case .success(let authoritative):
                if let index = partition.extensions.firstIndex(where: { $0.id == id }) {
                    partition.extensions[index] = authoritative
                }
                partition.errors.removeValue(forKey: key)
            case .failure(let error):
                if let index = partition.extensions.firstIndex(where: { $0.id == id }) {
                    partition.extensions[index] = previous
                }
                partition.errors[key] = Self.errorText(error)
            }
            partition.extensionRollbackValues.removeValue(forKey: id)
            Self.advanceNormalResourceVersion(key, in: &partition)
        }
        await saveCacheSnapshot(serverId: serverId)
    }

    private func queueOppiChange(
        key: ServerResourceMutationKey,
        serverId: String,
        request: @escaping OppiMutationRequest,
        fetchAuthoritative: @escaping OppiConfigurationRequest,
        change: (OppiExtensionConfiguration) -> OppiExtensionConfiguration
    ) async {
        guard mutationsAllowed(for: .extensions, serverId: serverId),
              let configuration = oppiConfiguration(forServer: serverId) else {
            return
        }

        let desiredConfiguration = change(configuration)
        guard !Self.sameOppiValues(desiredConfiguration, configuration) else {
            return
        }

        update(serverId) {
            $0.desiredOppiConfiguration = desiredConfiguration
            $0.pendingMutations.insert(key)
            $0.errors.removeValue(forKey: key)
            $0.oppiOrderingVersion &+= 1
            Self.applyOppiState(to: &$0)
        }
        await drainOppiWriteQueue(
            serverId: serverId,
            request: request,
            fetchAuthoritative: fetchAuthoritative
        )
    }

    private func drainOppiWriteQueue(
        serverId: String,
        request: @escaping OppiMutationRequest,
        fetchAuthoritative: @escaping OppiConfigurationRequest
    ) async {
        guard let partition = partitions[serverId], !partition.oppiWriteInFlight,
              let authoritative = partition.authoritativeOppiConfiguration,
              let desired = partition.desiredOppiConfiguration,
              !Self.sameOppiValues(desired, authoritative) else {
            return
        }

        update(serverId) { $0.oppiWriteInFlight = true }
        let result = await Self.capture {
            try await request(desired.enabled, desired.approvalPolicy, authoritative.revision)
        }

        switch result {
        case .success(let response):
            var shouldContinue = false
            update(serverId) { partition in
                partition.oppiWriteInFlight = false
                partition.authoritativeOppiConfiguration = response
                partition.oppiOrderingVersion &+= 1
                if partition.desiredOppiConfiguration?.enabled == response.enabled {
                    partition.pendingMutations.remove(.oppiEnabled)
                    partition.errors.removeValue(forKey: .oppiEnabled)
                }
                if partition.desiredOppiConfiguration?.approvalPolicy == response.approvalPolicy {
                    partition.pendingMutations.remove(.oppiApprovalPolicy)
                    partition.errors.removeValue(forKey: .oppiApprovalPolicy)
                }
                if let desired = partition.desiredOppiConfiguration,
                   Self.sameOppiValues(desired, response) {
                    partition.desiredOppiConfiguration = response
                } else {
                    shouldContinue = true
                }
                Self.applyOppiState(to: &partition)
            }
            await saveCacheSnapshot(serverId: serverId)
            if shouldContinue {
                await drainOppiWriteQueue(
                    serverId: serverId,
                    request: request,
                    fetchAuthoritative: fetchAuthoritative
                )
            }

        case .failure(let error):
            if Self.isRevisionConflict(error) {
                let refreshed = await Self.capture(fetchAuthoritative)
                update(serverId) { partition in
                    partition.oppiWriteInFlight = false
                    let pending = partition.pendingMutations.intersection([.oppiEnabled, .oppiApprovalPolicy])
                    let errorMessage: String
                    switch refreshed {
                    case .success(let configuration):
                        partition.authoritativeOppiConfiguration = configuration
                        partition.desiredOppiConfiguration = configuration
                        partition.oppiRequiresAuthoritativeRefresh = false
                        errorMessage = "Oppi setting changed elsewhere on the server."
                    case .failure(let refreshError):
                        partition.desiredOppiConfiguration = partition.authoritativeOppiConfiguration
                        partition.oppiRequiresAuthoritativeRefresh = true
                        partition.extensionsSync.markSyncFailed()
                        errorMessage = "Oppi setting changed elsewhere on the server. Couldn’t refresh the current setting: \(Self.errorText(refreshError))"
                    }
                    partition.oppiOrderingVersion &+= 1
                    partition.pendingMutations.subtract([.oppiEnabled, .oppiApprovalPolicy])
                    for key in pending {
                        partition.errors[key] = errorMessage
                    }
                    Self.applyOppiState(to: &partition)
                }
                await saveCacheSnapshot(serverId: serverId)
                return
            }

            update(serverId) { partition in
                partition.oppiWriteInFlight = false
                partition.desiredOppiConfiguration = partition.authoritativeOppiConfiguration
                partition.oppiOrderingVersion &+= 1
                let pending = partition.pendingMutations.intersection([.oppiEnabled, .oppiApprovalPolicy])
                partition.pendingMutations.subtract([.oppiEnabled, .oppiApprovalPolicy])
                for key in pending {
                    partition.errors[key] = Self.errorText(error)
                }
                Self.applyOppiState(to: &partition)
            }
            await saveCacheSnapshot(serverId: serverId)
        }
    }

    private func beginMutation(_ key: ServerResourceMutationKey, serverId: String) -> UInt64 {
        var generation: UInt64 = 0
        update(serverId) {
            generation = ($0.mutationGenerations[key] ?? 0) &+ 1
            $0.mutationGenerations[key] = generation
            Self.advanceNormalResourceVersion(key, in: &$0)
            $0.pendingMutations.insert(key)
            $0.errors.removeValue(forKey: key)
        }
        return generation
    }

    private func setUnavailableMutationError(_ key: ServerResourceMutationKey, serverId: String) {
        update(serverId) {
            $0.errors[key] = "Server catalog is offline. Retry before changing this setting."
        }
    }

    private func nextSkillsGeneration(for serverId: String) -> UInt64 {
        var generation: UInt64 = 0
        update(serverId) {
            $0.skillsGeneration &+= 1
            generation = $0.skillsGeneration
        }
        return generation
    }

    private func nextExtensionsGeneration(for serverId: String) -> UInt64 {
        var generation: UInt64 = 0
        update(serverId) {
            $0.extensionsGeneration &+= 1
            generation = $0.extensionsGeneration
        }
        return generation
    }

    private func ensurePartition(for serverId: String) {
        if partitions[serverId] == nil {
            partitions[serverId] = Partition()
        }
    }

    private func update(_ serverId: String, _ body: (inout Partition) -> Void) {
        var partition = partitions[serverId] ?? Partition()
        body(&partition)
        partitions[serverId] = partition
    }

    private static func stableSyncState(_ state: ServerSyncState) -> ServerSyncState {
        var stable = state
        stable.isSyncing = false
        return stable
    }

    private static func syncStateAfterCancellation(
        capturedStableState: ServerSyncState,
        currentState: ServerSyncState,
        capturedOrderingVersion: UInt64,
        currentOrderingVersion: UInt64
    ) -> ServerSyncState {
        guard currentOrderingVersion == capturedOrderingVersion else {
            return stableSyncState(currentState)
        }
        return capturedStableState
    }

    private static func capture<T>(_ operation: @escaping @MainActor () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    private static func mergeRefreshedSkills(
        _ refreshed: [ServerSkillSummary],
        into partition: Partition,
        startVersions: [ServerResourceMutationKey: UInt64]
    ) -> [ServerSkillSummary] {
        let currentByID = Dictionary(uniqueKeysWithValues: partition.skills.map { ($0.id, $0) })
        var refreshedIDs = Set<String>()
        var merged = refreshed.map { skill in
            refreshedIDs.insert(skill.id)
            let key = ServerResourceMutationKey.skill(skill.id)
            guard shouldPreserveNormalResource(
                key,
                in: partition,
                startVersions: startVersions
            ) else {
                return skill
            }
            return currentByID[skill.id] ?? skill
        }

        for current in partition.skills where !refreshedIDs.contains(current.id) {
            let key = ServerResourceMutationKey.skill(current.id)
            if shouldPreserveNormalResource(key, in: partition, startVersions: startVersions) {
                merged.append(current)
            }
        }
        return merged
    }

    private static func mergeRefreshedExtensions(
        _ refreshed: [ServerExtensionSummary],
        into partition: Partition,
        startVersions: [ServerResourceMutationKey: UInt64],
        preserveOppi: Bool
    ) -> [ServerExtensionSummary] {
        let currentByID = Dictionary(uniqueKeysWithValues: partition.extensions.map { ($0.id, $0) })
        var refreshedIDs = Set<String>()
        var merged = refreshed.map { resource in
            refreshedIDs.insert(resource.id)
            let preserve: Bool
            if resource.isBuiltInOppi {
                preserve = preserveOppi
            } else {
                preserve = shouldPreserveNormalResource(
                    .normalExtension(resource.id),
                    in: partition,
                    startVersions: startVersions
                )
            }
            guard preserve else { return resource }
            return currentByID[resource.id] ?? resource
        }

        for current in partition.extensions where !refreshedIDs.contains(current.id) {
            let preserve: Bool
            if current.isBuiltInOppi {
                preserve = preserveOppi
            } else {
                preserve = shouldPreserveNormalResource(
                    .normalExtension(current.id),
                    in: partition,
                    startVersions: startVersions
                )
            }
            if preserve {
                merged.append(current)
            }
        }
        return merged
    }

    private static func shouldPreserveNormalResource(
        _ key: ServerResourceMutationKey,
        in partition: Partition,
        startVersions: [ServerResourceMutationKey: UInt64]
    ) -> Bool {
        partition.pendingMutations.contains(key)
            || partition.normalResourceVersions[key, default: 0] != startVersions[key, default: 0]
    }

    private static func shouldPreserveOppiDuringRefresh(
        _ partition: Partition,
        startVersion: UInt64
    ) -> Bool {
        partition.oppiWriteInFlight
            || !partition.pendingMutations.isDisjoint(with: [.oppiEnabled, .oppiApprovalPolicy])
            || partition.oppiOrderingVersion != startVersion
    }

    private static func advanceNormalResourceVersion(
        _ key: ServerResourceMutationKey,
        in partition: inout Partition
    ) {
        partition.normalResourceVersions[key, default: 0] &+= 1
    }

    private static func skill(_ skill: ServerSkillSummary, state: ServerSkillState) -> ServerSkillSummary {
        ServerSkillSummary(
            id: skill.id,
            name: skill.name,
            description: skill.description,
            provenance: skill.provenance,
            path: skill.path,
            packageName: skill.packageName,
            state: state,
            loadError: skill.loadError,
            warnings: skill.warnings
        )
    }

    private static func `extension`(_ resource: ServerExtensionSummary, state: ServerExtensionState) -> ServerExtensionSummary {
        ServerExtensionSummary(
            id: resource.id,
            name: resource.name,
            description: resource.description,
            kind: resource.kind,
            provenance: resource.provenance,
            path: resource.path,
            packageName: resource.packageName,
            state: state,
            loadError: resource.loadError,
            warnings: resource.warnings,
            isRemovable: resource.isRemovable
        )
    }

    private static func applyOppiState(to partition: inout Partition) {
        guard let configuration = partition.desiredOppiConfiguration ?? partition.authoritativeOppiConfiguration,
              let index = partition.extensions.firstIndex(where: \.isBuiltInOppi) else {
            return
        }
        partition.extensions[index] = Self.extension(
            partition.extensions[index],
            state: configuration.enabled ? .on : .off
        )
    }

    private static func sameOppiValues(
        _ lhs: OppiExtensionConfiguration,
        _ rhs: OppiExtensionConfiguration
    ) -> Bool {
        lhs.enabled == rhs.enabled && lhs.approvalPolicy == rhs.approvalPolicy
    }

    private static func errorText(_ error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The server could not save this setting." : text
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func isRevisionConflict(_ error: Error) -> Bool {
        guard case APIError.server(let status, _) = error else { return false }
        return status == 409
    }
}
