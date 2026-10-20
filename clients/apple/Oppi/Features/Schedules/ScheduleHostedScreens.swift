import SwiftUI

/// The SwiftUI screens a schedule's UIKit detail presents: the native editor
/// and the reviewable prompt reader.
@MainActor
enum ScheduleHostedScreens {
    static func nativeEdit(
        _ schedule: AgentSchedule?,
        onSaved: @escaping (AgentSchedule, AgentScheduleSummary) -> Void
    ) -> RouterScreen {
        .hosted {
            guard let schedule else { return AnyView(EmptyView()) }
            return AnyView(ScheduleNativeEditView(schedule: schedule, onSaved: onSaved))
        }
    }

    static func promptReader(_ schedule: AgentSchedule?) -> RouterScreen {
        .hosted {
            guard let schedule else { return AnyView(EmptyView()) }
            return AnyView(ReviewableControlMarkdownView(
                content: SchedulePresentation.prompt(in: schedule.action),
                domain: .schedules,
                targetId: schedule.id,
                targetName: schedule.name,
                sourceLabel: "\(schedule.name) prompt",
                sourcePath: "Schedules/\(schedule.id)/Prompt.md"
            ))
        }
    }
}
