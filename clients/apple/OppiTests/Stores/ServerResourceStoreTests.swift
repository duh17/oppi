import Foundation
import Testing
@testable import Oppi

@Suite("Server resource store", .serialized)
@MainActor
struct ServerResourceStoreTests {
    @Test func cachedSnapshotAppearsBeforeOfflineRefreshAndKeepsEmptyDistinctFromUnloaded() async throws {
        let cache = makeCache()
        let cached = snapshot(skills: [], extensions: [extensionSummary(id: "cached")])
        await cache.saveServerResourceCatalog(cached, serverId: "server-a")

        let store = ServerResourceStore(cache: cache, now: { fixedNow })
        await store.load(
            serverId: "server-a",
            fetchSkills: { throw APIError.server(status: 503, message: "Skills unavailable") },
            fetchExtensions: { throw APIError.server(status: 503, message: "Extensions unavailable") }
        )

        #expect(store.hasLoadedSkills(forServer: "server-a"))
        #expect(store.hasLoadedExtensions(forServer: "server-a"))
        #expect(store.skills(forServer: "server-a").isEmpty)
        #expect(store.extensions(forServer: "server-a").map(\.id) == ["cached"])
        #expect(store.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
        #expect(store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(!store.mutationsAllowed(for: .skills, serverId: "server-a"))
        #expect(!store.hasLoadedSkills(forServer: "server-b"))
    }

    @Test func refreshesCatalogHalvesIndependentlyAndPreservesFailedPartition() async throws {
        let cache = makeCache()
        let cached = snapshot(
            skills: [skill(id: "cached-skill", state: .disabled)],
            extensions: [extensionSummary(id: "cached-extension")]
        )
        await cache.saveServerResourceCatalog(cached, serverId: "server-a")

        let freshSkill = skill(id: "fresh-skill", state: .enabled)
        let store = ServerResourceStore(cache: cache, now: { fixedNow })
        await store.load(
            serverId: "server-a",
            fetchSkills: { [freshSkill] in [freshSkill] },
            fetchExtensions: { throw APIError.server(status: 503, message: "Extensions unavailable") }
        )

        #expect(store.skills(forServer: "server-a") == [freshSkill])
        #expect(store.extensions(forServer: "server-a").map(\.id) == ["cached-extension"])
        #expect(!store.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
        #expect(store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(store.mutationsAllowed(for: .skills, serverId: "server-a"))
        #expect(!store.mutationsAllowed(for: .extensions, serverId: "server-a"))
    }

    @Test func successfulEmptyCatalogIsLoadedAndNotUnavailable() async {
        let store = ServerResourceStore(cache: makeCache(), now: { fixedNow })

        await store.load(
            serverId: "server-a",
            fetchSkills: { [] },
            fetchExtensions: { ServerExtensionCatalog(extensions: []) }
        )

        #expect(store.hasLoadedSkills(forServer: "server-a"))
        #expect(store.hasLoadedExtensions(forServer: "server-a"))
        #expect(store.skills(forServer: "server-a").isEmpty)
        #expect(store.extensions(forServer: "server-a").isEmpty)
        #expect(!store.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
        #expect(!store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
    }

