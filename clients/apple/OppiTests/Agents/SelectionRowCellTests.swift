import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Selection row")
struct SelectionRowCellTests {
    @Test("a selection row re-measures when the text size changes live, and none of its text is cut off")
    func selectionRowsGrowWithTheTextSize() async throws {
        let page = SelectionRowsPage()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 3000)
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        page.traitOverrides.preferredContentSizeCategory = .large

        let rows = SelectionRowsPage.Row.allCases
        func heights() async -> [SelectionRowsPage.Row: CGFloat]? {
            for _ in 0..<150 {
                page.view.layoutIfNeeded()
                let cells = rows.compactMap { row in
                    page.dataSource?.indexPath(for: row).flatMap { page.collectionView.cellForItem(at: $0) }.map { (row, $0.bounds.height) }
                }
                if cells.count == rows.count { return Dictionary(uniqueKeysWithValues: cells) }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
        let before = try #require(await heights())

        page.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        var after = before
        for _ in 0..<150 {
            page.view.layoutIfNeeded()
            after = (await heights()) ?? before
            if rows.allSatisfy({ (after[$0] ?? 0) > (before[$0] ?? .greatestFiniteMagnitude) }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        for row in rows {
            #expect((after[row] ?? 0) > (before[row] ?? .greatestFiniteMagnitude), "\(row) did not grow: \(before[row] ?? 0) -> \(after[row] ?? 0)")
        }

        page.view.layoutIfNeeded()
        for row in rows {
            guard let indexPath = page.dataSource?.indexPath(for: row), let cell = page.collectionView.cellForItem(at: indexPath) else {
                Issue.record("\(row) has no cell")
                continue
            }
            var checked = 0
            for label in Self.labels(in: cell) where !(label.text ?? "").isEmpty && !label.isHidden && label.bounds.width > 0 {
                checked += 1
                let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                #expect(needed.height <= label.bounds.height + 1, "\(row): \"\(label.text ?? "")\" is clipped (\(needed.height) > \(label.bounds.height))")
            }
            #expect(checked >= 1, "\(row): no label was checked")
        }
    }

    @Test("a chosen row says so and a row nobody can choose is dimmed and disabled")
    func chosenAndDisabledRows() async throws {
        let page = SelectionRowsPage()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 3000)
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        func button(_ identifier: String) -> UIButton? {
            page.view.layoutIfNeeded()
            return page.collectionView.visibleCells.lazy.compactMap { Self.button(identifier, in: $0) }.first
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { button("test.selection.chosen") != nil })
        let chosen = try #require(button("test.selection.chosen"))
        #expect(chosen.accessibilityTraits.contains(.selected))
        #expect(chosen.accessibilityLabel == "Read files")
        #expect(chosen.accessibilityValue == "Selected")

        let blocked = try #require(button("test.selection.blocked"))
        #expect(!blocked.isEnabled)
        #expect(blocked.accessibilityTraits.contains(.notEnabled))
        #expect(!blocked.accessibilityTraits.contains(.selected))
    }

    private static func labels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for subview in view.subviews { found += labels(in: subview) }
        return found
    }

    private static func button(_ identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        for subview in view.subviews {
            if let found = button(identifier, in: subview) { return found }
        }
        return nil
    }
}

/// One of each selection row, with text long enough to wrap at the largest sizes.
private final class SelectionRowsPage: SettingsListViewController<SelectionRowsPage.Section, SelectionRowsPage.Row> {
    enum Section: Hashable, Sendable { case rows }
    enum Row: CaseIterable, Hashable, Sendable { case chosen, blocked, check }

    init() {
        super.init(title: "Selection", listIdentifier: "test.selection.list", scope: .device)
    }

    override func sections() -> [SettingsSectionModel<Section, Row>] {
        [SettingsSectionModel(.rows, items: Row.allCases)]
    }

    private lazy var row = UICollectionView.CellRegistration<SelectionRowCell, Row> { cell, _, row in
        switch row {
        case .chosen:
            cell.configure(
                title: "Read files",
                subtitle: "Reads a file from the workspace, with offsets for large files and images.",
                isChosen: true,
                value: "Selected",
                identifier: "test.selection.chosen"
            ) {}
        case .blocked:
            cell.configure(
                title: "a-saved-tool-the-server-no-longer-lists",
                subtitle: "Not resolved by the server-global catalog",
                status: "Unavailable",
                isChosen: false,
                isEnabled: false,
                value: "Not selected, Unavailable",
                identifier: "test.selection.blocked"
            ) {}
        case .check:
            cell.configure(
                title: "America/Argentina/ComodRivadavia and some more words",
                mark: .trailingCheck,
                isChosen: true,
                identifier: "test.selection.check"
            ) {}
        }
    }

    override func prepareRegistrations() {
        _ = row
    }

    override func dequeue(_ item: Row, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
    }
}
