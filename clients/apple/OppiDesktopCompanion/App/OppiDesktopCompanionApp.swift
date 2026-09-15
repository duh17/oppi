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
        let captureSession = session
        var startedSocket: DesktopCompanionOwnerSocket?
        do {
            let socket = DesktopCompanionOwnerSocket(shareGate: shareGate)
            try socket.start()
            startedSocket = socket
            ownerSocket = socket
        } catch {
            ownerSocket = nil
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "OppiDesktopCompanion",
                category: "OwnerSocket"
            ).error("Owner socket failed to start: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                captureSession.stopLocalPreview()
                startedSocket?.stop()
            }
        }
    }

    private static var isRunningUnderTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }
}
