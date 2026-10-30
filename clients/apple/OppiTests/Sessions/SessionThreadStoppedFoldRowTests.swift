import Testing
import UIKit
@testable import Oppi

/// The "N Stopped" row of an open thread, drawn by the real session list: one button whose touch and
/// accessibility activation reach the same owner action, with a stable scoped identifier and an
/// Expanded/Collapsed value that a reused cell does not carry over.
@MainActor
@Suite("Stopped fold row")
struct SessionThreadStoppedFoldRowTests {
    private func makeList(
        toggled: @escaping (SessionThreadStoppedFold) -> Void,
        opened: @escaping (Session) -> Void = { _ in }
    ) -> (list: SessionListCollection<Int, Int, Int, Int>, window: UIWindow) {
        let actions = SessionListRowActions(
            open: opened,
            toggleThread: { _ in },
            toggleStoppedMembers: toggled,
            stop: { _ in },
            resume: { _ in },
            delete: { _ in nil },
            lockTarget: { _ in nil }
        )
        let list = SessionListCollection<Int, Int, Int, Int>(
            root: makeTestAppRoot(),
            appearance: .plain,
            actions: actions,
            iconAssetCache: { nil },
            configureRow: { _, _ in },
            onToggle: { _ in }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 800))
        let controller = UIViewController()
        list.collectionView.frame = window.bounds
        controller.view.addSubview(list.collectionView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (list, window)
    }

    private func apply(
        _ folds: [SessionThreadStoppedFold],
        to list: SessionListCollection<Int, Int, Int, Int>,
        in window: UIWindow
    ) {
        var snapshot = SessionListCollection<Int, Int, Int, Int>.Snapshot()
        snapshot.appendSection(0)
        for (index, fold) in folds.enumerated() {
            let entry = SessionListEntry(
                session: Session(
                    id: fold.rootId, workspaceId: "w", name: fold.rootId, status: .ready,
                    createdAt: Date(timeIntervalSince1970: 0), lastActivity: Date(timeIntervalSince1970: 1),
                    messageCount: 0, tokens: TokenUsage(input: 0, output: 0), cost: 0
                ),
                thread: nil, outsideRoot: nil, depth: 1, stoppedFold: fold
            )
            snapshot.append(sessions: [entry], to: 0, item: { _ in index }) { _ in nil }
        }
        list.apply(snapshot)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        list.collectionView.layoutIfNeeded()
    }

    private func control(at item: Int, in list: SessionListCollection<Int, Int, Int, Int>) throws
        -> SessionThreadStoppedFoldControl {
        let cell = try #require(list.collectionView.cellForItem(at: IndexPath(item: item, section: 0)))
        return try #require(cell.firstSubview(ofType: SessionThreadStoppedFoldControl.self))
    }

    @Test func touchAndAccessibilityActivationRunTheSameOwnerAction() throws {
        var toggled: [SessionThreadStoppedFold] = []
        var opened: [String] = []
        let (list, window) = makeList(toggled: { toggled.append($0) }, opened: { opened.append($0.id) })
        let fold = SessionThreadStoppedFold(rootId: "root-a", count: 3, isOpen: false)
        apply([fold], to: list, in: window)

        let button = try control(at: 0, in: list)
        #expect(button.accessibilityIdentifier == "thread.stopped.root-a")
        #expect(button.accessibilityLabel == "3 Stopped")
        #expect(button.accessibilityValue == "Collapsed")
        #expect(button.accessibilityTraits.contains(.button))
        #expect(button.isAccessibilityElement)

        button.sendActions(for: .touchUpInside)
        #expect(button.accessibilityActivate())
        #expect(toggled == [fold, fold], "A touch and VoiceOver activation both reach the owner action")

        // The list never selects the row, so a tap cannot also open the root's chat.
        let indexPath = IndexPath(item: 0, section: 0)
        #expect(list.collectionView.delegate?.collectionView?(list.collectionView, shouldHighlightItemAt: indexPath) == false)
        #expect(opened.isEmpty)
    }

    @Test func aReusedCellTakesTheNewFoldsIdentityValueAndAction() throws {
        var toggled: [SessionThreadStoppedFold] = []
        let (list, window) = makeList(toggled: { toggled.append($0) })
        apply([SessionThreadStoppedFold(rootId: "root-a", count: 3, isOpen: false)], to: list, in: window)
        let before = try control(at: 0, in: list)
        #expect(before.accessibilityValue == "Collapsed")

        // The same item now stands for another thread's open fold.
        let next = SessionThreadStoppedFold(rootId: "root-b", count: 8, isOpen: true)
        apply([next], to: list, in: window)

        let after = try control(at: 0, in: list)
        #expect(after.accessibilityIdentifier == "thread.stopped.root-b")
        #expect(after.accessibilityLabel == "8 Stopped")
        #expect(after.accessibilityValue == "Expanded")
        #expect(after.accessibilityActivate())
        #expect(toggled == [next], "Activation acts on what the row shows now, not on its first thread")
    }
}

private extension UIView {
    func firstSubview<T: UIView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstSubview(ofType: type) { return match }
        }
        return nil
    }
}
