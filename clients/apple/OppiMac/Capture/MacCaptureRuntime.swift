import AppKit
import OSLog

/// In-process ScreenCaptureKit + owner-socket still fetch.
/// Screen Recording TCC belongs to Oppi (`dev.chenda.OppiMac`), not a companion app.
@MainActor
final class MacCaptureRuntime {
    static let windowID = "capture"

    let session: DesktopCaptureSession
    private let ownerSocket: DesktopCompanionOwnerSocket?

    init() {
        let shareGate = DesktopStillShareGate()
        let viewGrantGate = DesktopViewGrantGate()
        session = DesktopCaptureSession(
            service: ScreenCaptureKitDesktopCaptureService(),
            shareGate: shareGate,
            viewGrantGate: viewGrantGate
        )
        guard !Self.isRunningUnderTests else {
            ownerSocket = nil
            return
        }
        let captureSession = session
        var startedSocket: DesktopCompanionOwnerSocket?
        do {
            let socket = DesktopCompanionOwnerSocket(
                shareGate: shareGate,
                viewGrantGate: viewGrantGate
            )
            try socket.start()
            startedSocket = socket
            ownerSocket = socket
        } catch {
            ownerSocket = nil
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "dev.chenda.OppiMac",
                category: "OwnerSocket"
            ).error("Owner socket failed to start: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                captureSession.prepareForTermination()
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
