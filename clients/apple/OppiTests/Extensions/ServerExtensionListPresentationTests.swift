import Foundation
import Testing
@testable import Oppi

@Suite("Server Extensions presentation")
@MainActor
struct ServerExtensionListPresentationTests {
    @Test func groupsBuiltInFirstThenAttentionEnabledAndDisabled() {
        let rows = [
            extensionRow(id: "disabled", name: "Zulu", state: .off),
            extensionRow(id: "enabled", name: "Alpha", state: .on),
            extensionRow(id: "broken", name: "Broken", state: .error, loadError: "Import failed"),
            extensionRow(id: "other-built-in", name: "Another", kind: .builtIn, state: .on),
        ]

        let presentation = ServerExtensionListPresentation(extensions: rows, query: "")

        #expect(presentation.sections.map(\.kind) == [
            .builtIn,
            .needsAttention,
            .enabledPiExtensions,
            .disabledPiExtensions,
        ])
        #expect(presentation.sections[0].extensions.map(\.id) == ["other-built-in"])
        #expect(presentation.sections[1].extensions.map(\.id) == ["broken"])
        #expect(presentation.sections[2].extensions.map(\.id) == ["enabled"])
        #expect(presentation.sections[3].extensions.map(\.id) == ["disabled"])
    }

    @Test func searchMatchesCapabilityProvenanceKindAndState() {
        let rows = [
            extensionRow(id: "review", name: "Review", description: "Checks pull requests", state: .on),
            extensionRow(id: "package", name: "Package", kind: .package, provenance: "npm:@scope/tools", state: .off),
        ]

        #expect(ServerExtensionListPresentation(extensions: rows, query: "pull requests").visibleExtensions.map(\.id) == ["review"])
        #expect(ServerExtensionListPresentation(extensions: rows, query: "npm:@scope").visibleExtensions.map(\.id) == ["package"])
        #expect(ServerExtensionListPresentation(extensions: rows, query: "package").visibleExtensions.map(\.id) == ["package"])
        #expect(ServerExtensionListPresentation(extensions: rows, query: "disabled").visibleExtensions.map(\.id) == ["package"])
    }

    @Test func packageNameIsSearchableAndAppearsBeforeProvenanceInAccessibility() throws {
        let resource = try JSONDecoder().decode(ServerExtensionSummary.self, from: Data("""
        {"id":"review-tools","name":"Review tools","kind":"package","provenance":{"kind":"package","label":"Configured package source"},"path":"/private/var/folders/package/index.ts","packageName":"@scope/review-tools","state":"on","warnings":[],"isRemovable":false}
        """.utf8))

        #expect(ServerExtensionListPresentation(extensions: [resource], query: "@scope/review-tools").visibleExtensions.map(\.id) == ["review-tools"])
        #expect(ServerExtensionListPresentation.accessibilityLabel(for: resource) == "Review tools, @scope/review-tools, Configured package source, Enabled")
    }

    @Test func noPiExtensionsAndFilteredNoResultsRemainDistinct() {
        let builtIn = extensionRow(id: "built-in", name: "Built-in", kind: .builtIn, state: .off)

        let unfiltered = ServerExtensionListPresentation(extensions: [builtIn], query: "")
        let filtered = ServerExtensionListPresentation(extensions: [builtIn], query: "missing")

        #expect(unfiltered.hasNoPiExtensions)
        #expect(!unfiltered.isFilteredNoResults)
        #expect(filtered.isFilteredNoResults)
    }

    @Test func rowAccessibilityIncludesNameProvenanceAndState() {
        let row = extensionRow(id: "broken", name: "Broken", provenance: "Pi user settings", state: .error)

        #expect(ServerExtensionListPresentation.accessibilityLabel(for: row) == "Broken, Pi user settings, Error")
    }

    @Test func postMutationDetailFailureCannotRevertAuthoritativeCatalogSummary() async {
        let target = ServerResourceDetailNavTarget(serverId: "server-a", kind: .extension, resourceId: "review")
        let staleDetail = ServerExtensionDetail(
            summary: extensionRow(id: "review", name: "Review", state: .off),
            contributedTools: ["review"],
            contributedCommands: nil
        )
        let authoritative = extensionRow(id: "review", name: "Review", state: .on)
        let failureGate = ExtensionDetailSuspensionGate()
        let loader = ServerResourceDetailLoader(initialDetail: staleDetail, target: target)

        loader.invalidateSummaryAfterAuthoritativeMutation()
        loader.load(target: target) {
            await failureGate.suspend()
            throw APIError.server(status: 503, message: "Detail unavailable")
        }
        await failureGate.waitUntilSuspended()
        await failureGate.release()
        await failureGate.waitUntilReturned()

        let rendered = resolvedServerExtensionDetailSummary(
            catalogSummary: authoritative,
            freshDetail: loader.usesDetailSummary ? loader.detail : nil
        )
        #expect(rendered == authoritative)
        #expect(loader.detail == staleDetail)
        #expect(loader.error == "Detail unavailable")
    }

    @Test func targetChangeDiscardsOldServerDetailResponse() async {
        let oldTarget = ServerResourceDetailNavTarget(serverId: "server-a", kind: .extension, resourceId: "shared")
        let newTarget = ServerResourceDetailNavTarget(serverId: "server-b", kind: .extension, resourceId: "shared")
        let oldDetail = ServerExtensionDetail(
            summary: extensionRow(id: "shared", name: "Server A", state: .on),
            contributedTools: nil,
            contributedCommands: nil
        )
        let newDetail = ServerExtensionDetail(
            summary: extensionRow(id: "shared", name: "Server B", state: .off),
            contributedTools: nil,
            contributedCommands: nil
        )
        let oldGate = ExtensionDetailSuspensionGate()
        let newGate = ExtensionDetailSuspensionGate()
        let loader = ServerResourceDetailLoader<ServerExtensionDetail>(target: oldTarget)

        loader.load(target: oldTarget) {
            await oldGate.suspend()
            return oldDetail
        }
        await oldGate.waitUntilSuspended()
        loader.load(target: newTarget) {
            await newGate.suspend()
            return newDetail
        }
        await newGate.waitUntilSuspended()
        await newGate.release()
        await newGate.waitUntilReturned()
        await oldGate.release()
        await oldGate.waitUntilReturned()

        #expect(loader.detail == newDetail)
        #expect(loader.target == newTarget)
    }

    @Test func healthyDetailRetrySupersedesStaleCatalogErrorForRenderingAndToggle() {
        let staleCatalog = extensionRow(
            id: "review",
            name: "Review",
            state: .error,
            loadError: "Stale catalog failure"
        )
        let healthyDetail = ServerExtensionDetail(
            summary: extensionRow(id: "review", name: "Review", state: .on),
            contributedTools: nil,
            contributedCommands: nil
        )

        let rendered = resolvedServerExtensionDetailSummary(
            catalogSummary: staleCatalog,
            freshDetail: healthyDetail
        )

        #expect(rendered == healthyDetail.summary)
        #expect(rendered?.state == .on)
    }

    @Test func theOppiBarNeedsAUserOwnedEntryFile() {
        let path = "/Users/chen/.pi/agent/extensions/workflow.ts"

        #expect(ServerExtensionListPresentation.editablePath(
            for: extensionRow(id: "workflow", name: "workflow", state: .on, path: path)
        ) == path)
        // A disabled or broken extension is still a file the user can revise.
        #expect(ServerExtensionListPresentation.editablePath(
            for: extensionRow(id: "broken", name: "broken", state: .error, path: path)
        ) == path)

        let hidden: [(String, ServerExtensionSummary)] = [
            ("package", extensionRow(id: "p", name: "p", kind: .package, state: .on, path: "/opt/node_modules/p/index.js")),
            ("package provenance", extensionRow(id: "q", name: "q", provenanceKind: .package, state: .on, path: path)),
            ("built-in", extensionRow(id: "b", name: "b", kind: .builtIn, state: .on, path: "builtin:b")),
            ("directory", extensionRow(id: "d", name: "d", kind: .directory, state: .on, path: "/Users/chen/.pi/agent/extensions/d")),
            ("unknown kind", extensionRow(id: "u", name: "u", kind: .unknown, state: .on, path: path)),
            ("no path", extensionRow(id: "n", name: "n", state: .on, path: nil)),
            ("relative path", extensionRow(id: "r", name: "r", state: .on, path: "extensions/r.ts")),
            ("multi-line path", extensionRow(id: "m", name: "m", state: .on, path: "/a.ts\n/b.ts")),
        ]
        for (reason, row) in hidden {
            #expect(ServerExtensionListPresentation.editablePath(for: row) == nil, "\(reason)")
        }
    }

    private func extensionRow(
        id: String,
        name: String,
        description: String? = nil,
        kind: ServerExtensionKind = .file,
        provenance: String? = nil,
        provenanceKind: ServerResourceProvenanceKind? = nil,
        state: ServerExtensionState,
        loadError: String? = nil,
        path: String? = nil
    ) -> ServerExtensionSummary {
        ServerExtensionSummary(
            id: id,
            name: name,
            description: description,
            kind: kind,
            provenance: ServerResourceProvenance(
                kind: provenanceKind ?? (kind == .builtIn ? .builtIn : (kind == .package ? .package : .userSettings)),
                label: provenance ?? (kind == .builtIn ? "Built-in extension" : "Pi user settings")
            ),
            path: path,
            state: state,
            loadError: loadError,
            warnings: [],
            isRemovable: false
        )
    }
}

private actor ExtensionDetailSuspensionGate {
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
