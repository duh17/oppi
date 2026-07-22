import Foundation
import Testing
@testable import Oppi

@Suite("Server Skills presentation")
@MainActor
struct ServerSkillListPresentationTests {
    @Test func groupsNeedsAttentionEnabledAndDisabledInExactOrder() {
        let rows = [
            skill(id: "disabled-z", name: "Zulu", state: .disabled),
            skill(id: "enabled-z", name: "Zulu", state: .enabled),
            skill(id: "error", name: "Broken", state: .error, loadError: "Invalid frontmatter"),
            skill(id: "enabled-a", name: "Alpha", state: .enabled),
        ]

        let presentation = ServerSkillListPresentation(skills: rows, query: "")

        #expect(presentation.sections.map(\.kind) == [.needsAttention, .enabled, .disabled])
        #expect(presentation.sections[0].skills.map(\.id) == ["error"])
        #expect(presentation.sections[1].skills.map(\.id) == ["enabled-a", "enabled-z"])
        #expect(presentation.sections[2].skills.map(\.id) == ["disabled-z"])
    }

    @Test func searchMatchesNameDescriptionProvenanceAndStateText() {
        let rows = [
            skill(id: "release", name: "Release", description: "Checks shipping readiness", state: .enabled),
            skill(id: "reddit", name: "Reddit", provenance: "~/.agents/skills", state: .disabled),
        ]

        #expect(ServerSkillListPresentation(skills: rows, query: "shipping").visibleSkills.map(\.id) == ["release"])
        #expect(ServerSkillListPresentation(skills: rows, query: ".agents").visibleSkills.map(\.id) == ["reddit"])
        #expect(ServerSkillListPresentation(skills: rows, query: "disabled").visibleSkills.map(\.id) == ["reddit"])
    }

    @Test func packageNameIsSearchableAndAppearsBeforeProvenanceInAccessibility() throws {
        let skill = try JSONDecoder().decode(ServerSkillSummary.self, from: Data("""
        {"id":"review-tools","name":"Review tools","description":"Package skill.","provenance":{"kind":"package","label":"Configured package source"},"path":"/private/var/folders/package/SKILL.md","packageName":"@scope/review-tools","state":"enabled","warnings":[]}
        """.utf8))

        #expect(ServerSkillListPresentation(skills: [skill], query: "@scope/review-tools").visibleSkills.map(\.id) == ["review-tools"])
        #expect(ServerSkillListPresentation.accessibilityLabel(for: skill) == "Review tools, @scope/review-tools, Configured package source, Enabled")
    }

    @Test func filteredNoResultsIsDistinctFromEmptyCatalog() {
        let rows = [skill(id: "release", name: "Release", state: .enabled)]

        let filtered = ServerSkillListPresentation(skills: rows, query: "missing")
        let empty = ServerSkillListPresentation(skills: [], query: "")

        #expect(filtered.isFilteredNoResults)
        #expect(!filtered.isCatalogEmpty)
        #expect(empty.isCatalogEmpty)
        #expect(!empty.isFilteredNoResults)
    }

    @Test func catalogPhaseDistinguishesFirstLoadCachedOfflineAndNoCacheFailure() {
        #expect(ServerSkillCatalogPresentationState.resolve(
            hasLoaded: false,
            isSyncing: true,
            lastSyncFailed: false,
            hasVisibleRows: false,
            isFilteredNoResults: false
        ) == .firstLoad)
        #expect(ServerSkillCatalogPresentationState.resolve(
            hasLoaded: true,
            isSyncing: false,
            lastSyncFailed: true,
            hasVisibleRows: true,
            isFilteredNoResults: false
        ) == .cachedOffline)
        #expect(ServerSkillCatalogPresentationState.resolve(
            hasLoaded: false,
            isSyncing: false,
            lastSyncFailed: true,
            hasVisibleRows: false,
            isFilteredNoResults: false
        ) == .unavailable)
        #expect(ServerSkillCatalogPresentationState.resolve(
            hasLoaded: true,
            isSyncing: false,
            lastSyncFailed: false,
            hasVisibleRows: false,
            isFilteredNoResults: false
        ) == .empty)
    }

    @Test func rowAccessibilityIncludesNameProvenanceAndState() {
        let row = skill(id: "broken", name: "Broken", provenance: "Pi user settings", state: .error)

        #expect(ServerSkillListPresentation.accessibilityLabel(for: row) == "Broken, Pi user settings, Error")
    }

    @Test func detailRetryCancelsEarlierGenerationAndKeepsLatestResponse() async {
        let target = ServerResourceDetailNavTarget(serverId: "server-a", kind: .skill, resourceId: "release")
        let initial = ServerSkillDetail(summary: skill(id: "release", name: "Initial", state: .disabled), skillMarkdown: "", files: [])
        let retried = ServerSkillDetail(summary: skill(id: "release", name: "Retried", state: .enabled), skillMarkdown: "# Release", files: [])
        let initialGate = SkillDetailSuspensionGate()
        let retryGate = SkillDetailSuspensionGate()
        let loader = ServerResourceDetailLoader<ServerSkillDetail>(target: target)

        loader.load(target: target) {
            await initialGate.suspend()
            return initial
        }
        await initialGate.waitUntilSuspended()

        loader.load(target: target) {
            await retryGate.suspend()
            return retried
        }
        await retryGate.waitUntilSuspended()
        await retryGate.release()
        await retryGate.waitUntilReturned()

        #expect(loader.detail == retried)
        #expect(loader.usesDetailSummary)

        await initialGate.release()
        await initialGate.waitUntilReturned()
        #expect(loader.detail == retried)
    }

    @Test func healthyDetailRetrySupersedesStaleCatalogErrorForRenderingAndToggle() {
        let staleCatalog = skill(id: "release", name: "Release", state: .error, loadError: "Stale catalog failure")
        let healthyDetail = ServerSkillDetail(
            summary: skill(id: "release", name: "Release", state: .enabled),
            skillMarkdown: "# Release",
            files: []
        )

        let rendered = resolvedServerSkillDetailSummary(
            catalogSummary: staleCatalog,
            freshDetail: healthyDetail
        )

        #expect(rendered == healthyDetail.summary)
        #expect(rendered?.state == .enabled)
    }

    private func skill(
        id: String,
        name: String,
        description: String = "Description",
        provenance: String = "~/.pi/agent/skills",
        state: ServerSkillState,
        loadError: String? = nil
    ) -> ServerSkillSummary {
        ServerSkillSummary(
            id: id,
            name: name,
            description: description,
            provenance: ServerResourceProvenance(kind: .piAgent, label: provenance),
            path: nil,
            state: state,
            loadError: loadError,
            warnings: []
        )
    }
}

private actor SkillDetailSuspensionGate {
    private var suspended = false
    private var returned = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var returnWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        returned = true
        let returnedWaiters = returnWaiters
        returnWaiters.removeAll()
        returnedWaiters.forEach { $0.resume() }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func waitUntilReturned() async {
        guard !returned else { return }
        await withCheckedContinuation { returnWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