    @Test func cancellingBeforeEitherCatalogCompletesRestoresCachedSyncAndCacheState() async {
        let cache = makeCache()
        let cached = snapshot(
            skills: [skill(id: "cached-skill", state: .disabled)],
            extensions: [extensionSummary(id: "cached-extension")]
        )
        await cache.saveServerResourceCatalog(cached, serverId: "server-a")
        let skillsGate = SuspensionGate()
        let extensionsGate = SuspensionGate()
        let store = ServerResourceStore(cache: cache, now: { fixedNow })

        let refresh = Task { @MainActor in
            await store.load(
                serverId: "server-a",
                fetchSkills: {
                    await skillsGate.suspend()
                    try Task.checkCancellation()
                    return []
                },
                fetchExtensions: {
                    await extensionsGate.suspend()
                    try Task.checkCancellation()
                    return self.extensionCatalog()
                }
            )
        }
        await skillsGate.waitUntilSuspended()
        await extensionsGate.waitUntilSuspended()
        refresh.cancel()
        await skillsGate.release()
        await extensionsGate.release()
        await refresh.value

        #expect(store.skills(forServer: "server-a") == cached.skills)
        #expect(store.extensions(forServer: "server-a") == cached.extensions)
        #expect(!store.syncState(for: .skills, serverId: "server-a").isSyncing)
        #expect(!store.syncState(for: .extensions, serverId: "server-a").isSyncing)
        #expect(!store.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
        #expect(!store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(await cache.loadServerResourceCatalog(serverId: "server-a") == cached)
    }

    @Test func cancellingAfterSkillsCompletesPreservesTheEntireCachedRefreshState() async {
        let cache = makeCache()
        let cachedExtension = extensionSummary(id: "cached-extension")
        let cached = snapshot(
            skills: [skill(id: "cached-skill", state: .disabled)],
            extensions: [cachedExtension]
        )
        let freshSkill = skill(id: "fresh-skill", state: .enabled)
        await cache.saveServerResourceCatalog(cached, serverId: "server-a")
        let skillsCompleted = CompletionSignal()
        let extensionsGate = SuspensionGate()
        let store = ServerResourceStore(cache: cache, now: { fixedNow })

        let refresh = Task { @MainActor in
            await store.load(
                serverId: "server-a",
                fetchSkills: {
                    await skillsCompleted.signal()
                    return [freshSkill]
                },
                fetchExtensions: {
                    await extensionsGate.suspend()
                    try Task.checkCancellation()
                    return self.extensionCatalog()
                }
            )
        }
        await skillsCompleted.wait()
        await extensionsGate.waitUntilSuspended()
        refresh.cancel()
        await extensionsGate.release()
        await refresh.value

        #expect(store.skills(forServer: "server-a") == cached.skills)
        #expect(store.extensions(forServer: "server-a") == [cachedExtension])
        #expect(!store.syncState(for: .skills, serverId: "server-a").isSyncing)
        #expect(!store.syncState(for: .extensions, serverId: "server-a").isSyncing)
        #expect(!store.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
        #expect(!store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(await cache.loadServerResourceCatalog(serverId: "server-a") == cached)
    }

    @Test func cancellingOnlyExtensionsFetchKeepsItsCacheWhileSkillsRefreshes() async {
        let cache = makeCache()
        let cachedExtension = extensionSummary(id: "cached-extension")
        let cached = snapshot(
            skills: [skill(id: "cached-skill", state: .disabled)],
            extensions: [cachedExtension]
        )
        let freshSkill = skill(id: "fresh-skill", state: .enabled)
        await cache.saveServerResourceCatalog(cached, serverId: "server-a")
        let store = ServerResourceStore(cache: cache, now: { fixedNow })

        await store.load(
            serverId: "server-a",
            fetchSkills: { [freshSkill] },
            fetchExtensions: { throw CancellationError() }
        )

        #expect(store.skills(forServer: "server-a") == [freshSkill])
        #expect(store.extensions(forServer: "server-a") == [cachedExtension])
        #expect(!store.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
        #expect(!store.syncState(for: .extensions, serverId: "server-a").isSyncing)
        #expect(!store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        let cachedAfterRefresh = await cache.loadServerResourceCatalog(serverId: "server-a")
        #expect(cachedAfterRefresh?.skills == [freshSkill])
        #expect(cachedAfterRefresh?.extensions == [cachedExtension])
    }

