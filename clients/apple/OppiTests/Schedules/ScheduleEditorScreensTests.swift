import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Edit Schedule screens")
struct ScheduleEditorScreensTests {
    private func makeSchedule(
        trigger: AgentScheduleTrigger = .every(intervalMs: 3_600_000, timeZone: "America/Los_Angeles")
    ) -> AgentSchedule {
        AgentSchedule(
            id: "schedule-editor-tests",
            name: "Nightly digest",
            status: .active,
            trigger: trigger,
            action: .newSession(
                workspaceId: "ws-1", prompt: "Summarize the day.", agentId: nil, model: nil,
                thinkingLevel: nil, worktreeId: nil, name: nil
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            archivedAt: nil
        )
    }

    private func makeEditor(schedule: AgentSchedule? = nil) -> ScheduleNativeEditViewController {
        ScheduleNativeEditViewController(
            schedule: schedule ?? makeSchedule(),
            apiClient: nil,
            connection: ServerConnection(),
            serverName: "mac-studio"
        ) { _, _ in }
    }

    @Test("the cadence decides which trigger rows show, and a cron expression the server would refuse blocks Save")
    func cadenceRowsAndCronValidation() async throws {
        let screen = try ScheduleScreen(makeEditor())
        defer { screen.hide() }
        #expect(await screen.waitFor { screen.root.navigationItem.rightBarButtonItem != nil })
        let save = try #require(screen.root.navigationItem.rightBarButtonItem)
        #expect(await screen.waitFor { save.isEnabled })

        // Every hour: a Repeat menu, no time.
        #expect(await screen.waitForButton("schedule.nativeEdit.interval") != nil)
        #expect(screen.datePicker("schedule.nativeEdit.time") == nil)

        let cadence = try #require(await screen.waitForButton("schedule.nativeEdit.cadence"))
        #expect(cadence.accessibilityValue == "Interval")
        try ScheduleScreen.choose("Weekly", in: cadence)
        #expect(await screen.waitFor {
            screen.button("schedule.nativeEdit.weekday") != nil && screen.datePicker("schedule.nativeEdit.time") != nil
        })
        #expect(screen.button("schedule.nativeEdit.interval") == nil)

        try ScheduleScreen.choose("Custom", in: cadence)
        let field = try #require(await screen.waitForField("schedule.nativeEdit.cronExpression"))
        // A seeded hourly interval has no expression yet, so the field starts empty and invalid.
        #expect(await screen.waitFor { !save.isEnabled })
        #expect(screen.cronError() == "Enter 5 fields, or 6 with seconds first.")
        field.text = "61 * * * *"
        field.sendActions(for: .editingChanged)
        #expect(await screen.waitFor { screen.cronError() == "Use valid numbers, *, lists, ranges, or / steps for each field." })
        #expect(!save.isEnabled)
        field.text = "0 9 * * 1-5"
        field.sendActions(for: .editingChanged)
        #expect(await screen.waitFor { save.isEnabled && screen.cronError() == nil })
    }

    @Test("a time chosen on the date row reaches the draft in the trigger's own time zone")
    func timeRowFollowsTheTimeZone() async throws {
        let editor = makeEditor(schedule: makeSchedule(trigger: .cron(expression: "30 9 * * *", timeZone: "Asia/Tokyo")))
        let screen = try ScheduleScreen(editor)
        defer { screen.hide() }
        let picker = try #require(await screen.waitForDatePicker("schedule.nativeEdit.time"))
        #expect(picker.timeZone == TimeZone(identifier: "Asia/Tokyo"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: picker.date)
        #expect(parts.hour == 9 && parts.minute == 30, "a daily 09:30 schedule shows 09:30 in its own zone")
    }

    @Test("the time zone list filters by the search text and reports the choice")
    func timeZoneListFiltersAndChooses() async throws {
        let chosen = Chosen()
        let picker = ScheduleTimeZonePickerViewController(selection: "America/Los_Angeles", serverName: "mac-studio") {
            chosen.zone = $0
        }
        let screen = try ScheduleScreen(picker, modal: true)
        defer { screen.hide() }

        let search = try #require(picker.navigationItem.searchController)
        search.searchBar.text = "los angeles"
        search.searchResultsUpdater?.updateSearchResults(for: search)
        let current = try #require(await screen.waitForButton("schedule.timeZone.America/Los_Angeles"))
        #expect(current.accessibilityTraits.contains(.selected), "the saved zone is marked")

        search.searchBar.text = "new york"
        search.searchResultsUpdater?.updateSearchResults(for: search)
        #expect(await screen.waitFor {
            screen.button("schedule.timeZone.America/New_York") != nil
                && screen.button("schedule.timeZone.Asia/Tokyo") == nil
        })
        let newYork = try #require(screen.button("schedule.timeZone.America/New_York"))
        #expect(newYork.accessibilityLabel == "America/New York")
        #expect(newYork.accessibilityTraits.contains(.selected) == false)

        newYork.sendActions(for: .touchUpInside)
        #expect(chosen.zone == "America/New_York", "choosing a zone reports its identifier, not its label")
    }
}

// MARK: - Cells at the largest text sizes

