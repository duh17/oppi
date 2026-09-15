import Foundation
import Testing
@testable import Oppi

@Suite("Mac capture fold")
struct MacCaptureFoldTests {
    @Test func screenRecordingIdentityIsOppiMac() {
        #expect(Bundle.main.bundleIdentifier == "dev.chenda.OppiMac")
    }

    @Test func ownerSocketStaysOnCompanionSockForNodeFetch() {
        let root = DesktopCompanionOwnerSocketPath.defaultRuntimeRoot()
        #expect(root.lastPathComponent == "OppiDesktopCompanion")
        #expect(DesktopCompanionOwnerSocketPath.socketName == "companion.sock")
        let socketURL = DesktopCompanionOwnerSocketPath.socketURL(runtimeRoot: root)
        #expect(socketURL.lastPathComponent == "companion.sock")
        #expect(!socketURL.path.contains("oppi.sock"))
    }

    @Test func captureSourcesCompileIntoOppiMacNotACompanionTarget() throws {
        let captureService = try String(
            contentsOf: appleClientRoot()
                .appending(path: "OppiMac/Capture/ScreenCaptureKitDesktopCaptureService.swift"),
            encoding: .utf8
        )
        #expect(captureService.contains("SCContentSharingPicker"))
        #expect(captureService.contains("ScreenCaptureKitDesktopCaptureService"))

        let runtime = try String(
            contentsOf: appleClientRoot()
                .appending(path: "OppiMac/Capture/MacCaptureRuntime.swift"),
            encoding: .utf8
        )
        #expect(runtime.contains("ScreenCaptureKitDesktopCaptureService()"))
        #expect(runtime.contains("DesktopCompanionOwnerSocket"))

        let project = try String(
            contentsOf: appleClientRoot().appending(path: "project.yml"),
            encoding: .utf8
        )
        #expect(project.contains("sdk: ScreenCaptureKit.framework"))
        #expect(!project.contains("PRODUCT_BUNDLE_IDENTIFIER: dev.chenda.OppiDesktopCompanion"))
        #expect(!project.contains("OppiDesktopCompanionTests"))
    }
}
