import Foundation
import Testing
@testable import Oppi

/// The Rex screen's two decisions: which Rexes it lists once (a Rex reached
/// straight over Tailscale and through a saved SSH host is one Rex, by its
/// `host_id`, and the direct route wins), and how a pane takes an attachment.
@Suite("Rex direct entry")
struct RexDirectEntryTests {
    private let studio = UUID()
    private let devbox = UUID()

    // MARK: - One Rex, listed once

    /// A saved host whose Rex said the same `host_id` as a listed direct Rex is
    /// left out; one whose Rex is another stays.
    @Test func aSavedHostWhoseRexIsADirectRexIsLeftOut() {
        let saved = [
            RexListDedupe.Saved(id: studio, hostID: "host-studio", learnedAddress: nil, learnedHostID: nil),
            RexListDedupe.Saved(id: devbox, hostID: "host-devbox", learnedAddress: nil, learnedHostID: nil),
        ]
        let direct = [RexListDedupe.Direct(address: "mac-studio-rex.tail0000.ts.net", hostID: "host-studio")]
        #expect(RexListDedupe.savedShown(saved, direct: direct) == [devbox])
    }

    /// Before the direct Rex has said who it is, a saved host that learned the id
    /// of the Rex at that same address answers for it: the host does not flash in
    /// and out while the direct connection opens.
    @Test func aDirectRexNotReadYetIsKnownByWhatTheSavedHostLearned() {
        let saved = [RexListDedupe.Saved(
            id: studio, hostID: nil,
            learnedAddress: "mac-studio-rex.tail0000.ts.net", learnedHostID: "host-studio"
        )]
        let direct = [RexListDedupe.Direct(address: "mac-studio-rex.tail0000.ts.net", hostID: nil)]
        #expect(RexListDedupe.savedShown(saved, direct: direct).isEmpty)
    }

    /// Once the direct Rex has said its own id, only that counts: a saved host
    /// that learned the same address from a different Rex (the address moved to
    /// another machine) is listed.
    @Test func theDirectRexsOwnIdWinsOverWhatAHostLearned() {
        let saved = [RexListDedupe.Saved(
            id: studio, hostID: nil,
            learnedAddress: "rex.tail0000.ts.net", learnedHostID: "host-old"
        )]
        let direct = [RexListDedupe.Direct(address: "rex.tail0000.ts.net", hostID: "host-new")]
        #expect(RexListDedupe.savedShown(saved, direct: direct) == [studio])
    }

    /// A saved host whose Rex has not said who it is yet, or with no direct Rex
    /// listed at all, is listed: nothing is hidden on a guess.
    @Test func aHostWithNoKnownIdOrNoDirectRexIsListed() {
        let unknown = RexListDedupe.Saved(id: studio, hostID: nil, learnedAddress: nil, learnedHostID: nil)
        let known = RexListDedupe.Saved(id: devbox, hostID: "host-devbox", learnedAddress: nil, learnedHostID: nil)
        let direct = [RexListDedupe.Direct(address: "rex.tail0000.ts.net", hostID: nil)]
        #expect(RexListDedupe.savedShown([unknown, known], direct: direct) == [studio, devbox])
        #expect(RexListDedupe.savedShown([unknown, known], direct: []) == [studio, devbox])
    }

    // MARK: - How a pane takes an attachment

    /// A Rex that takes uploads takes them itself on any route, Tailscale alone
    /// included; else the host's side commands; else Attach is not offered and
    /// Paste says why.
    @Test func rexsOwnUploadWinsThenSideCommandsThenTheReason() {
        let reason = RexTailnetTransport.sideCommandsReason
        #expect(SSHTerminalAttachRoute.choose(connectionUploads: true, sideCommandsUnavailable: reason) == .connection)
        #expect(SSHTerminalAttachRoute.choose(connectionUploads: true, sideCommandsUnavailable: nil) == .connection)
        #expect(SSHTerminalAttachRoute.choose(connectionUploads: false, sideCommandsUnavailable: nil) == .sideCommand)
        let older = SSHTerminalAttachRoute.choose(connectionUploads: false, sideCommandsUnavailable: reason)
        #expect(older == .unavailable(reason))
        #expect(!older.takesFiles && SSHTerminalAttachRoute.connection.takesFiles)
    }

    /// Rex's upload reservation: a lone file has no batch, and files sent
    /// together share one so Rex types their paths in one paste, in order. A
    /// file's bytes go in Rex's message size and end with the empty message
    /// that half-closes the stream; an empty file is that message alone.
    @Test func anUploadReservesItsBatchAndEndsItsStream() {
        let ref = UUID()
        let lone = RexUpload.beginArguments(name: "oppi-1.png", size: 3, ref: ref, batch: nil, index: 0, count: 1)
        #expect(lone["ref"] as? String == "upload:\(ref.uuidString.lowercased())")
        #expect(lone["batch"] == nil && lone["index"] == nil && lone["count"] == nil)
        let batch = UUID()
        let second = RexUpload.beginArguments(name: "oppi-2.pdf", size: 9, ref: ref, batch: batch, index: 1, count: 2)
        #expect(second["batch"] as? String == batch.uuidString.lowercased())
        #expect(second["index"] as? Int == 1 && second["count"] as? Int == 2)

        let bytes = Data(repeating: 7, count: RexUpload.chunkBytes * 2 + 5)
        let messages = RexUpload.messages(bytes)
        #expect(messages.map(\.count) == [RexUpload.chunkBytes, RexUpload.chunkBytes, 5, 0])
        #expect(Data(messages.joined()) == bytes)
        #expect(RexUpload.messages(Data()) == [Data()])
    }
}
