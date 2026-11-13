import UIKit

/// What a calendar event does, the same from the Day agenda, the Week grid, and Month's
/// agenda: a tap, the long-press menu, and VoiceOver's custom action all offer Schedule
/// Agent…, the schedule editor for a new one-time schedule at the event's time with its
/// details as the prompt's context. Nothing else: Oppi does not edit the calendar.
extension ScheduleCalendarActions {
    /// Presents Schedule Agent for `event`; a saved schedule reloads the calendar.
    func scheduleAgent(for event: ScheduleCalendarEvent) {
        guard let presenter else { return }
        let editor = ScheduleNativeEditViewController(
            event: event,
            apiClient: connection.apiClient,
            connection: connection,
            serverName: root.windowServerName
        ) { [weak self] _, _ in
            self?.model.reload()
            self?.reportError(nil)
            self?.onScheduleCreated?()
        }
        Router.present(editor, presentation: .sheet.inNavigation(), from: presenter)
    }

    /// The menu for `event`, identified by its id so tapping the preview finds it again.
    func eventMenu(for event: ScheduleCalendarEvent, width: CGFloat) -> UIContextMenuConfiguration {
        let preview = ScheduleCalendarEventViews.preview(
            event, calendar: model.calendar, palette: root.themeStore.activeThemeID.palette, width: width
        )
        let menu: UIContextMenuActionProvider = { [weak self] _ in
            let action = UIAction(title: Self.scheduleAgentTitle, image: UIImage(systemName: "calendar.badge.plus")) { _ in
                self?.scheduleAgent(for: event)
            }
            action.accessibilityIdentifier = "schedules.calendar.menu.scheduleAgent"
            return UIMenu(children: [action])
        }
        return UIContextMenuConfiguration(identifier: event.id as NSString, previewProvider: { preview }, actionProvider: menu)
    }

    func eventAccessibilityActions(for event: ScheduleCalendarEvent) -> [UIAccessibilityCustomAction] {
        [UIAccessibilityCustomAction(name: Self.scheduleAgentTitle) { [weak self] _ in
            self?.scheduleAgent(for: event)
            return true
        }]
    }

    static let scheduleAgentTitle = String(localized: "Schedule Agent…")
}
