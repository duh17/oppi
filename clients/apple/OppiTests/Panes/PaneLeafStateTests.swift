import Testing
@testable import Oppi

/// The leaf states of build plan §1.11: one pure resolver for every kind of
/// server, with the connection's status (and its remedy) passed as a value.
@Suite("PaneLeafState")
struct PaneLeafStateTests {
    private let session = PaneRoute.session("s-1")
    private let file = PaneRoute.file(.workspace(id: "ws-1", worktree: nil), path: "a.txt", line: nil)

    private func resolve(
        _ route: PaneRoute,
        _ connection: PaneConnectionStatus,
        _ presence: PaneContentPresence,
        locked: Bool = false
    ) -> PaneLeafState {
        PaneLeafState.resolve(route: route, connection: connection, presence: presence, isLocked: locked)
    }

    /// X1, X2, SD4: content the server says is gone is missing, by kind.
    @Test func contentTheServerNoLongerHasIsMissing() {
        #expect(resolve(session, .connected, .absent) == .missing(.session))
        #expect(resolve(file, .connected, .absent) == .missing(.file))
        #expect(resolve(.files(workspace: "ws-1", path: nil), .connected, .absent) == .missing(.workspace))
    }

    /// X3: an unpaired server is "Server removed", even for cached content.
    @Test func aServerThisDeviceNoLongerPairsIsMissingWhateverIsCached() {
        #expect(resolve(session, .removed, .present) == .missing(.server))
        #expect(resolve(session, .removed, .unknown) == .missing(.server))
    }

    /// X4, O1: an offline server shows content it already had, connecting for
    /// content it must ask about, and its own remedy once it is unreachable.
    @Test func anOfflineServerShowsKnownContentAndWaitsForTheRest() {
        #expect(resolve(session, .connecting, .present) == .content)
        #expect(resolve(session, .unreachable(.retry), .present) == .content)
        #expect(resolve(session, .connecting, .unknown) == .connecting)
        #expect(resolve(session, .connected, .unknown) == .connecting, "a lookup is still out")
        #expect(resolve(session, .unreachable(.retry), .unknown) == .unreachable(.retry))
    }

    /// X9: the Mac's own server stopped or turned off offers the remedy its
    /// connection reports, never "Server removed".
    @Test func theMacsOwnServerOffersItsConnectionsRemedy() {
        #expect(resolve(session, .unreachable(.restart), .unknown) == .unreachable(.restart))
        #expect(resolve(session, .unreachable(.openLoginItems), .unknown) == .unreachable(.openLoginItems))
    }

    /// B2 and the locked state: a scoped lock holds even known content, and a
    /// removed server wins over the lock (there is nothing to unlock).
    @Test func aLockHoldsContentUntilUnlocked() {
        #expect(resolve(session, .connected, .present, locked: true) == .locked)
        #expect(resolve(session, .removed, .present, locked: true) == .missing(.server))
    }

    @Test func aLeafKindFromANewerOppiIsUnsupportedOnAnyServer() {
        let web = PaneRoute.unsupported(kind: "web", raw: [:])
        #expect(resolve(web, .connected, .present) == .unsupported)
        #expect(resolve(web, .removed, .unknown) == .unsupported)
    }

    /// SD2 and the panel states of §1.11: a panel its session has not
    /// published waits while the session works and is unavailable once it
    /// rests; one it cleared, or whose session ended, has ended; and until
    /// panels can be pinned, a panel stands only beside its own chat.
    @Test func aPanelLeafFollowsItsSurfaceAndItsSession() {
        #expect(PaneLeafState.panel(surface: .published, session: .busy, chatShown: true) == .content)
        #expect(PaneLeafState.panel(surface: .published, session: .idle, chatShown: true) == .content)
        #expect(PaneLeafState.panel(surface: .published, session: .ended, chatShown: true) == .ended)
        #expect(PaneLeafState.panel(surface: .cleared, session: .busy, chatShown: true) == .ended)
        #expect(PaneLeafState.panel(surface: .notPublished, session: .busy, chatShown: true) == .waiting)
        #expect(PaneLeafState.panel(surface: .notPublished, session: .idle, chatShown: true) == .unavailable)
        #expect(PaneLeafState.panel(surface: .notPublished, session: .ended, chatShown: true) == .unavailable)
        #expect(PaneLeafState.panel(surface: .published, session: .busy, chatShown: false) == .chatNotShown)
    }
}
