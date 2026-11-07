import UIKit

/// What the task controls of one reader do: toggle a checkbox, change an Org
/// state from a menu, set or clear a Scheduled or Deadline date from a picker.
///
/// A control edits the source the reader shows through `TaskSourceEdit`, which
/// rewrites only the lines the edit owns, and hands the edit to `apply`. The
/// owner of the document saves it through its own edit path, with that path's
/// conflict check, and shows the result. The reader creates this only for a
/// document its owner can save, and `isAvailable` says whether that still holds.
@MainActor
final class ReaderTaskEditing: ReaderTaskControlHandling {
    /// Saves the edit `transform` makes to the document's current text, and
    /// shows the outcome. `transform` returns nil to change nothing.
    typealias Apply = @MainActor (_ transform: @escaping (String) -> String?) async -> Void

    let dialect: TaskSourceEdit.Dialect
    private let isAvailable: @MainActor () -> Bool
    private let source: @MainActor () -> String
    private let apply: Apply
    private let calendar: Calendar
    private let now: @MainActor () -> Date
    /// An edit is being saved: controls rest until the reader shows its result,
    /// so a second edit never reads lines the first one moved.
    private(set) var isCommitting = false

    init(
        dialect: TaskSourceEdit.Dialect,
        isAvailable: @escaping @MainActor () -> Bool,
        source: @escaping @MainActor () -> String,
        calendar: Calendar = .current,
        now: @escaping @MainActor () -> Date = { Date() },
        apply: @escaping Apply
    ) {
        self.dialect = dialect
        self.isAvailable = isAvailable
        self.source = source
        self.calendar = calendar
        self.now = now
        self.apply = apply
    }

    var allowsTaskControls: Bool { isAvailable() && !isCommitting }

    func interaction(for control: ReaderTaskControl, in view: UIView) -> ReaderTaskInteraction {
        switch control.kind {
        case .checkbox:
            return .action { [weak self] in self?.toggle(line: control.line) }
        case .state:
            return .menu(stateMenu(line: control.line, in: view))
        case .date(let kind):
            return .action { [weak self, weak view] in
                guard let view else { return }
                self?.presentDatePicker(kind: kind, line: control.line, from: view)
            }
        }
    }

    // MARK: - Edits

    func toggle(line: Int) {
        let dialect = dialect
        commit { TaskSourceEdit.toggleCheckbox(in: $0, line: line, dialect: dialect) }
    }

    func setState(_ keyword: String?, line: Int) {
        let now = now()
        let calendar = calendar
        commit { text in
            let keywords = OrgParser().todoKeywords(in: text)
            return TaskSourceEdit.setState(
                in: text,
                headingLine: line,
                to: keyword,
                keywords: keywords,
                now: now,
                calendar: calendar
            )
        }
    }

    func setDate(_ value: TaskSourceEdit.OrgDateValue?, kind: OrgPlanningKind, line: Int) {
        commit { TaskSourceEdit.setPlanningDate(in: $0, headingLine: line, kind: kind, to: value) }
    }

    private func commit(_ transform: @escaping (String) -> String?) {
        guard allowsTaskControls else { return }
        isCommitting = true
        let apply = apply
        Task { @MainActor [weak self] in
            await apply(transform)
            self?.isCommitting = false
        }
    }

    // MARK: - State menu

    /// The file's states, "No state", and the dates the heading lacks. Built
    /// when the menu opens, from the text as it is then.
    private func stateMenu(line: Int, in view: UIView) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self, weak view] provide in
                MainActor.assumeIsolated { provide(self?.stateMenuElements(line: line, in: view) ?? []) }
            },
        ])
    }

    private func stateMenuElements(line: Int, in view: UIView?) -> [UIMenuElement] {
        let text = source()
        let keywords = OrgParser().todoKeywords(in: text)
        let current = TaskSourceEdit.state(in: text, headingLine: line, keywords: keywords)

        func action(_ keyword: String) -> UIAction {
            let action = UIAction(title: keyword, state: keyword == current ? .on : .off) { [weak self] _ in
                self?.setState(keyword, line: line)
            }
            action.accessibilityIdentifier = "fileViewer.task.stateMenu.\(keyword)"
            return action
        }

        var sections: [UIMenuElement] = []
        if !keywords.active.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: keywords.active.map(action)))
        }
        if !keywords.done.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: keywords.done.map(action)))
        }
        let none = UIAction(title: String(localized: "No state"), state: current == nil ? .on : .off) { [weak self] _ in
            self?.setState(nil, line: line)
        }
        none.accessibilityIdentifier = "fileViewer.task.stateMenu.none"
        sections.append(UIMenu(options: .displayInline, children: [none]))

        // A heading's dates open from their own badges; the ones it has not got
        // yet are set from here.
        struct Offer {
            let kind: OrgPlanningKind
            let title: String
            let symbol: String
            let identifier: String
        }
        let offers = [
            Offer(kind: .scheduled, title: String(localized: "Set Scheduled…"), symbol: "calendar", identifier: "fileViewer.task.stateMenu.addScheduled"),
            Offer(kind: .deadline, title: String(localized: "Set Deadline…"), symbol: "flag", identifier: "fileViewer.task.stateMenu.addDeadline"),
        ]
        let missing = offers.filter { TaskSourceEdit.planningDate(in: text, headingLine: line, kind: $0.kind) == nil }
        if !missing.isEmpty {
            let dates = missing.map { offer in
                let action = UIAction(title: offer.title, image: UIImage(systemName: offer.symbol)) { [weak self, weak view] _ in
                    guard let self, let view else { return }
                    // Let the menu finish closing before the sheet opens.
                    DispatchQueue.main.async { self.presentDatePicker(kind: offer.kind, line: line, from: view) }
                }
                action.accessibilityIdentifier = offer.identifier
                return action
            }
            sections.append(UIMenu(options: .displayInline, children: dates))
        }
        return sections
    }

    // MARK: - Date picker

    private func presentDatePicker(kind: OrgPlanningKind, line: Int, from view: UIView) {
        guard allowsTaskControls else { return }
        var responder: UIResponder? = view
        while let next = responder, !(next is UIViewController) { responder = next.next }
        guard let presenter = responder as? UIViewController else { return }
        let current = TaskSourceEdit.planningDate(in: source(), headingLine: line, kind: kind)
        let picker = OrgDatePickerViewController(
            title: kind.label,
            value: current,
            calendar: calendar,
            now: now()
        ) { [weak self] value in
            self?.setDate(value, kind: kind, line: line)
        }
        Router.present(
            picker,
            // Tall enough to show the Time switch and Clear under the calendar.
            presentation: .sheet.detents([.large()], grabber: true).inNavigation(),
            from: presenter
        )
    }
}

