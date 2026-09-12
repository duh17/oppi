import AppKit
import OSLog
import SwiftUI

@main
struct OppiDesktopCompanionApp: App {
    @State private var runtime = CompanionRuntime()

    var body: some Scene {
        Window("Oppi Desktop Companion", id: "main") {
            DesktopCaptureView(session: runtime.session)
        }
        .commands {
            DesktopCaptureCommands(session: runtime.session)
        }
    }
}

@MainActor
private final class CompanionRuntime {
    let session: DesktopCaptureSession
    private let ownerSocket: DesktopCompanionOwnerSocket?

    init() {
        let shareGate = DesktopStillShareGate()
        session = DesktopCaptureSession(
            service: ScreenCaptureKitDesktopCaptureService(),
            shareGate: shareGate
        )
        guard !Self.isRunningUnderTests else {
            ownerSocket = nil
            return
        }
        let socket = DesktopCompanionOwnerSocket(shareGate: shareGate)
        do {
            try socket.start()
            ownerSocket = socket
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                socket.stop()
            }
        } catch {
            ownerSocket = nil
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "OppiDesktopCompanion",
                category: "OwnerSocket"
            ).error("Owner socket failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var isRunningUnderTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }
}