@MainActor
@Suite("Schedule editor rows")
struct ScheduleEditorRowsTests {
    @Test("the date row and the cron row re-measure when the text size changes live, and none of their text is cut off")
    func rowsGrowWithTheTextSize() async throws {
        let page = ScheduleRowsPage()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 3000)
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        page.traitOverrides.preferredContentSizeCategory = .large

        let rows = ScheduleRowsPage.Row.allCases
        func heights() async -> [ScheduleRowsPage.Row: CGFloat]? {
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

    private static func labels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for subview in view.subviews { found += labels(in: subview) }
        return found
    }
}

private final class ScheduleRowsPage: SettingsListViewController<ScheduleRowsPage.Section, ScheduleRowsPage.Row> {
    enum Section: Hashable, Sendable { case rows }
    enum Row: CaseIterable, Hashable, Sendable { case date, cron }

    init() {
        super.init(title: "Rows", listIdentifier: "test.schedule.rows", scope: .device)
    }

    override func sections() -> [SettingsSectionModel<Section, Row>] {
        [SettingsSectionModel(.rows, items: Row.allCases)]
    }

    private lazy var dateRow = UICollectionView.CellRegistration<ScheduleDateRowCell, Row> { cell, _, _ in
        cell.configure(
            title: "Run At", mode: .dateAndTime, date: Date(timeIntervalSince1970: 1_800_000_000),
            timeZone: TimeZone(identifier: "America/Los_Angeles") ?? .current, identifier: "test.date"
        ) { _ in }
    }
    private lazy var cronRow = UICollectionView.CellRegistration<ScheduleCronRowCell, Row> { cell, _, _ in
        cell.configure(
            expression: "61 * * * *",
            fieldLabels: "minute  hour  day  month  weekday",
            hint: "Minute, hour, day, month, and weekday",
            error: "Use valid numbers, *, lists, ranges, or / steps for each field.",
            guidance: "Example: 0 9 * * 1-5 runs weekdays at 9:00.",
            identifier: "test.cron"
        ) { _ in }
    }

    override func prepareRegistrations() {
        _ = (dateRow, cronRow)
    }

    override func dequeue(_ item: Row, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .date: collectionView.dequeueConfiguredReusableCell(using: dateRow, for: indexPath, item: item)
        case .cron: collectionView.dequeueConfiguredReusableCell(using: cronRow, for: indexPath, item: item)
        }
    }
}

// MARK: - Harness

private final class Chosen {
    var zone: String?
}

@MainActor
private final class ScheduleScreen {
    let window: UIWindow
    let navigation: UINavigationController
    let root: UIViewController

    /// `modal` presents `root` the way the router presents a sheet, so it can finish itself.
    init(_ root: UIViewController, modal: Bool = false) throws {
        self.root = root
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 2600)
        if modal {
            navigation = RouterNavigationController(rootViewController: root)
            let presenter = UIViewController()
            window.rootViewController = presenter
            window.makeKeyAndVisible()
            presenter.present(navigation, animated: false)
        } else {
            navigation = UINavigationController(rootViewController: root)
            window.rootViewController = navigation
            window.makeKeyAndVisible()
        }
    }

    func hide() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func waitFor(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) {
            self.window.layoutIfNeeded()
            return predicate()
        }
    }

    func waitForButton(_ identifier: String) async -> UIButton? {
        _ = await waitFor { self.button(identifier) != nil }
        return button(identifier)
    }

    func waitForField(_ identifier: String) async -> UITextField? {
        _ = await waitFor { self.views(of: UITextField.self).contains { $0.accessibilityIdentifier == identifier } }
        return views(of: UITextField.self).first { $0.accessibilityIdentifier == identifier }
    }

    func waitForDatePicker(_ identifier: String) async -> UIDatePicker? {
        _ = await waitFor { self.datePicker(identifier) != nil }
        return datePicker(identifier)
    }

    func button(_ identifier: String) -> UIButton? {
        views(of: UIButton.self).first { $0.accessibilityIdentifier == identifier }
    }

    func datePicker(_ identifier: String) -> UIDatePicker? {
        views(of: UIDatePicker.self).first { $0.accessibilityIdentifier == identifier }
    }

    /// The cron error line, nil when the row shows its example instead.
    func cronError() -> String? {
        views(of: UILabel.self).first { $0.accessibilityIdentifier == "schedule.nativeEdit.cronError" }?.text
    }

    func views<T: UIView>(of type: T.Type) -> [T] {
        guard let list = navigation.topViewController?.view.firstSubview(of: UICollectionView.self) else { return [] }
        return list.visibleCells.flatMap { $0.allSubviews(of: type) }
    }

    static func choose(_ title: String, in button: UIButton) throws {
        let menu = try #require(button.menu, "the button has no menu")
        let action = try #require(menu.children.compactMap { $0 as? UIAction }.first { $0.title == title }, "no menu item \(title)")
        action.performWithSender(nil, target: nil)
    }
}

private extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let found = subview.firstSubview(of: type) { return found }
        }
        return nil
    }

    func allSubviews<T: UIView>(of type: T.Type) -> [T] {
        var found = (self as? T).map { [$0] } ?? []
        for subview in subviews { found += subview.allSubviews(of: type) }
        return found
    }
}