/// A date, with an optional time, and Clear.
final class OrgDatePickerViewController: UIViewController {
    private let value: TaskSourceEdit.OrgDateValue?
    private let calendar: Calendar
    private let onCommit: (TaskSourceEdit.OrgDateValue?) -> Void
    private let picker = UIDatePicker()
    private let timeSwitch = UISwitch()
    private let clearButton = UIButton(type: .system)

    init(
        title: String,
        value: TaskSourceEdit.OrgDateValue?,
        calendar: Calendar,
        now: Date,
        onCommit: @escaping (TaskSourceEdit.OrgDateValue?) -> Void
    ) {
        self.value = value
        self.calendar = calendar
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
        self.title = title
        picker.calendar = calendar
        picker.timeZone = calendar.timeZone
        picker.preferredDatePickerStyle = .inline
        picker.date = value.flatMap { date(from: $0) } ?? now
        let hasTime = value?.time != nil
        timeSwitch.isOn = hasTime
        picker.datePickerMode = hasTime ? .dateAndTime : .date
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = ThemeRuntimeState.currentPalette()
        view.backgroundColor = palette.ui.bgDark

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.close() }
        )
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "fileViewer.task.datePicker.cancel"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.commit() }
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "fileViewer.task.datePicker.done"

        picker.accessibilityIdentifier = "fileViewer.task.datePicker.date"
        picker.tintColor = palette.ui.blue

        let timeLabel = UILabel()
        timeLabel.text = String(localized: "Time")
        timeLabel.font = .preferredFont(forTextStyle: .body)
        timeLabel.textColor = palette.ui.fg
        timeSwitch.accessibilityIdentifier = "fileViewer.task.datePicker.time"
        timeSwitch.accessibilityLabel = String(localized: "Time")
        timeSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            picker.datePickerMode = timeSwitch.isOn ? .dateAndTime : .date
        }, for: .valueChanged)
        // Time and Clear sit above the calendar, where a short sheet still shows them.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let timeRow = UIStackView(arrangedSubviews: [timeLabel, timeSwitch, spacer, clearButton])
        timeRow.axis = .horizontal
        timeRow.alignment = .center
        timeRow.spacing = 12

        var clear = UIButton.Configuration.plain()
        clear.title = String(localized: "Clear")
        clear.baseForegroundColor = palette.ui.red
        clearButton.configuration = clear
        clearButton.accessibilityIdentifier = "fileViewer.task.datePicker.clear"
        clearButton.isHidden = value == nil
        clearButton.addAction(UIAction { [weak self] _ in self?.clear() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [timeRow, picker])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
    }

    private func date(from value: TaskSourceEdit.OrgDateValue) -> Date? {
        calendar.date(from: DateComponents(
            year: value.year,
            month: value.month,
            day: value.day,
            hour: value.time?.hour ?? 0,
            minute: value.time?.minute ?? 0
        ))
    }

    private func close() {
        Router.finish(self)
    }

    private func commit() {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: picker.date)
        let result = TaskSourceEdit.OrgDateValue(
            year: parts.year ?? 1970,
            month: parts.month ?? 1,
            day: parts.day ?? 1,
            time: timeSwitch.isOn ? (parts.hour ?? 0, parts.minute ?? 0) : nil
        )
        close()
        onCommit(result)
    }

    private func clear() {
        close()
        onCommit(nil)
    }
}
