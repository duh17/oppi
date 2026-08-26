import Foundation

/// Cache value for independently trustworthy server-global Skills and Extensions snapshots.
struct ServerResourceCatalogSnapshot: Codable, Sendable, Equatable {
    let skills: [ServerSkillSummary]
    let extensions: [ServerExtensionSummary]
    let builtInTools: [ServerToolSummary]
    let savedAt: Date
    let skillsLoaded: Bool
    let extensionsLoaded: Bool
    let skillsSavedAt: Date?
    let extensionsSavedAt: Date?
}

enum ServerResourceCatalogKind: Hashable, Sendable {
    case skills
    case extensions
}

enum ServerResourceMutationKey: Hashable, Sendable {
    case skill(String)
    case normalExtension(String)
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

    private struct Partition {
        var skills: [ServerSkillSummary] = []
        var extensions: [ServerExtensionSummary] = []
        var builtInTools: [ServerToolSummary] = []
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

    func builtInTools(forServer serverId: String) -> [ServerToolSummary] {
        partitions[serverId]?.builtInTools ?? []
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
        }
    }

    func isMutationPending(_ key: ServerResourceMutationKey, serverId: String) -> Bool {
        partitions[serverId]?.pendingMutations.contains(key) ?? false
    }

    func mutationError(for key: ServerResourceMutationKey, serverId: String) -> String? {
        partitions[serverId]?.errors[key]
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
                    $0.extensionsSync = extensionsSyncBeforeRefresh
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
                    let mergedExtensions = Self.mergeRefreshedExtensions(
                        catalog.extensions,
                        into: $0,
                        startVersions: extensionsStartVersions
                    )
                    $0.extensions = mergedExtensions
                    $0.builtInTools = catalog.builtInTools
                    $0.extensionsLoaded = true
                    $0.extensionsSync.markSyncSucceeded(at: now())
                }
                shouldSaveCache = true
            }
        case .failure(let error):
            if partitions[serverId]?.extensionsGeneration == extensionsGeneration {
                update(serverId) {
                    if Self.isCancellation(error) {
                        $0.extensionsSync = extensionsSyncBeforeRefresh
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
              let previous = extensions(forServer: serverId).first(where: { $0.id == id }) else {
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
        builtInTools: [ServerToolSummary] = [],
        serverId: String
    ) {
        update(serverId) {
            $0.extensions = extensions
            $0.builtInTools = builtInTools
            $0.extensionsLoaded = true
            for resource in $0.extensions {
                Self.advanceNormalResourceVersion(.normalExtension(resource.id), in: &$0)
            }
            $0.extensionsSync.markSyncSucceeded(at: now())
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
            if !$0.extensionsLoaded, snapshot.extensionsLoaded {
                $0.extensions = snapshot.extensions
                $0.builtInTools = snapshot.builtInTools
                $0.extensionsLoaded = true
                if let savedAt = snapshot.extensionsSavedAt {
                    $0.extensionsSync.markSyncSucceeded(at: savedAt)
                }
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
        let hasCurrentExtensions = partition.extensionsLoaded
        let extensionsLoaded = hasCurrentExtensions || existing?.extensionsLoaded == true
        let cachedExtensions = hasCurrentExtensions ? currentExtensions : (existing?.extensions ?? [])
        let extensionsSavedAt = hasCurrentExtensions
            ? (partition.extensionsSync.lastSuccessfulSyncAt ?? existing?.extensionsSavedAt ?? now())
            : existing?.extensionsSavedAt

        guard skillsLoaded || extensionsLoaded else { return }
        let savedAt = now()
        await cache.saveServerResourceCatalog(
            ServerResourceCatalogSnapshot(
                skills: cachedSkills,
                extensions: cachedExtensions,
                builtInTools: hasCurrentExtensions
                    ? partition.builtInTools
                    : (existing?.builtInTools ?? []),
                savedAt: savedAt,
                skillsLoaded: skillsLoaded,
                extensionsLoaded: extensionsLoaded,
                skillsSavedAt: skillsSavedAt,
                extensionsSavedAt: extensionsSavedAt
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
        startVersions: [ServerResourceMutationKey: UInt64]
    ) -> [ServerExtensionSummary] {
        let currentByID = Dictionary(uniqueKeysWithValues: partition.extensions.map { ($0.id, $0) })
        var refreshedIDs = Set<String>()
        var merged = refreshed.map { resource in
            refreshedIDs.insert(resource.id)
            let key = ServerResourceMutationKey.normalExtension(resource.id)
            guard shouldPreserveNormalResource(
                key,
                in: partition,
                startVersions: startVersions
            ) else {
                return resource
            }
            return currentByID[resource.id] ?? resource
        }

        for current in partition.extensions where !refreshedIDs.contains(current.id) {
            let key = ServerResourceMutationKey.normalExtension(current.id)
            if shouldPreserveNormalResource(key, in: partition, startVersions: startVersions) {
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
            warnings: skill.warnings,
            editable: skill.editable
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
            isRemovable: resource.isRemovable,
            contributedTools: resource.contributedTools,
            contributedToolDetails: resource.contributedToolDetails
        )
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

}
