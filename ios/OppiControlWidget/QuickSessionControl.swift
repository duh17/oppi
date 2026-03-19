import AppIntents
import SwiftUI
import WidgetKit

/// Control widget button for starting a new Oppi session.
///
/// Can be placed in:
/// - **Action Button** (Settings > Action Button > Controls > Oppi)
/// - **Control Center** (swipe down, add control)
/// - **Lock Screen** (customize lock screen, add control)
///
/// Pressing the control opens the app and presents the Quick Session sheet
/// via `StartQuickSessionIntent`.
struct QuickSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SharedConstants.quickSessionControlKind
        ) {
            ControlWidgetButton(action: QuickSessionControlIntent()) {
                Label("New Session", systemImage: "plus.message")
            }
        }
        .displayName("New Session")
        .description("Start a new Oppi agent session.")
    }
}

/// Intent used by the ControlWidget.
///
/// Unlike `StartQuickSessionIntent` (which runs in-process with `openAppWhenRun`),
/// this intent runs in the widget extension process. It writes a flag to shared
/// UserDefaults that the main app picks up on foreground.
///
/// The system opens the app after `perform()` returns because ControlWidgetButton
/// with a non-background intent triggers app launch.
struct QuickSessionControlIntent: AppIntent {
    static let title: LocalizedStringResource = "New Session"
    static let description: IntentDescription = "Start a new Oppi agent session"
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Write to shared UserDefaults so the app knows to show the sheet.
        // The app checks this flag in handleScenePhase(.active).
        SharedConstants.sharedDefaults.set(true, forKey: SharedConstants.quickSessionPendingKey)
        return .result()
    }
}
