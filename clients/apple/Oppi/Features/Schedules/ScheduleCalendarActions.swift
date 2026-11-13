import UIKit

/// What a calendar entry does, the same from the Day agenda, the Week grid, and Month's
/// agenda: a tap opens the run's session (or, for an occurrence still to come, its
/// schedule); a long press offers Open Session, Run Now, Pause Schedule, Show Schedule, and
/// Last Run's Session, with a preview of the schedule's recent runs; VoiceOver offers the
/// same as custom actions. Only what the server can do is offered: an unavailable action is
/// left out, never dimmed (HIG Context menus).
///
/// One per calendar view, bound to the container's model and connection.
@MainActor
final class ScheduleCalendarActions {
    struct MenuAction {
        let title: String
        let symbol: String
        let identifier: String
        let perform: () -> Void
    }

    let root: AppRootEnvironment
    let connection: ServerConnection
    let model: ScheduleCalendarModel
    /// A change the person asked for failed; the container's composer says why.
    let reportError: (String?) -> Void
    let openSchedule: (String) -> Void
    /// Schedule Agent… saved a new schedule (`ScheduleCalendarActions+Events`).
    var onScheduleCreated: (() -> Void)?
    /// The screen consent prompts present from.
    weak var presenter: UIViewController?

    init(
        root: AppRootEnvironment,
        connection: ServerConnection,
        model: ScheduleCalendarModel,
        reportError: @escaping (String?) -> Void,
        openSchedule: @escaping (String) -> Void
    ) {
        self.root = root
        self.connection = connection
        self.model = model
        self.reportError = reportError
        self.openSchedule = openSchedule
    }

    /// A tap: a run with a session opens it; anything else opens its schedule.
    func open(_ item: ScheduleCalendarAgenda.Item) {
        if item.sessionId != nil {
            openSession(of: item)
        } else {
            openSchedule(item.scheduleId)
        }
    }

