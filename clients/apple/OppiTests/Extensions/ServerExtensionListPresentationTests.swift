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
            extensionRow(id: "oppi", name: "Oppi", kind: .builtIn, state: .off),
        ]

        let presentation = ServerExtensionListPresentation(extensions: rows, query: "")

        #expect(presentation.sections.map(\.kind) == [
            .builtIn,
            .needsAttention,
            .enabledPiExtensions,
            .disabledPiExtensions,
        ])
        #expect(presentation.sections[0].extensions.map(\.id) == ["oppi", "other-built-in"])
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
        #expect(ServerExtensionListPresentation(extensions: rows, query: "off").visibleExtensions.map(\.id) == ["package"])
    }

    @Test func packageNameIsSearchableAndAppearsBeforeProvenanceInAccessibility() throws {
        let resource = try JSONDecoder().decode(ServerExtensionSummary.self, from: Data("""
        {"id":"review-tools","name":"Review tools","kind":"package","provenance":{"kind":"package","label":"Configured package source"},"path":"/private/var/folders/package/index.ts","packageName":"@scope/review-tools","state":"on","warnings":[],"isRemovable":false}
        """.utf8))

        #expect(ServerExtensionListPresentation(extensions: [resource], query: "@scope/review-tools").visibleExtensions.map(\.id) == ["review-tools"])
        #expect(ServerExtensionListPresentation.accessibilityLabel(for: resource) == "Review tools, @scope/review-tools, Configured package source, On")
    }

    @Test func pathlessSemanticOppiIsRecognizedWithoutNameBranching() {
        let semanticOppi = extensionRow(id: "oppi", name: "Localized title", kind: .builtIn, state: .off)
        let sameNameButNormal = extensionRow(id: "normal", name: "Oppi", kind: .file, state: .on)

        #expect(ServerExtensionListPresentation.detailKind(for: semanticOppi) == .oppi)
        #expect(ServerExtensionListPresentation.detailKind(for: sameNameButNormal) == .generic)
    }

    @Test func noPiExtensionsAndFilteredNoResultsRemainDistinct() {
        let builtIn = extensionRow(id: "oppi", name: "Oppi", kind: .builtIn, state: .off)

        let unfiltered = ServerExtensionListPresentation(extensions: [builtIn], query: "")
        let filtered = ServerExtensionListPresentation(extensions: [builtIn], query: "missing")

        #expect(unfiltered.hasNoPiExtensions)
        #expect(!unfiltered.isFilteredNoResults)
        #expect(filtered.isFilteredNoResults)
    }

    @Test func offlineOrPendingOppiApprovalChoicesAreUnavailable() {
        #expect(!oppiApprovalPolicyChoicesAreAvailable(
            oppiIsEnabled: true,
            extensionsMutationsAllowed: false
        ))
        #expect(!oppiApprovalPolicyChoicesAreAvailable(
            oppiIsEnabled: true,
            extensionsMutationsAllowed: true,
            anySettingPending: true
        ))
        #expect(!oppiApprovalPolicyChoicesAreAvailable(
            oppiIsEnabled: false,
            extensionsMutationsAllowed: true
        ))
        #expect(oppiApprovalPolicyChoicesAreAvailable(
            oppiIsEnabled: true,
            extensionsMutationsAllowed: true
        ))
    }

    @Test func allOppiSettingControlsDisableWhileAnySettingWriteIsPending() {
        #expect(!oppiSettingsControlsAreAvailable(
            extensionsMutationsAllowed: true,
            anySettingPending: true
        ))
        #expect(oppiSettingsControlsAreAvailable(
            extensionsMutationsAllowed: true,
            anySettingPending: false
        ))
    }

    @Test func approvalChoicesExposeExactConsequenceCopyAndSavedMessage() {
        #expect(OppiApprovalPolicyPresentation(.confirmDestructiveOnly).title == "Confirm destructive only")
        #expect(OppiApprovalPolicyPresentation(.confirmDestructiveOnly).consequence == "Reads run immediately. Create, update, send, stop, resume, fork, run, and pause actions run without approval. Delete, remove, and archive actions require explicit approval.")
        #expect(OppiApprovalPolicyPresentation(.confirmAllChanges).consequence == "Reads run immediately. Every mutation requires explicit approval.")
        #expect(OppiApprovalPolicyPresentation(.readOnly).consequence == "Only allowlisted read commands are available. Mutation requests fail with a read-only error and do not open an approval prompt.")
        #expect(OppiApprovalPolicyPresentation.savedMessage(serverName: "mac-studio") == "Saved on mac-studio. New sessions use this setting. Reload an active session to apply it now.")
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

    private func extensionRow(
        id: String,
        name: String,
        description: String? = nil,
        kind: ServerExtensionKind = .file,
        provenance: String? = nil,
        state: ServerExtensionState,
        loadError: String? = nil
    ) -> ServerExtensionSummary {
        ServerExtensionSummary(
            id: id,
            name: name,
            description: description,
            kind: kind,
            provenance: ServerResourceProvenance(
                kind: kind == .builtIn ? .builtIn : (kind == .package ? .package : .userSettings),
                label: provenance ?? (kind == .builtIn ? "Built-in extension" : "Pi user settings")
            ),
            path: nil,
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
