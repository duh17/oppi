import Foundation
import Testing
@testable import Oppi

@Suite("Session list search survives opening a result")
struct SessionListSearchNavigationPersistenceTests {
    @Test func typingAtRootHoldsTheQuery() {
        var state = SessionListSearchNavigationPersistence.State()
        state = reduce(state, .searchTextChanged("usdz"), covered: false)
        state = reduce(state, .searchPresentationChanged(true), covered: false)

        #expect(state.searchText == "usdz")
        #expect(state.heldQuery == "usdz")
        #expect(state.isSearchPresented)
        #expect(!state.preservesSearchAcrossDismiss)
    }

    @Test func openingAResultThenSystemDismissKeepsTheQuery() {
        var state = searching("usdz")

        state = reduce(state, .willOpenDestination, covered: false)
        #expect(state.preservesSearchAcrossDismiss)

        // SwiftUI can dismiss searchable before the navigation path updates.
        state = reduce(state, .searchPresentationChanged(false), covered: false)
        #expect(state.searchText == "usdz")
        #expect(state.heldQuery == "usdz")
        #expect(!state.isSearchPresented)

        state = reduce(state, .searchTextChanged(""), covered: false)
        #expect(state.searchText == "usdz")

        state = reduce(state, .coverageChanged(isCovered: true), covered: true)
        #expect(state.searchText == "usdz")
    }

    @Test func backRestoresFlattenedSearchWithoutTreatingItAsCancel() {
        var state = searching("usdz")
        state = reduce(state, .willOpenDestination, covered: false)
        state = reduce(state, .searchPresentationChanged(false), covered: false)
        state = reduce(state, .searchTextChanged(""), covered: false)
        state = reduce(state, .coverageChanged(isCovered: true), covered: true)

        state = reduce(state, .coverageChanged(isCovered: false), covered: false)

        #expect(state.searchText == "usdz")
        #expect(state.isSearchPresented)
        #expect(!state.preservesSearchAcrossDismiss)
        #expect(SessionListSearchPresentation.hasQuery(state.searchText))
    }

    @Test func cancelAtRootClearsSearch() {
        var state = searching("usdz")

        state = reduce(state, .searchPresentationChanged(false), covered: false)

        #expect(state.searchText.isEmpty)
        #expect(state.heldQuery == nil)
        #expect(!state.isSearchPresented)
        #expect(!state.preservesSearchAcrossDismiss)
    }

    @Test func clearingTheFieldAtRootDropsTheHeldQuery() {
        var state = searching("usdz")

        state = reduce(state, .searchTextChanged(""), covered: false)

        #expect(state.searchText.isEmpty)
        #expect(state.heldQuery == nil)
        #expect(state.isSearchPresented)
    }

    @Test func cancelAfterReturningClearsSearch() {
        var state = searching("usdz")
        state = reduce(state, .willOpenDestination, covered: false)
        state = reduce(state, .coverageChanged(isCovered: true), covered: true)
        state = reduce(state, .coverageChanged(isCovered: false), covered: false)

        #expect(state.isSearchPresented)
        state = reduce(state, .searchPresentationChanged(false), covered: false)

        #expect(state.searchText.isEmpty)
        #expect(state.heldQuery == nil)
    }

    @Test func resetClearsHeldQueryAndPresentation() {
        var state = searching("usdz")
        state = reduce(state, .willOpenDestination, covered: false)

        state = reduce(state, .reset, covered: true)

        #expect(state == SessionListSearchNavigationPersistence.State())
    }

    @Test func openingWithoutAQueryDoesNotArmPreserve() {
        var state = SessionListSearchNavigationPersistence.State(isSearchPresented: true)

        state = reduce(state, .willOpenDestination, covered: false)
        state = reduce(state, .searchPresentationChanged(false), covered: false)

        #expect(!state.preservesSearchAcrossDismiss)
        #expect(state.searchText.isEmpty)
        #expect(state.heldQuery == nil)
    }

    @Test func whitespaceQueryIsNotASearch() {
        var state = SessionListSearchNavigationPersistence.State()
        state = reduce(state, .searchTextChanged("   "), covered: false)
        state = reduce(state, .willOpenDestination, covered: false)

        #expect(!state.preservesSearchAcrossDismiss)
        #expect(state.heldQuery == nil)
    }