    func openSession(of item: ScheduleCalendarAgenda.Item) {
        guard let sessionId = item.sessionId,
              let serverId = connection.workspaceStore.activeServerId else { return }
        root.navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId, workspaceId: item.workspaceId)
        )
    }

    /// All Sessions with the run's thread open. A run's session is its thread's root: a
    /// schedule launches it with no parent.
    func openThread(of item: ScheduleCalendarAgenda.Item) {
        guard let sessionId = item.sessionId,
              let serverId = connection.workspaceStore.activeServerId else { return }
        root.navigation.showThread(serverId: serverId, rootId: sessionId)
    }

    /// The long-press menu, and VoiceOver's custom actions, from the agenda as it is now: a
    /// schedule paused since the row was drawn offers no Pause.
    func menuActions(for item: ScheduleCalendarAgenda.Item, agenda: ScheduleCalendarAgenda?) -> [MenuAction] {
        let schedule = agenda?.schedules[item.scheduleId]
        let scheduleId = item.scheduleId
        var actions: [MenuAction] = []
        if item.sessionId != nil {
            actions.append(MenuAction(title: String(localized: "Open Session"), symbol: "bubble.left", identifier: "openSession") { [weak self] in
                self?.openSession(of: item)
            })
        }
        if schedule?.status != .archived {
            actions.append(MenuAction(title: String(localized: "Run Now"), symbol: "play.fill", identifier: "runNow") { [weak self] in
                self?.runNow(scheduleId, modelId: schedule?.model)
            })
        }
        if schedule?.status == .active {
            actions.append(MenuAction(title: String(localized: "Pause Schedule"), symbol: "pause.fill", identifier: "pause") { [weak self] in
                self?.pause(scheduleId)
            })
        }
        actions.append(MenuAction(title: String(localized: "Show Schedule"), symbol: "info.circle", identifier: "showSchedule") { [weak self] in
            self?.openSchedule(scheduleId)
        })
        if item.sessionId == nil, let last = agenda?.lastSession(of: scheduleId, before: model.now) {
            actions.append(MenuAction(title: String(localized: "Last Run's Session"), symbol: "bubble.left", identifier: "lastSession") { [weak self] in
                self?.openSession(of: last)
            })
        }
        return actions
    }

    func accessibilityActions(for item: ScheduleCalendarAgenda.Item, agenda: ScheduleCalendarAgenda?) -> [UIAccessibilityCustomAction] {
        menuActions(for: item, agenda: agenda).map { action in
            UIAccessibilityCustomAction(name: action.title) { _ in
                action.perform()
                return true
            }
        }
    }

    /// The menu for `item`, identified by its id so tapping the preview can find it again.
    func contextMenu(
        for item: ScheduleCalendarAgenda.Item,
        agenda: @escaping () -> ScheduleCalendarAgenda?,
        badge: ScheduleRowBadge?,
        width: CGFloat
    ) -> UIContextMenuConfiguration {
        let preview = previewController(for: item, agenda: agenda(), badge: badge, width: width)
        let menu: UIContextMenuActionProvider = { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: menuActions(for: item, agenda: agenda()).map { action in
                let element = UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { _ in action.perform() }
                element.accessibilityIdentifier = "schedules.calendar.menu.\(action.identifier)"
                return element
            })
        }
        return UIContextMenuConfiguration(identifier: item.id as NSString, previewProvider: { preview }, actionProvider: menu)
    }

    /// The menu's preview: timing, Agent or workspace and model, the last seven outcomes, and
    /// the average cost.
    private func previewController(
        for item: ScheduleCalendarAgenda.Item,
        agenda: ScheduleCalendarAgenda?,
        badge: ScheduleRowBadge?,
        width: CGFloat
    ) -> UIViewController {
        let palette = root.themeStore.activeThemeID.palette
        let now = model.now
        let schedule = agenda?.schedules[item.scheduleId]
        let recent = agenda?.recentOutcomes(of: item.scheduleId, before: now) ?? []
        let costs = agenda?.items.filter { $0.scheduleId == item.scheduleId && $0.outcome.isPast }.compactMap(\.cost) ?? []
        let controller = UIViewController()
        controller.view.backgroundColor = palette.ui.bgDark

        let title = ControlRowViews.label(item.name, style: .headline, color: palette.ui.fg)
        var head: [UIView] = [title, ControlRowViews.spacer()]
        if item.outcome == .upcoming {
            let countdown = ControlRowViews.label(
                ScheduleCalendarText.countdown(to: item.at, now: now, calendar: model.calendar),
                style: .subheadline, weight: .semibold, color: palette.ui.blue, lines: 1
            )
            countdown.setContentHuggingPriority(.required, for: .horizontal)
            head.append(countdown)
        }
        // Each line is one line, truncating, so the preview's height is the same at any
        // width: an iPad shows it narrower than it was measured, and wrapped text ran
        // under the outcomes.
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var lines: [UIView] = [ControlRowViews.stack(head, axis: .horizontal, spacing: 8, alignment: .firstBaseline)]
        var place: [String] = []
        if let badge { place.append(badge.name) }
        if let model = schedule?.model ?? item.model { place.append(ScheduleCalendarRowViews.modelName(model)) }
        for detail in [schedule?.trigger.scheduleScreenTiming(), place.isEmpty ? nil : place.joined(separator: " · ")] {
            guard let detail else { continue }
            let label = ControlRowViews.label(detail, style: .subheadline, color: palette.ui.fgDim, lines: 1)
            label.lineBreakMode = .byTruncatingTail
            lines.append(label)
        }
        if !recent.isEmpty {
            let glyphs = recent.map { ScheduleCalendarRowViews.glyph(.init($0, palette: palette), palette: palette, textStyle: .subheadline) }
            let caption = ControlRowViews.label(String(localized: "Last \(recent.count) runs"), style: .footnote, color: palette.ui.fgDim, lines: 1)
            caption.setContentCompressionResistancePriority(.required, for: .horizontal)
            var row: [UIView] = [caption]
            row += glyphs
            row.append(ControlRowViews.spacer())
            if !costs.isEmpty {
                row.append(ControlRowViews.label(
                    String(localized: "avg \(SessionFormatting.costString(costs.reduce(0, +) / Double(costs.count)))"),
                    style: .footnote, color: palette.ui.fgDim, lines: 1
                ))
            }
            lines.append(ControlRowViews.stack(row, axis: .horizontal, spacing: 4, alignment: .center))
        }
        let stack = ControlRowViews.stack(lines, spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -14),
        ])
        // Narrow enough to sit beside its menu on an iPad mini: a wider preview is shrunk
        // to fit, height with it, and a line is squeezed out.
        let width = min(width - 32, 340)
        let height = controller.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        controller.preferredContentSize = CGSize(width: width, height: height)
        return controller
    }

    /// The detail page's Run Now: consent, then one run; Starting shows at now meanwhile.
    private func runNow(_ scheduleId: String, modelId: String?) {
        guard let apiClient = connection.apiClient else { return }
        let connection = connection
        let model = model
        Task { [weak self] in
            var starting: String?
            do {
                _ = try await ScheduleRunNow.run(
                    scheduleId,
                    modelId: modelId,
                    apiClient: apiClient,
                    connection: connection,
                    from: self?.presenter
                ) {
                    starting = model.insertStarting(scheduleId: scheduleId)
                }
                guard let starting else { return }
                model.startingAccepted(starting)
                self?.reportError(nil)
            } catch {
                if let starting { model.removeStarting(starting) }
                self?.reportError(error.localizedDescription)
            }
        }
    }

    /// Its future runs leave once the server has paused it, not before.
    private func pause(_ scheduleId: String) {
        guard let apiClient = connection.apiClient else { return }
        Task { [weak self] in
            do {
                _ = try await apiClient.pauseAgentSchedule(scheduleId)
                self?.model.reload()
                self?.reportError(nil)
            } catch {
                self?.reportError(error.localizedDescription)
            }
        }
    }
}
