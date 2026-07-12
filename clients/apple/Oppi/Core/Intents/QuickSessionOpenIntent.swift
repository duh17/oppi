import AppIntents

/// Destination opened from Oppi's system control.
enum QuickSessionOpenTarget: String, AppEnum {
    case quickSession

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Oppi Screen"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .quickSession: "New Session",
    ]
}

/// Opens Oppi and routes the receiving scene to the Quick Session composer.
///
/// Apple requires an `OpenIntent` used by a control to belong to both the main
/// app and WidgetKit extension targets. `TargetContentProvidingIntent` lets the
/// app receive the resolved target with SwiftUI's `onAppIntentExecution`.
struct QuickSessionOpenIntent: OpenIntent, TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "New Session"
    static let description: IntentDescription = "Open Oppi to start a new agent session"

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif

    @Parameter(title: "Target")
    var target: QuickSessionOpenTarget

    init() {
        target = .quickSession
    }
}