    @Test func compactInboxIsCoveredByAPushedSession() {
        #expect(
            SessionListSearchNavigationPersistence.isInboxCovered(
                isSplitPresentation: false,
                stackDepth: 1
            )
        )
        #expect(
            !SessionListSearchNavigationPersistence.isInboxCovered(
                isSplitPresentation: false,
                stackDepth: 0
            )
        )
        #expect(
            !SessionListSearchNavigationPersistence.isInboxCovered(
                isSplitPresentation: true,
                stackDepth: 1
            )
        )
        #expect(
            SessionListSearchNavigationPersistence.isInboxCovered(
                isSplitPresentation: true,
                stackDepth: 0,
                splitDetailReplacesList: true
            )
        )
        #expect(
            !SessionListSearchNavigationPersistence.isInboxCovered(
                isSplitPresentation: true,
                stackDepth: 0,
                splitDetailReplacesList: false
            )
        )
    }

    @Test func workspaceListIsCoveredByADeeperSession() {
        #expect(
            SessionListSearchNavigationPersistence.isWorkspaceListCovered(
                stackDepth: 2,
                hasSessionDestination: false
            )
        )
        #expect(
            SessionListSearchNavigationPersistence.isWorkspaceListCovered(
                stackDepth: 1,
                hasSessionDestination: true
            )
        )
        #expect(
            !SessionListSearchNavigationPersistence.isWorkspaceListCovered(
                stackDepth: 1,
                hasSessionDestination: false
            )
        )
        #expect(
            SessionListSearchNavigationPersistence.isWorkspaceListCovered(
                stackDepth: 1,
                hasSessionDestination: false,
                splitDetailReplacesList: true
            )
        )
    }

    @Test func inboxAndWorkspaceListWireSearchPersistence() throws {
        let inbox = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        let workspace = try appleSource("Oppi/Features/Workspaces/WorkspaceDetailView.swift")

        #expect(inbox.contains("SessionListSearchNavigationPersistence"))
        #expect(workspace.contains("SessionListSearchNavigationPersistence"))
        #expect(inbox.contains(".willOpenDestination"))
        #expect(workspace.contains(".willOpenDestination"))
        #expect(inbox.contains(".searchFocused($isSearchFieldFocused)"))
        #expect(workspace.contains(".searchFocused($isSearchFieldFocused)"))
        #expect(inbox.contains("isInboxCovered("))
        #expect(workspace.contains("isWorkspaceListCovered("))
        #expect(inbox.contains("inboxSessionSearch"))
        #expect(workspace.contains("workspaceSessionSearchByID"))
        #expect(inbox.contains(".onChange(of: activeServerId)"))
        let hostTask = try sourceSlice(
            inbox,
            start: ".task(id: activeServerId) {",
            end: ".task(id: selectedWorkspace?.workspace.id)"
        )
        #expect(!hostTask.contains("resetLocalHostState"))
        #expect(inbox.contains("applySearchNavigation(.searchTextChanged"))
        #expect(inbox.contains("applySearchNavigation(.searchPresentationChanged"))
        #expect(inbox.contains("restoreSearchAfterCoverageChange()"))
        #expect(inbox.contains("applySearchNavigation(.reset)"))
        #expect(workspace.contains("applySearchNavigation(.searchTextChanged"))
        #expect(workspace.contains("applySearchNavigation(.searchPresentationChanged"))
        #expect(workspace.contains("restoreSearchAfterCoverageChange()"))
        #expect(workspace.contains("importAndResumeLocal"))

        let inboxOpen = try sourceSlice(
            inbox,
            start: "private func openSession(_ item: SessionInboxItem)",
            end: "private func stopSession"
        )
        let routeGuardIndex = try #require(inboxOpen.range(of: "Session route is unavailable")?.upperBound)
        let willOpenIndex = try #require(inboxOpen.range(of: "willOpenDestination")?.lowerBound)
        let navigateIndex = try #require(inboxOpen.range(of: "openWorkspaceSession")?.lowerBound)
        #expect(routeGuardIndex < willOpenIndex)
        #expect(willOpenIndex < navigateIndex)

        let workspaceOpen = try sourceSlice(
            workspace,
            start: "private func openSession(_ session: Session)",
            end: "private func routeToSession"
        )
        #expect(workspaceOpen.contains("willOpenDestination"))

        let localImport = try sourceSlice(
            workspace,
            start: "private func importAndResumeLocal",
            end: "private func isArchiveBucketGroupID"
        )
        let localArmIndex = try #require(localImport.range(of: "willOpenDestination")?.lowerBound)
        let localRouteIndex = try #require(localImport.range(of: "routeToSession")?.lowerBound)
        #expect(localArmIndex < localRouteIndex)
    }

    private func searching(_ query: String) -> SessionListSearchNavigationPersistence.State {
        var state = SessionListSearchNavigationPersistence.State()
        state = reduce(state, .searchPresentationChanged(true), covered: false)
        state = reduce(state, .searchTextChanged(query), covered: false)
        return state
    }

    private func reduce(
        _ state: SessionListSearchNavigationPersistence.State,
        _ event: SessionListSearchNavigationPersistence.Event,
        covered: Bool
    ) -> SessionListSearchNavigationPersistence.State {
        SessionListSearchNavigationPersistence.reduce(
            state,
            event: event,
            isCoveredByDestination: covered
        )
    }

    private func appleSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sourceSlice(_ source: String, start: String, end: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
        else {
            throw SourceSliceError.missing(start: start, end: end)
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private enum SourceSliceError: Error {
        case missing(start: String, end: String)
    }
}
