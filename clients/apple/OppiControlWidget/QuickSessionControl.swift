import AppIntents
import SwiftUI
import WidgetKit

/// Control widget buttons that start a new Oppi session.
///
/// Each can be placed in:
/// - **Action Button** (Settings > Action Button > Controls > Oppi)
/// - **Control Center** (swipe down, add control)
/// - **Lock Screen** (customize lock screen, add control)
///
/// Pressing one opens the app and presents Quick Session in the control's mode via
/// `QuickSessionOpenIntent`. A Shortcut with the New Session action picks the Agent and
/// workspace too.
struct QuickSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SharedConstants.quickSessionControlKind
        ) {
            ControlWidgetButton(action: QuickSessionOpenIntent(target: .message)) {
                Label("New Session", systemImage: "plus.message")
            }
        }
        .displayName("New Session")
        .description("Start a new Pi session in Oppi.")
    }
}

/// One press opens a new session straight into a Live Voice call.
struct LiveVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SharedConstants.liveVoiceControlKind
        ) {
            ControlWidgetButton(action: QuickSessionOpenIntent(target: .liveVoice)) {
                Label("Live Voice", systemImage: "waveform")
            }
        }
        .displayName("Live Voice")
        .description("Start a new Pi session in a Live Voice call.")
    }
}
