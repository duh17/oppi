import AppIntents
import UIKit

/// How a new session starts: in the composer, dictating, or in a Live Voice call.
///
/// Shared by Oppi's system controls (`QuickSessionOpenIntent`) and the New Session
/// shortcut (`StartQuickSessionIntent`), so a control, the Action Button, Siri, and a
/// Shortcut all name the same three starts.
enum QuickSessionMode: String, AppEnum {
    /// Raw value kept from the original single-target control.
    case message = "quickSession"
    case dictation
    case liveVoice

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .message: DisplayRepresentation(title: "Message", image: .init(systemName: "plus.message")),
        .dictation: DisplayRepresentation(title: "Dictation", image: .init(systemName: "mic")),
        .liveVoice: DisplayRepresentation(title: "Live Voice", image: .init(systemName: "waveform")),
    ]
}

/// Opens Oppi and routes the receiving scene to a new session in `target`'s mode.
///
/// Apple requires an `OpenIntent` used by a control to belong to both the main
/// app and WidgetKit extension targets. As a `UISceneAppIntent` it reaches the
/// app's UIKit scene (`SceneDelegate`), which presents Quick Session.
struct QuickSessionOpenIntent: OpenIntent, UISceneAppIntent {
    static let title: LocalizedStringResource = "New Session"
    static let description: IntentDescription = "Open Oppi to start a new agent session"

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif

    @Parameter(title: "Mode")
    var target: QuickSessionMode

    init() {
        target = .message
    }

    init(target: QuickSessionMode) {
        self.target = target
    }
}
