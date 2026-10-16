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
        #expect(SessionListSearchNavigationPersistence.isWorkspaceListCovered(stackDepth: 2))
        #expect(!SessionListSearchNavigationPersistence.isWorkspaceListCovered(stackDepth: 1))
        #expect(
            SessionListSearchNavigationPersistence.isWorkspaceListCovered(
                stackDepth: 1,
                splitDetailReplacesList: true
            )
        )
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
}