    @Test func URLCancellationFormsPreservePriorCatalogStateWithoutGoingOffline() async {
        let cancellationErrors: [Error] = [
            URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ]

        for cancellationError in cancellationErrors {
            let cache = makeCache()
            let cachedExtension = extensionSummary(id: "cached-extension")
            let cached = snapshot(
                skills: [skill(id: "cached-skill", state: .disabled)],
                extensions: [cachedExtension]
            )
            let freshSkill = skill(id: "fresh-skill", state: .enabled)
            await cache.saveServerResourceCatalog(cached, serverId: "server-a")
            let store = ServerResourceStore(cache: cache, now: { fixedNow })

            await store.load(
                serverId: "server-a",
                fetchSkills: { [freshSkill] },
                fetchExtensions: { throw cancellationError }
            )

            #expect(store.skills(forServer: "server-a") == [freshSkill])
            #expect(store.extensions(forServer: "server-a") == [cachedExtension])
            #expect(!store.syncState(for: .extensions, serverId: "server-a").isSyncing)
            #expect(!store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
            #expect(store.mutationsAllowed(for: .extensions, serverId: "server-a"))
        }
    }

    @Test func overlappingCancellationRollsBackToStableStateForEveryCacheAndCancellationForm() async {
        for cacheState in RefreshCacheState.allCases {
            for cancellation in RefreshCancellationRepresentation.allCases {
                let cache = makeCache()
                let expected = cacheState.snapshot(
                    skills: [skill(id: "cached-skill", state: .disabled)],
                    extensions: [extensionSummary(id: "cached-extension")]
                )
                if let expected {
                    await cache.saveServerResourceCatalog(expected, serverId: "server-a")
                }

                let firstSkillsGate = SuspensionGate()
                let firstExtensionsGate = SuspensionGate()
                let secondSkillsGate = SuspensionGate()
                let secondExtensionsGate = SuspensionGate()
                let store = ServerResourceStore(cache: cache, now: { fixedNow })

                let first = Task { @MainActor in
                    await store.load(
                        serverId: "server-a",
                        fetchSkills: {
                            await firstSkillsGate.suspend()
                            return [self.skill(id: "stale-first-skill", state: .enabled)]
                        },
                        fetchExtensions: {
                            await firstExtensionsGate.suspend()
                            return self.extensionCatalog()
                        }
                    )
                }
                await firstSkillsGate.waitUntilSuspended()
                await firstExtensionsGate.waitUntilSuspended()

                let second = Task { @MainActor in
                    await store.load(
                        serverId: "server-a",
                        fetchSkills: {
                            try await cancellation.cancel(
                                afterSuspendingOn: secondSkillsGate
                            ) as [ServerSkillSummary]
                        },
                        fetchExtensions: {
                            try await cancellation.cancel(
                                afterSuspendingOn: secondExtensionsGate
                            ) as ServerExtensionCatalog
                        }
                    )
                }
                if cancellation == .cancelledTask {
                    await secondSkillsGate.waitUntilSuspended()
                    await secondExtensionsGate.waitUntilSuspended()
                    second.cancel()
                    await secondSkillsGate.release()
                    await secondExtensionsGate.release()
                }
                await second.value

                await firstSkillsGate.release()
                await firstExtensionsGate.release()
                await first.value

                #expect(!store.syncState(for: .skills, serverId: "server-a").isSyncing)
                #expect(!store.syncState(for: .extensions, serverId: "server-a").isSyncing)
                #expect(store.hasLoadedSkills(forServer: "server-a") == (expected?.skillsLoaded ?? false))
                #expect(store.hasLoadedExtensions(forServer: "server-a") == (expected?.extensionsLoaded ?? false))
                #expect(store.skills(forServer: "server-a") == (expected?.skills ?? []))
                #expect(store.extensions(forServer: "server-a") == (expected?.extensions ?? []))
                #expect(
                    store.syncState(for: .skills, serverId: "server-a").lastSuccessfulSyncAt
                        == expected?.skillsSavedAt
                )
                #expect(
                    store.syncState(for: .extensions, serverId: "server-a").lastSuccessfulSyncAt
                        == expected?.extensionsSavedAt
                )
                #expect(!store.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
                #expect(!store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
                #expect(await cache.loadServerResourceCatalog(serverId: "server-a") == expected)
            }
        }
    }

    @Test func genuineURLErrorMarksOnlyItsCatalogOffline() async {
        let cachedExtension = extensionSummary(id: "cached-extension")
        let store = ServerResourceStore(cache: makeCache(), now: { fixedNow })
        store.replaceSkills([], serverId: "server-a")
        store.replaceExtensions([cachedExtension], serverId: "server-a")

        await store.load(
            serverId: "server-a",
            fetchSkills: { [] },
            fetchExtensions: { throw URLError(.notConnectedToInternet) }
        )

        #expect(!store.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
        #expect(store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(!store.mutationsAllowed(for: .extensions, serverId: "server-a"))
    }

    @Test func coldPartialSuccessSurvivesOfflineRelaunchWithoutLoadingMissingHalfAsEmpty() async {
        let cache = makeCache()
        let freshSkill = skill(id: "fresh-skill", state: .enabled)
        let store = ServerResourceStore(cache: cache, now: { fixedNow })

        await store.load(
            serverId: "server-a",
            fetchSkills: { [freshSkill] },
            fetchExtensions: { throw URLError(.cannotConnectToHost) }
        )

        #expect(store.skills(forServer: "server-a") == [freshSkill])
        #expect(store.hasLoadedSkills(forServer: "server-a"))
        #expect(!store.hasLoadedExtensions(forServer: "server-a"))
        #expect(await cache.loadServerResourceCatalog(serverId: "server-a") != nil)

        let relaunched = ServerResourceStore(cache: cache, now: { fixedNow })
        await relaunched.load(
            serverId: "server-a",
            fetchSkills: { throw URLError(.notConnectedToInternet) },
            fetchExtensions: { throw URLError(.notConnectedToInternet) }
        )

        #expect(relaunched.skills(forServer: "server-a") == [freshSkill])
        #expect(relaunched.hasLoadedSkills(forServer: "server-a"))
        #expect(!relaunched.hasLoadedExtensions(forServer: "server-a"))
        #expect(relaunched.syncState(for: .skills, serverId: "server-a").lastSuccessfulSyncAt == fixedNow)
        #expect(relaunched.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
        #expect(relaunched.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(!relaunched.mutationsAllowed(for: .extensions, serverId: "server-a"))
    }

    @Test func coldExtensionsSuccessSurvivesOfflineRelaunchWithoutLoadingSkillsAsEmpty() async {
        let cache = makeCache()
        let store = ServerResourceStore(cache: cache, now: { fixedNow })

        await store.load(
            serverId: "server-a",
            fetchSkills: { throw URLError(.cannotConnectToHost) },
            fetchExtensions: { self.extensionCatalog() }
        )

        #expect(!store.hasLoadedSkills(forServer: "server-a"))
        #expect(store.hasLoadedExtensions(forServer: "server-a"))

        let relaunched = ServerResourceStore(cache: cache, now: { fixedNow })
        await relaunched.load(
            serverId: "server-a",
            fetchSkills: { throw URLError(.notConnectedToInternet) },
            fetchExtensions: { throw URLError(.notConnectedToInternet) }
        )

        #expect(!relaunched.hasLoadedSkills(forServer: "server-a"))
        #expect(relaunched.hasLoadedExtensions(forServer: "server-a"))
        #expect(relaunched.extensions(forServer: "server-a").map(\.id) == ["catalog-extension"])
        #expect(relaunched.syncState(for: .extensions, serverId: "server-a").lastSuccessfulSyncAt == fixedNow)
        #expect(relaunched.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(relaunched.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
        #expect(!relaunched.mutationsAllowed(for: .skills, serverId: "server-a"))
    }

    @Test func optimisticSkillToggleRetainsPackageMetadataAcrossPendingSuccessAndPresentation() async throws {
        let privatePath = "/private/var/folders/skill-package/SKILL.md"
        let cached = skill(
            id: "skill-package",
            state: .disabled,
            packageName: "@scope/cached-skill",
            path: privatePath
        )
        let authoritative = skill(
            id: cached.id,
            state: .enabled,
            packageName: "@scope/authoritative-skill",
            path: privatePath
        )
        let mutationGate = SuspensionGate()
        let store = configuredStore(skills: [cached])

        let mutation = Task { @MainActor in
            await store.setSkillEnabled(
                id: cached.id,
                enabled: true,
                serverId: "server-a",
                request: { _, _ in
                    await mutationGate.suspend()
                    return authoritative
                }
            )
        }
        await mutationGate.waitUntilSuspended()

        let pending = try #require(store.skills(forServer: "server-a").first)
        #expect(pending.packageName == "@scope/cached-skill")
        let pendingPresentation = ServerSkillListPresentation(skills: [pending], query: "@scope/cached-skill")
        #expect(pendingPresentation.visibleSkills == [pending])
        #expect(ServerSkillListPresentation(skills: [pending], query: privatePath).visibleSkills.isEmpty)
        #expect(ServerSkillListPresentation.accessibilityLabel(for: pending) == "skill-package, @scope/cached-skill, Pi agent, Enabled")
        #expect(!ServerSkillListPresentation.accessibilityLabel(for: pending).contains(privatePath))
        #expect(resolvedServerSkillDetailSummary(catalogSummary: pending, freshDetail: nil)?.packageName == "@scope/cached-skill")

        await mutationGate.release()
        await mutation.value

        let settled = try #require(store.skills(forServer: "server-a").first)
        #expect(settled == authoritative)
        #expect(settled.packageName == "@scope/authoritative-skill")
        #expect(ServerSkillListPresentation(skills: [settled], query: "@scope/authoritative-skill").visibleSkills == [settled])
        #expect(resolvedServerSkillDetailSummary(catalogSummary: settled, freshDetail: nil)?.packageName == "@scope/authoritative-skill")
    }

    @Test func optimisticExtensionToggleRetainsPackageMetadataAcrossPendingRollbackAndPresentation() async throws {
        let privatePath = "/private/var/folders/extension-package/index.ts"
        let cached = extensionSummary(
            id: "extension-package",
            state: .off,
            packageName: "@scope/cached-extension",
            path: privatePath
        )
        let mutationGate = SuspensionGate()
        let store = configuredStore(skills: [])
        store.replaceExtensions([cached], serverId: "server-a")

        let mutation = Task { @MainActor in
            await store.setExtensionEnabled(
                id: cached.id,
                enabled: true,
                serverId: "server-a",
                request: { _, _ in
                    await mutationGate.suspend()
                    throw APIError.server(status: 500, message: "Could not save")
                }
            )
        }
        await mutationGate.waitUntilSuspended()

        let pending = try #require(store.extensions(forServer: "server-a").first { $0.id == cached.id })
        #expect(pending.packageName == "@scope/cached-extension")
        let pendingPresentation = ServerExtensionListPresentation(extensions: [pending], query: "@scope/cached-extension")
        #expect(pendingPresentation.visibleExtensions == [pending])
        #expect(ServerExtensionListPresentation(extensions: [pending], query: privatePath).visibleExtensions.isEmpty)
        #expect(ServerExtensionListPresentation.accessibilityLabel(for: pending) == "extension-package, @scope/cached-extension, Pi user settings, On")
        #expect(!ServerExtensionListPresentation.accessibilityLabel(for: pending).contains(privatePath))
        #expect(resolvedServerExtensionDetailSummary(catalogSummary: pending, freshDetail: nil)?.packageName == "@scope/cached-extension")

        await mutationGate.release()
        await mutation.value

        let rolledBack = try #require(store.extensions(forServer: "server-a").first { $0.id == cached.id })
        #expect(rolledBack == cached)
        #expect(rolledBack.packageName == "@scope/cached-extension")
        #expect(ServerExtensionListPresentation(extensions: [rolledBack], query: "@scope/cached-extension").visibleExtensions == [rolledBack])
        #expect(resolvedServerExtensionDetailSummary(catalogSummary: rolledBack, freshDetail: nil)?.packageName == "@scope/cached-extension")
    }

    @Test func normalToggleIsOptimisticAndRollsBackOnlyItsRowOnFailure() async {
        let first = skill(id: "first", state: .disabled)
        let second = skill(id: "second", state: .enabled)
        let store = ServerResourceStore(cache: makeCache(), now: { fixedNow })
        store.replaceSkills([first, second], serverId: "server-a")

        await store.setSkillEnabled(
            id: first.id,
            enabled: true,
            serverId: "server-a",
            request: { _, _ in throw APIError.server(status: 500, message: "Could not save") }
        )

        #expect(store.skills(forServer: "server-a") == [first, second])
        #expect(store.mutationError(for: .skill(first.id), serverId: "server-a") == "Could not save")
        #expect(!store.isMutationPending(.skill(first.id), serverId: "server-a"))
        #expect(!store.isMutationPending(.skill(second.id), serverId: "server-a"))
    }

    @Test func normalToggleUsesAuthoritativeResponseWithoutChangingOtherRows() async {
        let first = extensionSummary(id: "first", state: .off)
        let second = extensionSummary(id: "second", state: .on)
        let store = ServerResourceStore(cache: makeCache(), now: { fixedNow })
        store.replaceExtensions([first, second], serverId: "server-a")
        let authoritative = extensionSummary(id: "first", state: .on, name: "Renamed by server")

        await store.setExtensionEnabled(
            id: first.id,
            enabled: true,
            serverId: "server-a",
            request: { _, _ in authoritative }
        )

        #expect(store.extensions(forServer: "server-a") == [authoritative, second])
        #expect(!store.isMutationPending(.normalExtension(first.id), serverId: "server-a"))
    }

    @Test func refreshStartedBeforeNormalMutationCompletionCannotOverwriteAuthoritativeResponse() async {
        let original = skill(id: "skill", state: .disabled)
        let authoritative = skill(id: "skill", state: .enabled, name: "Server canonical name")
        let refreshGate = SuspensionGate()
        let mutationGate = SuspensionGate()
        let cache = makeCache()
        let store = configuredStore(cache: cache, skills: [original])

        let refresh = Task { @MainActor in
            await store.load(
                serverId: "server-a",
                fetchSkills: {
                    await refreshGate.suspend()
                    return [original]
                },
                fetchExtensions: { self.extensionCatalog() }
            )
        }
        await refreshGate.waitUntilSuspended()

        let mutation = Task { @MainActor in
            await store.setSkillEnabled(
                id: original.id,
                enabled: true,
                serverId: "server-a",
                request: { _, _ in
                    await mutationGate.suspend()
                    return authoritative
                }
            )
        }
        await mutationGate.waitUntilSuspended()

        await refreshGate.release()
        await refresh.value
        #expect(store.skills(forServer: "server-a").first?.state == .enabled)
        #expect(store.isMutationPending(.skill(original.id), serverId: "server-a"))
        #expect(await cache.loadServerResourceCatalog(serverId: "server-a")?.skills == [original])

        await mutationGate.release()
        await mutation.value

        #expect(store.skills(forServer: "server-a") == [authoritative])
        #expect(!store.isMutationPending(.skill(original.id), serverId: "server-a"))
        #expect(store.mutationError(for: .skill(original.id), serverId: "server-a") == nil)
    }

    @Test func refreshStartedAfterNormalMutationCompletionMayApplyNewerSnapshot() async {
        let original = skill(id: "skill", state: .disabled)
        let authoritative = skill(id: "skill", state: .enabled, name: "Mutation response")
        let refreshed = skill(id: "skill", state: .enabled, name: "Newer refresh")
        let store = configuredStore(skills: [original])

        await store.setSkillEnabled(
            id: original.id,
            enabled: true,
            serverId: "server-a",
            request: { _, _ in authoritative }
        )
        await store.load(
            serverId: "server-a",
            fetchSkills: { [refreshed] },
            fetchExtensions: { self.extensionCatalog() }
        )

        #expect(store.skills(forServer: "server-a") == [refreshed])
        #expect(!store.isMutationPending(.skill(original.id), serverId: "server-a"))
    }

    @Test func staleMutationResponseRemainsIsolatedToItsServerPartition() async {
        let gate = SuspensionGate()
        let serverAOriginal = skill(id: "shared", state: .disabled, name: "Server A old")
        let serverAAuthoritative = skill(id: "shared", state: .enabled, name: "Server A canonical")
        let serverB = skill(id: "shared", state: .disabled, name: "Server B")
        let store = configuredStore(skills: [serverAOriginal])
        store.replaceSkills([serverB], serverId: "server-b")

        let mutation = Task { @MainActor in
            await store.setSkillEnabled(
                id: serverAOriginal.id,
                enabled: true,
                serverId: "server-a",
                request: { _, _ in
                    await gate.suspend()
                    return serverAAuthoritative
                }
            )
        }
        await gate.waitUntilSuspended()
        store.switchServer(to: "server-b")
        await gate.release()
        await mutation.value

        #expect(store.skills(forServer: "server-a") == [serverAAuthoritative])
        #expect(store.skills(forServer: "server-b") == [serverB])
        #expect(!store.isMutationPending(.skill(serverAOriginal.id), serverId: "server-b"))
    }

    @Test func successfulNormalMutationWritesAuthoritativeSnapshotThroughToCache() async {
        let cache = makeCache()
        let original = skill(id: "skill", state: .disabled)
        let authoritative = skill(id: "skill", state: .enabled, name: "Cached canonical name")
        let store = configuredStore(cache: cache, skills: [original])

        await store.setSkillEnabled(
            id: original.id,
            enabled: true,
            serverId: "server-a",
            request: { _, _ in authoritative }
        )

        let relaunched = ServerResourceStore(cache: cache, now: { fixedNow })
        await relaunched.load(
            serverId: "server-a",
            fetchSkills: { throw APIError.server(status: 503, message: "Offline") },
            fetchExtensions: { throw APIError.server(status: 503, message: "Offline") }
        )

        #expect(relaunched.skills(forServer: "server-a") == [authoritative])
        #expect(relaunched.hasLoadedSkills(forServer: "server-a"))
    }

    @Test func cacheWriteFailureDoesNotTurnSuccessfulServerMutationIntoUIFailure() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "server-resource-cache-failure-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: base) }
        try Data("not-a-directory".utf8).write(to: base, options: .atomic)

        let cache = TimelineCache(rootURL: base.appending(path: "blocked-cache"))
        let original = skill(id: "skill", state: .disabled)
        let authoritative = skill(id: "skill", state: .enabled, name: "Server succeeded")
        let store = configuredStore(cache: cache, skills: [original])

        await store.setSkillEnabled(
            id: original.id,
            enabled: true,
            serverId: "server-a",
            request: { _, _ in authoritative }
        )

        #expect(store.skills(forServer: "server-a") == [authoritative])
        #expect(!store.isMutationPending(.skill(original.id), serverId: "server-a"))
        #expect(store.mutationError(for: .skill(original.id), serverId: "server-a") == nil)
    }

    private var fixedNow: Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func configuredStore(
        cache: TimelineCache? = nil,
        skills: [ServerSkillSummary]
    ) -> ServerResourceStore {
        let store = ServerResourceStore(cache: cache ?? makeCache(), now: { fixedNow })
        store.replaceSkills(skills, serverId: "server-a")
        store.replaceExtensions([], serverId: "server-a")
        return store
    }

    private func extensionCatalog() -> ServerExtensionCatalog {
        ServerExtensionCatalog(extensions: [extensionSummary(id: "catalog-extension")])
    }

    private func makeCache() -> TimelineCache {
        TimelineCache(rootURL: FileManager.default.temporaryDirectory.appending(path: "server-resource-store-tests-\(UUID().uuidString)"))
    }

    private func snapshot(
        skills: [ServerSkillSummary],
        extensions: [ServerExtensionSummary]
    ) -> ServerResourceCatalogSnapshot {
        ServerResourceCatalogSnapshot(
            skills: skills,
            extensions: extensions,
            builtInTools: [],
            savedAt: fixedNow,
            skillsLoaded: true,
            extensionsLoaded: true,
            skillsSavedAt: fixedNow,
            extensionsSavedAt: fixedNow
        )
    }

    private func skill(
        id: String,
        state: ServerSkillState,
        name: String? = nil,
        packageName: String? = nil,
        path: String? = nil
    ) -> ServerSkillSummary {
        ServerSkillSummary(
            id: id,
            name: name ?? id,
            description: "Description for \(id)",
            provenance: ServerResourceProvenance(kind: .piAgent, label: "Pi agent"),
            path: path,
            packageName: packageName,
            state: state,
            loadError: nil,
            warnings: [],
            editable: true
        )
    }

    private func extensionSummary(
        id: String,
        state: ServerExtensionState = .off,
        name: String? = nil,
        kind: ServerExtensionKind = .file,
        packageName: String? = nil,
        path: String? = nil
    ) -> ServerExtensionSummary {
        ServerExtensionSummary(
            id: id,
            name: name ?? id,
            description: nil,
            kind: kind,
            provenance: ServerResourceProvenance(
                kind: kind == .builtIn ? .builtIn : .userSettings,
                label: kind == .builtIn ? "Built-in extension" : "Pi user settings"
            ),
            path: path,
            packageName: packageName,
            state: state,
            loadError: nil,
            warnings: [],
            isRemovable: false
        )
    }
}

