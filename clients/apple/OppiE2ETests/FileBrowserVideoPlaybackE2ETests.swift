import Foundation
import XCTest

/// Paired-server proof that workspace video files open in the file browser and
/// can play through the system video player. Run this through sim-lab with
/// `--record-video=always` to keep the simulator playback artifact.
@MainActor
final class FileBrowserVideoPlaybackE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceName = ""

    override var e2eLaunchesWorkspaceHomeOnly: Bool { true }

    override func seedE2EFixtures() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        workspaceName = "video-playback-\(suffix)"

        let fixture = try createLabWorkspaceFileFixture(
            directoryName: "oppi-e2e-video-playback-\(suffix)",
            filename: Self.videoFilename,
            base64: Self.videoFixtureBase64
        )
        _ = try createLabWorkspace(named: workspaceName, hostMount: fixture.hostMount)
    }

    func testFileBrowserVideoPlaybackCanBeRecorded() throws {
        try openSeededWorkspace()
        try openWorkspaceFiles()
        try openVideoFile()
        try startPlaybackAndCaptureArtifact()
    }

    private func openSeededWorkspace() throws {
        let openButton = app.buttons["workspace.open.\(workspaceName)"]
        if !openButton.waitForExistence(timeout: 15) {
            app.collectionViews["workspace.list"].swipeDown()
        }
        XCTAssertTrue(openButton.waitForExistence(timeout: 15), "Seeded video workspace did not appear")
        openButton.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()

        XCTAssertTrue(
            app.buttons["workspace.files.open"].waitForExistence(timeout: 15),
            "Workspace detail did not load for video workspace"
        )
    }

    private func openWorkspaceFiles() throws {
        tap(app.buttons["workspace.files.open"], named: "workspace files button")
        XCTAssertTrue(
            app.navigationBars["Files"].waitForExistence(timeout: 10)
                || app.staticTexts[Self.videoFilename].waitForExistence(timeout: 10),
            "File browser did not open"
        )
    }

    private func openVideoFile() throws {
        let videoRow = app.staticTexts[Self.videoFilename]
        XCTAssertTrue(videoRow.waitForExistence(timeout: 15), "Video fixture file did not appear in file browser")
        tap(videoRow, named: "video fixture file row")

        XCTAssertTrue(
            app.otherElements["videoPlayer.native"].waitForExistence(timeout: 15),
            "Native video player did not load"
        )
    }

    private func startPlaybackAndCaptureArtifact() throws {
        let nativePlayer = app.otherElements["videoPlayer.native"]
        XCTAssertTrue(nativePlayer.waitForExistence(timeout: 8), "Native video player did not appear")

        let playButton = app.buttons["Play"]
        if playButton.waitForExistence(timeout: 2), playButton.isHittable {
            tap(playButton, named: "native video play button", timeout: 1)
        } else {
            nativePlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        let fullScreenControl = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", "screen", "screen", "zoom", "zoom")
        ).firstMatch
        XCTAssertTrue(fullScreenControl.waitForExistence(timeout: 3), "Native video full-screen control did not appear")
        XCTAssertFalse(app.staticTexts["Streaming from workspace file"].exists, "App-added source label should not be visible in the player")

        // This pause is not synchronization; it intentionally leaves a visible
        // playback interval for the simulator video artifact.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        try saveLabScreenshot(name: "file-browser-video-playback-e2e")
    }

    nonisolated private static let videoFilename = "oppi-video-playback.mp4"
    nonisolated private static let videoFixtureBase64 = """
AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAANLbW9vdgAAAGxtdmhkAAAAAAAAAAAA
AAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA
AABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAnZ0cmFrAAAAXHRraGQAAAADAAAA
AAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAA
AAAAAAAAAABAAAAAAKAAAABaAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAAAAABAAAA
AAHubWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAKABVxAAAAAAALWhkbHIAAAAAAAAAAHZp
ZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABmW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAA
ACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAVlzdGJsAAAAuXN0c2QAAAAAAAAA
AQAAAKlhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAKAAWgBIAAAASAAAAAAAAAABFUxhdmM2
Mi4xMS4xMDAgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAAL2F2Y0MBQsAK/+EAGGdCwAraCjfkwEQA
AAMABAAAAwBQPEiagAEABGjOD8gAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAADz6AAAAAAA
AAAYc3R0cwAAAAAAAAABAAAACgAABAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNjAAAAAAAA
AAEAAAABAAAACgAAAAEAAAA8c3RzegAAAAAAAAAAAAAACgAADY8AAAGJAAABigAAAdkAAAG/AAAC
SwAAAg0AAAHmAAACEAAAAfUAAAAUc3RjbwAAAAAAAAABAAADewAAAGF1ZHRhAAAAWW1ldGEAAAAA
AAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRh
AAAAAQAAAABMYXZmNjIuMy4xMDAAAAAIZnJlZQAAHoVtZGF0AAACVAYF//9Q3EXpvebZSLeWLNgg
2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2Rl
YyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRt
bCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1k
aWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2
IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0
X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MyBsb29rYWhlYWRfdGhyZWFkcz0x
IHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29t
cGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAg
a2V5aW50X21pbj0xMCBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAg
Y3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEu
NDAgYXE9MACAAAALM2WIhDomKAAJAsMYACTYAAgCYISSFgJq2GDEIQwf/wAPDdETAn7Omh94AFQS
i99WxxI3fcGEAASDwDwgABAdAAEADQABAWBwQRjBwQRgAFH+QFZgoTt+BwACgAAgCsYOAAUAAEAV
gAC2ALN0Cgm09yEhIgxgAIBjvE/ZZZZZZJskwGNAAKbIiY36GR3wJmiT9QXTTf2wJmiT9QXTTf2D
D4f8IABAAEAgBYDwQAAgFAACEyAAIK9gAewqzWiyefIMOAB4CoCzxpvUCJBgogYcZgOAAIFwAAgJ
gDg+mCAAFwaIAAIEQAAgD4OEFYg4QViDgAFQABAEYg4ABUAAQBGBHR2IxQABMejgACQHHAAEDaMw
HAAEC4AAQEgBwAB9MEAALgACANEAAECIAAQkYOEFYwcIKxBwACoAAgCMYOAAVAAEARiGMABAGEJN
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
"""
}
