import SwiftUI

@main
struct OppiDesktopCompanionApp: App {
    @State private var session = DesktopCaptureSession(
        service: ScreenCaptureKitDesktopCaptureService()
    )

    var body: some Scene {
        Window("Oppi Desktop Companion", id: "main") {
            DesktopCaptureView(session: session)
        }
        .commands {
            DesktopCaptureCommands(session: session)
        }
    }
}
