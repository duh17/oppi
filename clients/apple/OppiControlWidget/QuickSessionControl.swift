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
/// via `QuickSessionOpenIntent`.
struct QuickSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SharedConstants.quickSessionControlKind
        ) {
            ControlWidgetButton(action: QuickSessionOpenIntent()) {
                Label("New Session", systemImage: "plus.message")
            }
        }
        .displayName("New Session")
        .description("Start a new Pi session in Oppi.")
    }
}
