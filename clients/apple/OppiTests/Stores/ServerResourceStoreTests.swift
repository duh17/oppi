import Foundation
import SwiftUI
import Testing
import UIKit
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
            fetchExtensions: { ServerExtensionCatalog(extensions: [], oppiConfiguration: disabledOppi) }
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
                    return self.oppiCatalog(configuration: self.disabledOppi)
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
                    return self.oppiCatalog(configuration: self.disabledOppi)
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
                    extensions: [extensionSummary(id: "cached-extension")],
                    configuration: disabledOppi
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
                            return self.oppiCatalog(configuration: self.disabledOppi)
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
        store.replaceExtensions([cachedExtension], oppiConfiguration: disabledOppi, serverId: "server-a")

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
            fetchExtensions: { self.oppiCatalog(configuration: self.disabledOppi) }
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
        #expect(relaunched.extensions(forServer: "server-a").map(\.id) == ["oppi"])
        #expect(relaunched.oppiConfiguration(forServer: "server-a") == disabledOppi)
        #expect(relaunched.syncState(for: .extensions, serverId: "server-a").lastSuccessfulSyncAt == fixedNow)
        #expect(relaunched.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(relaunched.syncState(for: .skills, serverId: "server-a").lastSyncFailed)
        #expect(!relaunched.mutationsAllowed(for: .skills, serverId: "server-a"))
    }

    @Test func cachedOfflineOppiPolicyActivationDoesNotStartOrReportAMutation() async {
        let store = configuredOppiStore()
        await store.load(
            serverId: "server-a",
            fetchSkills: { [] },
            fetchExtensions: { throw APIError.server(status: 503, message: "Extensions unavailable") }
        )
        var requestCount = 0

        await store.setOppiApprovalPolicy(
            .readOnly,
            serverId: "server-a",
            request: { _, _, _ in
                requestCount += 1
                return OppiExtensionConfiguration(enabled: false, approvalPolicy: .readOnly, revision: 2)
            },
            fetchAuthoritative: { self.disabledOppi }
        )

        #expect(!store.mutationsAllowed(for: .extensions, serverId: "server-a"))
        #expect(requestCount == 0)
        #expect(store.oppiConfiguration(forServer: "server-a") == disabledOppi)
        #expect(!store.isMutationPending(.oppiApprovalPolicy, serverId: "server-a"))
        #expect(store.mutationError(for: .oppiApprovalPolicy, serverId: "server-a") == nil)
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
        let store = configuredOppiStore()
        store.replaceExtensions(
            [extensionSummary(id: "oppi", state: .off, kind: .builtIn), cached],
            oppiConfiguration: disabledOppi,
            serverId: "server-a"
        )

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
        store.replaceExtensions([first, second], oppiConfiguration: disabledOppi, serverId: "server-a")
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
                fetchExtensions: { self.oppiCatalog(configuration: self.disabledOppi) }
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
            fetchExtensions: { self.oppiCatalog(configuration: self.disabledOppi) }
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

    @Test func selectingAlreadyAuthoritativeOppiPolicyIsATrueNoOp() async {
        let store = configuredOppiStore()
        var requestCount = 0

        await store.setOppiApprovalPolicy(
            .confirmDestructiveOnly,
            serverId: "server-a",
            request: { _, _, _ in
                requestCount += 1
                return self.disabledOppi
            },
            fetchAuthoritative: { self.disabledOppi }
        )

        #expect(requestCount == 0)
        #expect(store.oppiConfiguration(forServer: "server-a") == disabledOppi)
        #expect(!store.isMutationPending(.oppiApprovalPolicy, serverId: "server-a"))
        #expect(store.mutationError(for: .oppiApprovalPolicy, serverId: "server-a") == nil)
    }

    @Test func rapidOppiChangesSerializeFullSnapshotsAndAdvanceRevision() async {
        let gate = OppiWriteGate(responses: [
            OppiExtensionConfiguration(enabled: true, approvalPolicy: .confirmDestructiveOnly, revision: 2),
            OppiExtensionConfiguration(enabled: true, approvalPolicy: .confirmAllChanges, revision: 3),
        ])
        let store = configuredOppiStore()

        let first = Task { @MainActor in
            await store.setOppiEnabled(
                true,
                serverId: "server-a",
                request: { enabled, policy, revision in
                    try await gate.write(enabled: enabled, policy: policy, revision: revision)
                },
                fetchAuthoritative: { try await gate.fetchAuthoritative() }
            )
        }
        await gate.waitForFirstWrite()

        await store.setOppiApprovalPolicy(
            .confirmAllChanges,
            serverId: "server-a",
            request: { enabled, policy, revision in
                try await gate.write(enabled: enabled, policy: policy, revision: revision)
            },
            fetchAuthoritative: { try await gate.fetchAuthoritative() }
        )
        #expect(store.oppiConfiguration(forServer: "server-a")?.approvalPolicy == .confirmAllChanges)
        #expect(store.isMutationPending(.oppiEnabled, serverId: "server-a"))
        #expect(store.isMutationPending(.oppiApprovalPolicy, serverId: "server-a"))

        await gate.releaseFirstWrite()
        await first.value

        #expect(await gate.calls() == [
            .init(enabled: true, policy: .confirmDestructiveOnly, revision: 1),
            .init(enabled: true, policy: .confirmAllChanges, revision: 2),
        ])
        #expect(store.oppiConfiguration(forServer: "server-a") == OppiExtensionConfiguration(
            enabled: true,
            approvalPolicy: .confirmAllChanges,
            revision: 3
        ))
        #expect(!store.isMutationPending(.oppiEnabled, serverId: "server-a"))
        #expect(!store.isMutationPending(.oppiApprovalPolicy, serverId: "server-a"))
    }

    @Test func oldRefreshDuringRapidOppiChangesCannotDiscardWriteResponseOrReuseStaleRevision() async {
        let gate = OppiWriteGate(responses: [
            .success(OppiExtensionConfiguration(enabled: true, approvalPolicy: .confirmDestructiveOnly, revision: 2)),
            .success(OppiExtensionConfiguration(enabled: true, approvalPolicy: .confirmAllChanges, revision: 3)),
        ])
        let refreshGate = SuspensionGate()
        let store = configuredOppiStore()

        let enable = Task { @MainActor in
            await store.setOppiEnabled(
                true,
                serverId: "server-a",
                request: { enabled, policy, revision in
                    try await gate.write(enabled: enabled, policy: policy, revision: revision)
                },
                fetchAuthoritative: { try await gate.fetchAuthoritative() }
            )
        }
        await gate.waitForFirstWrite()
        await store.setOppiApprovalPolicy(
            .confirmAllChanges,
            serverId: "server-a",
            request: { enabled, policy, revision in
                try await gate.write(enabled: enabled, policy: policy, revision: revision)
            },
            fetchAuthoritative: { try await gate.fetchAuthoritative() }
        )

        let refresh = Task { @MainActor in
            await store.load(
                serverId: "server-a",
                fetchSkills: { [] },
                fetchExtensions: {
                    await refreshGate.suspend()
                    return self.oppiCatalog(configuration: self.disabledOppi)
                }
            )
        }
        await refreshGate.waitUntilSuspended()
        await refreshGate.release()
        await refresh.value
        await gate.releaseFirstWrite()
        await enable.value

        #expect(await gate.calls() == [
            .init(enabled: true, policy: .confirmDestructiveOnly, revision: 1),
            .init(enabled: true, policy: .confirmAllChanges, revision: 2),
        ])
        #expect(store.oppiConfiguration(forServer: "server-a") == OppiExtensionConfiguration(
            enabled: true,
            approvalPolicy: .confirmAllChanges,
            revision: 3
        ))
        #expect(!store.isMutationPending(.oppiEnabled, serverId: "server-a"))
        #expect(!store.isMutationPending(.oppiApprovalPolicy, serverId: "server-a"))
        #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a") == nil)
        #expect(store.mutationError(for: .oppiApprovalPolicy, serverId: "server-a") == nil)
    }

    @Test func newValueRefreshDuringRapidOppiChangesCannotAdvanceCASBasePastWriteResponse() async {
        let gate = OppiWriteGate(responses: [
            .success(OppiExtensionConfiguration(enabled: true, approvalPolicy: .confirmDestructiveOnly, revision: 3)),
            .success(OppiExtensionConfiguration(enabled: true, approvalPolicy: .confirmAllChanges, revision: 4)),
        ])
        let refreshGate = SuspensionGate()
        let store = configuredOppiStore()

        let enable = Task { @MainActor in
            await store.setOppiEnabled(
                true,
                serverId: "server-a",
                request: { enabled, policy, revision in
                    try await gate.write(enabled: enabled, policy: policy, revision: revision)
                },
                fetchAuthoritative: { try await gate.fetchAuthoritative() }
            )
        }
        await gate.waitForFirstWrite()
        await store.setOppiApprovalPolicy(
            .confirmAllChanges,
            serverId: "server-a",
            request: { enabled, policy, revision in
                try await gate.write(enabled: enabled, policy: policy, revision: revision)
            },
            fetchAuthoritative: { try await gate.fetchAuthoritative() }
        )

        let refreshSnapshot = OppiExtensionConfiguration(
            enabled: true,
            approvalPolicy: .confirmDestructiveOnly,
            revision: 2
        )
        let refresh = Task { @MainActor in
            await store.load(
                serverId: "server-a",
                fetchSkills: { [] },
                fetchExtensions: {
                    await refreshGate.suspend()
                    return self.oppiCatalog(configuration: refreshSnapshot)
                }
            )
        }
        await refreshGate.waitUntilSuspended()
        await refreshGate.release()
        await refresh.value
        await gate.releaseFirstWrite()
        await enable.value

        #expect(await gate.calls().map(\.revision) == [1, 3])
        #expect(store.oppiConfiguration(forServer: "server-a")?.revision == 4)
        #expect(!store.isMutationPending(.oppiEnabled, serverId: "server-a"))
        #expect(!store.isMutationPending(.oppiApprovalPolicy, serverId: "server-a"))
    }

    @Test func refreshDuringFailedRapidOppiChangeDoesNotSendQueuedStaleWrite() async {
        let gate = OppiWriteGate(responses: [.failure(status: 500, message: "Persistence failed")])
        let refreshGate = SuspensionGate()
        let store = configuredOppiStore()

        let enable = Task { @MainActor in
            await store.setOppiEnabled(
                true,
                serverId: "server-a",
                request: { enabled, policy, revision in
                    try await gate.write(enabled: enabled, policy: policy, revision: revision)
                },
                fetchAuthoritative: { try await gate.fetchAuthoritative() }
            )
        }
        await gate.waitForFirstWrite()
        await store.setOppiApprovalPolicy(
            .confirmAllChanges,
            serverId: "server-a",
            request: { enabled, policy, revision in
                try await gate.write(enabled: enabled, policy: policy, revision: revision)
            },
            fetchAuthoritative: { try await gate.fetchAuthoritative() }
        )

        let refresh = Task { @MainActor in
            await store.load(
                serverId: "server-a",
                fetchSkills: { [] },
                fetchExtensions: {
                    await refreshGate.suspend()
                    return self.oppiCatalog(configuration: OppiExtensionConfiguration(
                        enabled: true,
                        approvalPolicy: .confirmDestructiveOnly,
                        revision: 2
                    ))
                }
            )
        }
        await refreshGate.waitUntilSuspended()
        await refreshGate.release()
        await refresh.value
        await gate.releaseFirstWrite()
        await enable.value

        #expect(await gate.calls().count == 1)
        #expect(store.oppiConfiguration(forServer: "server-a") == disabledOppi)
        #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a") == "Persistence failed")
        #expect(store.mutationError(for: .oppiApprovalPolicy, serverId: "server-a") == "Persistence failed")
        #expect(!store.isMutationPending(.oppiEnabled, serverId: "server-a"))
        #expect(!store.isMutationPending(.oppiApprovalPolicy, serverId: "server-a"))
    }

    @Test func refreshDuringConflictingRapidOppiChangeAdoptsConflictFetchWithoutDuplicatePut() async {
        let conflict = OppiExtensionConfiguration(enabled: false, approvalPolicy: .readOnly, revision: 7)
        let gate = OppiWriteGate(
            responses: [.failure(status: 409, message: "Oppi extension configuration changed")],
            authoritative: conflict
        )
        let refreshGate = SuspensionGate()
        let store = configuredOppiStore()

        let enable = Task { @MainActor in
            await store.setOppiEnabled(
                true,
                serverId: "server-a",
                request: { enabled, policy, revision in
                    try await gate.write(enabled: enabled, policy: policy, revision: revision)
                },
                fetchAuthoritative: { try await gate.fetchAuthoritative() }
            )
        }
        await gate.waitForFirstWrite()
        await store.setOppiApprovalPolicy(
            .confirmAllChanges,
            serverId: "server-a",
            request: { enabled, policy, revision in
                try await gate.write(enabled: enabled, policy: policy, revision: revision)
            },
            fetchAuthoritative: { try await gate.fetchAuthoritative() }
        )

        let refresh = Task { @MainActor in
            await store.load(
                serverId: "server-a",
                fetchSkills: { [] },
                fetchExtensions: {
                    await refreshGate.suspend()
                    return self.oppiCatalog(configuration: self.disabledOppi)
                }
            )
        }
        await refreshGate.waitUntilSuspended()
        await refreshGate.release()
        await refresh.value
        await gate.releaseFirstWrite()
        await enable.value

        #expect(await gate.calls().count == 1)
        #expect(await gate.fetchCount() == 1)
        #expect(store.oppiConfiguration(forServer: "server-a") == conflict)
        #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a")?.contains("changed elsewhere") == true)
        #expect(store.mutationError(for: .oppiApprovalPolicy, serverId: "server-a")?.contains("changed elsewhere") == true)
        #expect(!store.isMutationPending(.oppiEnabled, serverId: "server-a"))
        #expect(!store.isMutationPending(.oppiApprovalPolicy, serverId: "server-a"))
    }

    @Test func successfulOppiMutationWritesAuthoritativeSnapshotThroughToCache() async {
        let cache = makeCache()
        let store = configuredOppiStore(cache: cache)
        let authoritative = OppiExtensionConfiguration(
            enabled: true,
            approvalPolicy: .confirmDestructiveOnly,
            revision: 2
        )

        await store.setOppiEnabled(
            true,
            serverId: "server-a",
            request: { _, _, _ in authoritative },
            fetchAuthoritative: { authoritative }
        )

        let relaunched = ServerResourceStore(cache: cache, now: { fixedNow })
        await relaunched.load(
            serverId: "server-a",
            fetchSkills: { throw APIError.server(status: 503, message: "Offline") },
            fetchExtensions: { throw APIError.server(status: 503, message: "Offline") }
        )

        #expect(relaunched.oppiConfiguration(forServer: "server-a") == authoritative)
        #expect(relaunched.extensions(forServer: "server-a").first(where: \.isBuiltInOppi)?.state == .on)
    }

    @Test func failedOppiWriteRollsBackToLastAuthoritativeConfiguration() async {
        let store = configuredOppiStore()

        await store.setOppiEnabled(
            true,
            serverId: "server-a",
            request: { _, _, _ in throw APIError.server(status: 500, message: "Persistence failed") },
            fetchAuthoritative: { disabledOppi }
        )

        #expect(store.oppiConfiguration(forServer: "server-a") == disabledOppi)
        #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a") == "Persistence failed")
        #expect(!store.isMutationPending(.oppiEnabled, serverId: "server-a"))
    }

    @Test func conflictAdoptsAuthoritativeConfigurationAndClearsQueuedIntent() async {
        let store = configuredOppiStore()
        let current = OppiExtensionConfiguration(enabled: false, approvalPolicy: .readOnly, revision: 7)

        await store.setOppiEnabled(
            true,
            serverId: "server-a",
            request: { _, _, _ in throw APIError.server(status: 409, message: "Oppi extension configuration changed") },
            fetchAuthoritative: { current }
        )

        #expect(store.oppiConfiguration(forServer: "server-a") == current)
        #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a")?.contains("changed elsewhere") == true)
        #expect(!store.isMutationPending(.oppiEnabled, serverId: "server-a"))
    }

    @Test func failedConflictRefetchKeepsLastTrustworthyConfigOfflineUntilRefreshRecovers() async {
        let writeGate = SuspensionGate()
        let store = configuredOppiStore()
        var writeRevisions: [Int] = []

        let enabledMutation = Task { @MainActor in
            await store.setOppiEnabled(
                true,
                serverId: "server-a",
                request: { _, _, revision in
                    writeRevisions.append(revision)
                    await writeGate.suspend()
                    throw APIError.server(status: 409, message: "Oppi extension configuration changed")
                },
                fetchAuthoritative: {
                    throw APIError.server(status: 503, message: "Authoritative refetch unavailable")
                }
            )
        }
        await writeGate.waitUntilSuspended()

        await store.setOppiApprovalPolicy(
            .confirmAllChanges,
            serverId: "server-a",
            request: { _, _, revision in
                writeRevisions.append(revision)
                return self.disabledOppi
            },
            fetchAuthoritative: { self.disabledOppi }
        )
        await writeGate.release()
        await enabledMutation.value

        #expect(writeRevisions == [1])
        #expect(store.oppiConfiguration(forServer: "server-a") == disabledOppi)
        #expect(store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(!store.mutationsAllowed(for: .extensions, serverId: "server-a"))
        #expect(!store.isMutationPending(.oppiEnabled, serverId: "server-a"))
        #expect(!store.isMutationPending(.oppiApprovalPolicy, serverId: "server-a"))
        #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a")?.contains("changed elsewhere") == true)
        #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a")?.contains("Authoritative refetch unavailable") == true)
        #expect(store.mutationError(for: .oppiApprovalPolicy, serverId: "server-a")?.contains("changed elsewhere") == true)
        #expect(store.mutationError(for: .oppiApprovalPolicy, serverId: "server-a")?.contains("Authoritative refetch unavailable") == true)

        let recovered = OppiExtensionConfiguration(enabled: false, approvalPolicy: .readOnly, revision: 8)
        await store.load(
            serverId: "server-a",
            fetchSkills: { [] },
            fetchExtensions: { self.oppiCatalog(configuration: recovered) }
        )

        #expect(store.oppiConfiguration(forServer: "server-a") == recovered)
        #expect(!store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(store.mutationsAllowed(for: .extensions, serverId: "server-a"))
        #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a") == nil)
        #expect(store.mutationError(for: .oppiApprovalPolicy, serverId: "server-a") == nil)
    }

    @Test func failedConflictRefetchPersistsLockoutAndRelaunchKeepsDisplayedConfigurationReadOnly() async throws {
        let cache = makeCache()
        let normalExtension = extensionSummary(id: "normal-extension", state: .on)
        let store = configuredStore(cache: cache, skills: [skill(id: "skill", state: .enabled)])
        store.replaceExtensions(
            [extensionSummary(id: "oppi", state: .off, kind: .builtIn), normalExtension],
            oppiConfiguration: disabledOppi,
            serverId: "server-a"
        )

        await store.setOppiEnabled(
            true,
            serverId: "server-a",
            request: { _, _, _ in
                throw APIError.server(status: 409, message: "Oppi extension configuration changed")
            },
            fetchAuthoritative: {
                throw APIError.server(status: 503, message: "Authoritative refetch unavailable")
            }
        )

        let lockedSnapshot = try #require(await cache.loadServerResourceCatalog(serverId: "server-a"))
        #expect(lockedSnapshot.oppiRequiresAuthoritativeRefresh)
        #expect(lockedSnapshot.oppiConfiguration == disabledOppi)

        let relaunched = ServerResourceStore(cache: cache, now: { fixedNow })
        var refreshAttempts = 0
        await relaunched.load(
            serverId: "server-a",
            fetchSkills: {
                refreshAttempts += 1
                throw CancellationError()
            },
            fetchExtensions: {
                refreshAttempts += 1
                throw CancellationError()
            }
        )

        #expect(refreshAttempts == 2)
        #expect(relaunched.hasLoadedExtensions(forServer: "server-a"))
        #expect(relaunched.extensions(forServer: "server-a").map(\.id) == ["oppi", "normal-extension"])
        #expect(relaunched.oppiConfiguration(forServer: "server-a") == disabledOppi)
        #expect(relaunched.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(relaunched.requiresAuthoritativeOppiRefresh(forServer: "server-a"))
        #expect(!relaunched.mutationsAllowed(for: .extensions, serverId: "server-a"))

        var mutationRequests = 0
        await relaunched.setExtensionEnabled(
            id: normalExtension.id,
            enabled: false,
            serverId: "server-a",
            request: { _, _ in
                mutationRequests += 1
                return normalExtension
            }
        )
        await relaunched.setOppiEnabled(
            true,
            serverId: "server-a",
            request: { _, _, _ in
                mutationRequests += 1
                return self.disabledOppi
            },
            fetchAuthoritative: { self.disabledOppi }
        )
        await relaunched.setOppiApprovalPolicy(
            .readOnly,
            serverId: "server-a",
            request: { _, _, _ in
                mutationRequests += 1
                return self.disabledOppi
            },
            fetchAuthoritative: { self.disabledOppi }
        )

        #expect(mutationRequests == 0)
        #expect(await cache.loadServerResourceCatalog(serverId: "server-a")?.oppiRequiresAuthoritativeRefresh == true)
    }

    @Test func successfulAuthoritativeRefreshClearsAndPersistsRelaunchedLockoutWhileCancellationDoesNot() async throws {
        let cache = makeCache()
        let locked = ServerResourceCatalogSnapshot(
            skills: [],
            extensions: [extensionSummary(id: "oppi", state: .off, kind: .builtIn)],
            oppiConfiguration: disabledOppi,
            savedAt: fixedNow,
            skillsLoaded: false,
            extensionsLoaded: true,
            skillsSavedAt: nil,
            extensionsSavedAt: fixedNow,
            oppiRequiresAuthoritativeRefresh: true
        )
        await cache.saveServerResourceCatalog(locked, serverId: "server-a")
        let store = ServerResourceStore(cache: cache, now: { fixedNow })

        await store.load(
            serverId: "server-a",
            fetchSkills: { throw URLError(.cancelled) },
            fetchExtensions: { throw URLError(.cancelled) }
        )

        #expect(store.requiresAuthoritativeOppiRefresh(forServer: "server-a"))
        #expect(!store.mutationsAllowed(for: .extensions, serverId: "server-a"))
        #expect(await cache.loadServerResourceCatalog(serverId: "server-a") == locked)

        let recovered = OppiExtensionConfiguration(
            enabled: true,
            approvalPolicy: .readOnly,
            revision: 8
        )
        await store.load(
            serverId: "server-a",
            fetchSkills: { [] },
            fetchExtensions: { self.oppiCatalog(configuration: recovered) }
        )

        #expect(!store.requiresAuthoritativeOppiRefresh(forServer: "server-a"))
        #expect(store.oppiConfiguration(forServer: "server-a") == recovered)
        #expect(store.mutationsAllowed(for: .extensions, serverId: "server-a"))
        #expect(await cache.loadServerResourceCatalog(serverId: "server-a")?.oppiRequiresAuthoritativeRefresh == false)

        let relaunched = ServerResourceStore(cache: cache, now: { fixedNow })
        await relaunched.load(
            serverId: "server-a",
            fetchSkills: { throw CancellationError() },
            fetchExtensions: { throw CancellationError() }
        )
        #expect(!relaunched.requiresAuthoritativeOppiRefresh(forServer: "server-a"))
        #expect(relaunched.oppiConfiguration(forServer: "server-a") == recovered)
        #expect(relaunched.mutationsAllowed(for: .extensions, serverId: "server-a"))
    }

    @Test func oppiDetailRefreshesCachedConfigurationWhenAuthoritativeRefreshIsRequired() {
        #expect(!oppiDetailShouldRefresh(
            configuration: disabledOppi,
            requiresAuthoritativeRefresh: false
        ))
        #expect(oppiDetailShouldRefresh(
            configuration: disabledOppi,
            requiresAuthoritativeRefresh: true
        ))
        #expect(oppiDetailShouldRefresh(
            configuration: nil,
            requiresAuthoritativeRefresh: false
        ))
    }

    @Test func refreshCancellationCannotEraseNewerFailedConflictRecovery() async {
        for cancellation in RefreshCancellationRepresentation.allCases {
            let cache = makeCache()
            let extensionGate = SuspensionGate()
            let store = configuredOppiStore(cache: cache)

            let refresh = Task { @MainActor in
                await store.load(
                    serverId: "server-a",
                    fetchSkills: { [] },
                    fetchExtensions: {
                        await extensionGate.suspend()
                        return try cancellation.raise() as ServerExtensionCatalog
                    }
                )
            }
            await extensionGate.waitUntilSuspended()

            await store.setOppiEnabled(
                true,
                serverId: "server-a",
                request: { _, _, _ in
                    throw APIError.server(status: 409, message: "Oppi extension configuration changed")
                },
                fetchAuthoritative: {
                    throw APIError.server(status: 503, message: "Authoritative refetch unavailable")
                }
            )

            #expect(store.requiresAuthoritativeOppiRefresh(forServer: "server-a"))
            #expect(store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
            #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a")?.contains("changed elsewhere") == true)

            if cancellation == .cancelledTask {
                refresh.cancel()
            }
            await extensionGate.release()
            await refresh.value

            let extensionsSync = store.syncState(for: .extensions, serverId: "server-a")
            #expect(!extensionsSync.isSyncing)
            #expect(extensionsSync.lastSyncFailed)
            #expect(store.oppiConfiguration(forServer: "server-a") == disabledOppi)
            #expect(store.requiresAuthoritativeOppiRefresh(forServer: "server-a"))
            #expect(!store.mutationsAllowed(for: .extensions, serverId: "server-a"))
            #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a")?.contains("changed elsewhere") == true)
            #expect(store.mutationError(for: .oppiEnabled, serverId: "server-a")?.contains("Authoritative refetch unavailable") == true)
            #expect(await cache.loadServerResourceCatalog(serverId: "server-a")?.oppiRequiresAuthoritativeRefresh == true)
        }
    }

    @Test func refreshStartedBeforeFailedConflictRefetchCannotReenableStaleConfiguration() async {
        let refreshGate = SuspensionGate()
        let store = configuredOppiStore()
        let staleRefresh = OppiExtensionConfiguration(
            enabled: true,
            approvalPolicy: .confirmAllChanges,
            revision: 2
        )

        let refresh = Task { @MainActor in
            await store.load(
                serverId: "server-a",
                fetchSkills: { [] },
                fetchExtensions: {
                    await refreshGate.suspend()
                    return self.oppiCatalog(configuration: staleRefresh)
                }
            )
        }
        await refreshGate.waitUntilSuspended()

        await store.setOppiEnabled(
            true,
            serverId: "server-a",
            request: { _, _, _ in
                throw APIError.server(status: 409, message: "Oppi extension configuration changed")
            },
            fetchAuthoritative: {
                throw APIError.server(status: 503, message: "Authoritative refetch unavailable")
            }
        )
        await refreshGate.release()
        await refresh.value

        #expect(store.oppiConfiguration(forServer: "server-a") == disabledOppi)
        #expect(store.syncState(for: .extensions, serverId: "server-a").lastSyncFailed)
        #expect(!store.mutationsAllowed(for: .extensions, serverId: "server-a"))
        #expect(!store.isMutationPending(.oppiEnabled, serverId: "server-a"))
    }

    @Test func oppiAvailabilityNativeSwitchIsTheOnlyAccessible44PointControl() throws {
        let store = configuredOppiStore()
        let controller = UIHostingController(rootView:
            NavigationStack {
                OppiExtensionDetailView(target: ServerResourceDetailNavTarget(
                    serverId: "server-a",
                    kind: .extension,
                    resourceId: "oppi"
                ))
            }
            .environment(store)
            .environment(ServerStore())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let nativeSwitch = try #require(firstSubview(ofType: UISwitch.self, in: controller.view))
        #expect(nativeSwitch.accessibilityIdentifier == "extensions.oppi.enabled")
        #expect(nativeSwitch.isAccessibilityElement)
        #expect(nativeSwitch.accessibilityFrame.height >= 44)
        #expect(nativeSwitch.superview is UIControl)
        #expect(nativeSwitch.superview?.bounds.height ?? 0 >= 44)
        #expect(accessibleSubviews(in: controller.view).filter { $0 is UISwitch }.count == 1)
    }

    private var fixedNow: Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    private var disabledOppi: OppiExtensionConfiguration {
        OppiExtensionConfiguration(enabled: false, approvalPolicy: .confirmDestructiveOnly, revision: 1)
    }

    private func configuredOppiStore(cache: TimelineCache? = nil) -> ServerResourceStore {
        configuredStore(cache: cache ?? makeCache(), skills: [])
    }

    private func configuredStore(
        cache: TimelineCache? = nil,
        skills: [ServerSkillSummary]
    ) -> ServerResourceStore {
        let store = ServerResourceStore(cache: cache ?? makeCache(), now: { fixedNow })
        store.replaceSkills(skills, serverId: "server-a")
        store.replaceExtensions(
            [extensionSummary(id: "oppi", state: .off, kind: .builtIn)],
            oppiConfiguration: disabledOppi,
            serverId: "server-a"
        )
        return store
    }

    private func oppiCatalog(configuration: OppiExtensionConfiguration) -> ServerExtensionCatalog {
        ServerExtensionCatalog(
            extensions: [extensionSummary(
                id: "oppi",
                state: configuration.enabled ? .on : .off,
                kind: .builtIn
            )],
            oppiConfiguration: configuration
        )
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
            oppiConfiguration: disabledOppi,
            savedAt: fixedNow
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

@MainActor
private func firstSubview<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
    if let match = root as? T { return match }
    for child in root.subviews {
        if let match = firstSubview(ofType: type, in: child) { return match }
    }
    return nil
}

@MainActor
private func accessibleSubviews(in root: UIView) -> [UIView] {
    let children = root.subviews.flatMap { accessibleSubviews(in: $0) }
    return (root.isAccessibilityElement ? [root] : []) + children
}

private enum RefreshCacheState: CaseIterable {
    case cold
    case partial
    case full

    func snapshot(
        skills: [ServerSkillSummary],
        extensions: [ServerExtensionSummary],
        configuration: OppiExtensionConfiguration
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
                oppiConfiguration: nil,
                savedAt: skillsSavedAt,
                skillsLoaded: true,
                extensionsLoaded: false,
                skillsSavedAt: skillsSavedAt,
                extensionsSavedAt: nil,
                oppiRequiresAuthoritativeRefresh: false
            )
        case .full:
            return ServerResourceCatalogSnapshot(
                skills: skills,
                extensions: extensions,
                oppiConfiguration: configuration,
                savedAt: extensionsSavedAt,
                skillsLoaded: true,
                extensionsLoaded: true,
                skillsSavedAt: skillsSavedAt,
                extensionsSavedAt: extensionsSavedAt,
                oppiRequiresAuthoritativeRefresh: false
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

private actor OppiWriteGate {
    enum Response: Sendable {
        case success(OppiExtensionConfiguration)
        case failure(status: Int, message: String)
    }

    struct Call: Equatable, Sendable {
        let enabled: Bool
        let policy: OppiApprovalPolicy
        let revision: Int
    }

    private var responses: [Response]
    private let authoritative: OppiExtensionConfiguration
    private var recordedCalls: [Call] = []
    private var authoritativeFetchCount = 0
    private var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWriteRelease: CheckedContinuation<Void, Never>?

    init(
        responses: [OppiExtensionConfiguration],
        authoritative: OppiExtensionConfiguration = OppiExtensionConfiguration(
            enabled: false,
            approvalPolicy: .readOnly,
            revision: 0
        )
    ) {
        self.responses = responses.map(Response.success)
        self.authoritative = authoritative
    }

    init(
        responses: [Response],
        authoritative: OppiExtensionConfiguration = OppiExtensionConfiguration(
            enabled: false,
            approvalPolicy: .readOnly,
            revision: 0
        )
    ) {
        self.responses = responses
        self.authoritative = authoritative
    }

    func write(
        enabled: Bool,
        policy: OppiApprovalPolicy,
        revision: Int
    ) async throws -> OppiExtensionConfiguration {
        recordedCalls.append(Call(enabled: enabled, policy: policy, revision: revision))
        if recordedCalls.count == 1 {
            let waiters = firstWriteWaiters
            firstWriteWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { firstWriteRelease = $0 }
        }
        switch responses.removeFirst() {
        case .success(let configuration):
            return configuration
        case .failure(let status, let message):
            throw APIError.server(status: status, message: message)
        }
    }

    func fetchAuthoritative() -> OppiExtensionConfiguration {
        authoritativeFetchCount += 1
        return authoritative
    }

    func waitForFirstWrite() async {
        guard recordedCalls.isEmpty else { return }
        await withCheckedContinuation { firstWriteWaiters.append($0) }
    }

    func releaseFirstWrite() {
        firstWriteRelease?.resume()
        firstWriteRelease = nil
    }

    func calls() -> [Call] {
        recordedCalls
    }

    func fetchCount() -> Int {
        authoritativeFetchCount
    }
}