private enum RefreshCacheState: CaseIterable {
    case cold
    case partial
    case full

    func snapshot(
        skills: [ServerSkillSummary],
        extensions: [ServerExtensionSummary]
    ) -> ServerResourceCatalogSnapshot? {
        let skillsSavedAt = Date(timeIntervalSince1970: 1_699_999_900)
        let extensionsSavedAt = Date(timeIntervalSince1970: 1_699_999_950)
        switch self {
        case .cold:
            return nil
        case .partial:
            return ServerResourceCatalogSnapshot(
                skills: skills,
                extensions: [],
                builtInTools: [],
                savedAt: skillsSavedAt,
                skillsLoaded: true,
                extensionsLoaded: false,
                skillsSavedAt: skillsSavedAt,
                extensionsSavedAt: nil
            )
        case .full:
            return ServerResourceCatalogSnapshot(
                skills: skills,
                extensions: extensions,
                builtInTools: [],
                savedAt: extensionsSavedAt,
                skillsLoaded: true,
                extensionsLoaded: true,
                skillsSavedAt: skillsSavedAt,
                extensionsSavedAt: extensionsSavedAt
            )
        }
    }
}

private enum RefreshCancellationRepresentation: CaseIterable {
    case cancelledTask
    case cancellationError
    case urlError
    case nsurlError

    func cancel<T>(afterSuspendingOn gate: SuspensionGate) async throws -> T {
        if self == .cancelledTask {
            await gate.suspend()
        }
        return try raise()
    }

    func raise<T>() throws -> T {
        switch self {
        case .cancelledTask:
            try Task.checkCancellation()
            throw CancellationError()
        case .cancellationError:
            throw CancellationError()
        case .urlError:
            throw URLError(.cancelled)
        case .nsurlError:
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        }
    }
}

private actor SuspensionGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CompletionSignal {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        completed = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }

    func wait() async {
        guard !completed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
