import Testing
import UIKit
@testable import Oppi

/// One sheet per window across its panes: a second pane's sheet waits for
/// the first, presents when it goes, and leaves the line when dismissed
/// before its turn or when its pane is gone.
@MainActor
@Suite("Pane sheet arbiter")
struct PaneSheetArbiterTests {
    private let chat = Self.id("leaf-1")
    private let files = Self.id("leaf-2")
    private let git = Self.id("leaf-3")

    private static func id(_ raw: String) -> PaneID {
        guard let id = PaneID(raw) else { preconditionFailure("\(raw) is not a pane id") }
        return id
    }

    @Test func aSecondPanesSheetWaitsForTheFirstAndPresentsWhenItGoes() {
        let arbiter = PaneSheetArbiter()
        var presented: [String] = []
        arbiter.request(owner: chat, container: UIViewController(), onCancel: nil) { presented.append("chat"); return true }
        arbiter.request(owner: files, container: UIViewController(), onCancel: nil) { presented.append("files"); return true }
        arbiter.request(owner: git, container: UIViewController(), onCancel: nil) { presented.append("git"); return true }
        #expect(presented == ["chat"])
        #expect(arbiter.waitingOwners == [files, git], "the waiting panes, oldest first, for their grips' dots")

        arbiter.sheetDidDismiss()
        #expect(presented == ["chat", "files"])
        #expect(arbiter.waitingOwners == [git])
        arbiter.sheetDidDismiss()
        arbiter.sheetDidDismiss()
        #expect(presented == ["chat", "files", "git"])
        #expect(arbiter.waitingOwners.isEmpty)

        arbiter.request(owner: chat, container: UIViewController(), onCancel: nil) { presented.append("again"); return true }
        #expect(presented.last == "again", "with no sheet showing, a sheet presents at once")
    }

    @Test func aWaitingSheetDismissedBeforeItsTurnLeavesTheLine() {
        let arbiter = PaneSheetArbiter()
        var presented: [String] = []
        var cancelled = 0
        let waiting = UIViewController()
        arbiter.request(owner: chat, container: UIViewController(), onCancel: nil) { presented.append("chat"); return true }
        arbiter.request(
            owner: files, container: waiting, onCancel: { cancelled += 1 },
            present: { presented.append("files"); return true }
        )
        #expect(PaneSheetArbiter.cancel(waiting))
        #expect(cancelled == 1, "its caller hears it was dismissed")
        #expect(arbiter.waitingOwners.isEmpty)
        #expect(!PaneSheetArbiter.cancel(waiting), "only once")
        #expect(!PaneSheetArbiter.cancel(UIViewController()), "a sheet that never waited is not the arbiter's")
        arbiter.sheetDidDismiss()
        #expect(presented == ["chat"])
    }

    @Test func aSheetWhosePaneLeftTheWindowIsSkipped() {
        let arbiter = PaneSheetArbiter()
        var presented: [String] = []
        arbiter.request(owner: chat, container: UIViewController(), onCancel: nil) { presented.append("chat"); return true }
        arbiter.request(owner: files, container: UIViewController(), onCancel: nil) { false }
        arbiter.request(owner: git, container: UIViewController(), onCancel: nil) { presented.append("git"); return true }
        arbiter.sheetDidDismiss()
        #expect(presented == ["chat", "git"], "the gone pane's sheet is dropped and the next one presents")
        #expect(arbiter.waitingOwners.isEmpty)
    }
}
