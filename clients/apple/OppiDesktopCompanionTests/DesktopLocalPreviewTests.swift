import CoreGraphics
import Foundation
import Testing
@testable import OppiDesktopCompanion

@Suite("Desktop local preview")
@MainActor
struct DesktopLocalPreviewTests {
    @Test func startWaitsForReadyAndAFrameBeforeLiveCaption() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 101, title: "Notes")
        pickWindow(session, fake, surface)

        session.startLocalPreview()

        #expect(fake.previewStartCount == 1)
        #expect(session.previewState == .starting)
        #expect(session.previewStatusText == DesktopCaptureCopy.previewStarting)
        #expect(session.previewLabel == nil)
        #expect(!session.isLivePreview)
        #expect(!session.canCapture)
        #expect(!session.canStartLocalPreview)
        #expect(session.canStopLocalPreview)

        fake.confirmPreviewStart()
        #expect(session.previewState == .starting)
        #expect(!session.isLivePreview)

        let frame = makePixel(red: 1)
        fake.deliverPreviewFrame(frame)
        #expect(session.previewState == .live)
        #expect(session.isLivePreview)
        #expect(session.previewLabel == DesktopCaptureCopy.localPreviewCaption)
        #expect(session.previewStatusText == DesktopCaptureCopy.localPreviewCaption)
        #expect(session.previewFrame === frame)
    }

    @Test func frameBeforeStartConfirmationStaysStarting() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 102, title: "Safari")
        pickWindow(session, fake, surface)
        session.startLocalPreview()

        let frame = makePixel(green: 1)
        fake.deliverPreviewFrame(frame)
        #expect(session.previewState == .starting)
        #expect(!session.isLivePreview)
        #expect(session.previewLabel == nil)
        #expect(session.previewFrame === frame)

        fake.confirmPreviewStart()
        #expect(session.previewState == .live)
        #expect(session.isLivePreview)
        #expect(session.previewLabel == DesktopCaptureCopy.localPreviewCaption)
    }

    @Test func secondStartIsIgnoredWhilePreviewing() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 103, title: "Mail")
        pickWindow(session, fake, surface)
        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel())

        session.startLocalPreview()
        session.startLocalPreview()

        #expect(fake.previewStartCount == 1)
        #expect(session.previewState == .live)
    }

    @Test func captureOnceIsDisabledAndDoesNotRunWhilePreviewing() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 104, title: "Maps")
        pickWindow(session, fake, surface)
        session.startLocalPreview()
        #expect(!session.canCapture)
        session.captureOnce()
        #expect(fake.captureCount == 0)

        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel())
        session.captureOnce()
        #expect(fake.captureCount == 0)
        #expect(session.still == nil)
    }

    @Test func stopDiscardsPendingAndLateFrames() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 105, title: "Calendar")
        pickWindow(session, fake, surface)
        session.startLocalPreview()
        fake.confirmPreviewStart()
        let live = makePixel(blue: 1)
        fake.deliverPreviewFrame(live)
        #expect(session.previewFrame === live)

        session.stopLocalPreview()
        #expect(session.previewState == .stopping)
        #expect(session.previewStatusText == DesktopCaptureCopy.previewStopping)
        #expect(!session.isLivePreview)
        #expect(session.previewLabel == nil)
        #expect(session.previewFrame == nil)
        #expect(fake.previewStopCount == 1)
        #expect(!session.canStopLocalPreview)
        #expect(!session.canStartLocalPreview)

        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel(red: 1))
        #expect(session.previewState == .stopping)
        #expect(session.previewFrame == nil)
        #expect(!session.isLivePreview)

        fake.completePreviewStop()
        #expect(session.previewState == .stopped)
        #expect(session.previewStatusText == DesktopCaptureCopy.previewStopped)
        fake.deliverPreviewFrame(makePixel(green: 1))
        #expect(session.previewFrame == nil)
        #expect(!session.isLivePreview)
    }

    @Test func lateStartCompletionCannotReviveStoppedPreview() throws {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 106, title: "Notes")
        pickWindow(session, fake, surface)
        session.startLocalPreview()
        let staleGeneration = try #require(fake.lastPreviewGeneration)

        session.stopLocalPreview()
        fake.completePreviewStop()
        fake.confirmPreviewStart(generation: staleGeneration)
        fake.deliverPreviewFrame(makePixel(red: 1), generation: staleGeneration)

        #expect(session.previewState == .stopped)
        #expect(session.previewFrame == nil)
        #expect(!session.isLivePreview)
        #expect(fake.previewStartCount == 1)
    }

    @Test func clearStopsProducerAndRevokesStillShareWithoutPublishingPreview() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 107, title: "Terminal")
        pickWindow(session, fake, surface)
        session.captureOnce()
        fake.completePending(.success(makeStill(surface: surface)))
        session.enableLocalShare()
        #expect(session.isLocalShareEnabled)

        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel(red: 1))
        let captures = fake.captureCount
        let shareBefore = session.shareGate.current()?.captureID
        #expect(shareBefore != nil)

        session.clear()
        fake.deliverPreviewFrame(makePixel(green: 1))

        #expect(session.previewState == .stopping)
        #expect(session.previewFrame == nil)
        #expect(!session.isLivePreview)
        #expect(session.still == nil)
        #expect(!session.isLocalShareEnabled)
        #expect(session.shareGate.current() == nil)
        #expect(fake.previewStopCount == 1)
        #expect(fake.captureCount == captures)

        fake.completePreviewStop()
        #expect(session.previewState == .stopped)
        #expect(session.previewFrame == nil)
    }

    @Test func reselectionStopsPreviewAndRevokesStillShare() throws {
        let (session, fake) = makeHarness()
        let first = makeSurface(windowID: 108, title: "Code")
        let second = makeSurface(windowID: 109, title: "Preview")
        pickWindow(session, fake, first)
        session.captureOnce()
        fake.completePending(.success(makeStill(surface: first)))
        session.enableLocalShare()
        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel())
        let staleGeneration = try #require(fake.lastPreviewGeneration)

        pickWindow(session, fake, second)
        fake.deliverPreviewFrame(makePixel(red: 1), generation: staleGeneration)

        #expect(session.selection == second)
        #expect(session.previewState == .stopping)
        #expect(session.previewFrame == nil)
        #expect(session.still == nil)
        #expect(!session.isLocalShareEnabled)
        #expect(session.shareGate.current() == nil)
        #expect(fake.previewStopCount == 1)

        fake.completePreviewStop()
        #expect(session.previewState == .stopped)
        #expect(session.previewFrame == nil)
    }

    @Test func selectedWindowClosureStopsPreviewAndDoesNotSubstitute() throws {
        let (session, fake) = makeHarness()
        let original = makeSurface(windowID: 110, title: "Original")
        let other = makeSurface(windowID: 111, title: "Other")
        pickWindow(session, fake, original)
        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel())
        let staleGeneration = try #require(fake.lastPreviewGeneration)

        fake.simulateSurfaceUnavailable(original)
        fake.deliverPreviewFrame(makePixel(red: 1), generation: staleGeneration)
        fake.confirmPreviewStart(generation: staleGeneration)
        fake.simulateUserSelection(other)

        #expect(session.selection == nil)
        #expect(session.selection != other)
        #expect(session.previewState == .stopping)
        #expect(session.previewFrame == nil)
        #expect(!session.isLivePreview)
        #expect(session.failure == .unavailable || session.failure == .surfaceSubstitutionRejected)
        #expect(fake.previewStopCount == 1)
        #expect(!session.canStartLocalPreview)

        fake.completePreviewStop()
        #expect(session.previewState == .unavailable)
        #expect(session.previewStatusText == DesktopCaptureCopy.previewUnavailable)
        #expect(session.previewFrame == nil)
        #expect(!session.canStartLocalPreview)
    }

    @Test func startFailureIsHonestAndDoesNotGoLive() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 112, title: "Notes")
        pickWindow(session, fake, surface)
        session.startLocalPreview()
        fake.failPreview(.permissionDenied)
        fake.deliverPreviewFrame(makePixel())

        #expect(session.previewState == .stopped)
        #expect(session.failure == .permissionDenied)
        #expect(session.previewFrame == nil)
        #expect(!session.isLivePreview)
        #expect(session.previewLabel == nil)
    }

    @Test func permissionDeniedDoesNotStartProducer() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 113, title: "Maps")
        pickWindow(session, fake, surface)
        fake.availability = .permissionDenied

        session.startLocalPreview()

        #expect(fake.previewStartCount == 0)
        #expect(session.previewState == .stopped)
        #expect(session.failure == .permissionDenied)
        #expect(!session.isLivePreview)
    }

    @Test func unsupportedDoesNotStartProducer() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 114, title: "Calendar")
        pickWindow(session, fake, surface)
        fake.availability = .unsupported

        session.startLocalPreview()

        #expect(fake.previewStartCount == 0)
        #expect(session.previewState == .stopped)
        #expect(session.failure == .unsupported)
    }

    @Test func startDoesNotPublishOrRecaptureStill() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 115, title: "Notes")
        pickWindow(session, fake, surface)
        session.captureOnce()
        let still = makeStill(surface: surface)
        fake.completePending(.success(still))
        session.enableLocalShare()
        session.enableRemoteView()
        let captures = fake.captureCount
        let local = session.shareGate.current()
        let remote = session.shareGate.fetchCurrent()

        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel(red: 1))
        session.stopLocalPreview()
        fake.completePreviewStop()

        #expect(fake.captureCount == captures)
        #expect(session.still?.captureID == still.captureID)
        #expect(session.isLocalShareEnabled)
        #expect(session.isRemoteViewEnabled)
        #expect(session.shareGate.current()?.captureID == local?.captureID)
        #expect(session.shareGate.current()?.pngData == local?.pngData)
        #expect(session.shareGate.fetchCurrent() == remote)
        #expect(session.previewState == .stopped)
        #expect(!session.isLivePreview)
    }

    @Test func previewFramesNeverEnterShareGate() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 116, title: "Mail")
        pickWindow(session, fake, surface)
        #expect(session.shareGate.current() == nil)

        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel(red: 1))

        #expect(session.isLivePreview)
        #expect(session.shareGate.current() == nil)
        #expect(session.shareGate.fetchCurrent() == .failure(.sharingDisabled))
        #expect(fake.captureCount == 0)
        #expect(!session.isLocalShareEnabled)
        #expect(!session.isRemoteViewEnabled)
    }

    @Test func mismatchedFrameDoesNotSubstituteSurface() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 117, title: "Keep")
        pickWindow(session, fake, surface)
        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel(), surfaceID: CaptureSurfaceID(windowID: 999))

        #expect(session.selection == surface)
        #expect(session.previewFrame == nil)
        #expect(!session.isLivePreview)
        #expect(session.failure == .surfaceSubstitutionRejected)
        #expect(session.previewState == .stopping)
        #expect(fake.previewStopCount == 1)

        fake.completePreviewStop()
        #expect(session.previewState == .stopped)
        #expect(session.previewFrame == nil)
    }

    @Test func identicalFramesKeepTheStreamLive() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 118, title: "Static")
        pickWindow(session, fake, surface)
        session.startLocalPreview()
        fake.confirmPreviewStart()
        let frame = makePixel()
        fake.deliverPreviewFrame(frame)
        fake.deliverPreviewFrame(frame)
        fake.deliverPreviewFrame(frame)

        #expect(session.previewState == .live)
        #expect(session.isLivePreview)
        #expect(session.failure == nil)
        #expect(session.previewFrame === frame)
    }

    @Test func captureInFlightBlocksPreviewStart() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 119, title: "Notes")
        pickWindow(session, fake, surface)
        session.captureOnce()
        #expect(session.isCaptureInFlight)

        session.startLocalPreview()

        #expect(fake.previewStartCount == 0)
        #expect(session.previewState == .stopped)
        #expect(session.isCaptureInFlight)
    }

    @Test func noAutomaticRestartAfterFailure() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 120, title: "Notes")
        pickWindow(session, fake, surface)
        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel())
        fake.failPreview(.captureFailed)

        #expect(session.previewState == .stopped)
        #expect(session.failure == .captureFailed)
        #expect(fake.previewStartCount == 1)
        #expect(!session.isLivePreview)
    }

    @Test func failureRacingExplicitStopLeavesPreviewTerminalOnce() throws {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 121, title: "Notes")
        pickWindow(session, fake, surface)
        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel())
        let stoppingGeneration = try #require(fake.lastPreviewGeneration)

        session.stopLocalPreview()
        #expect(session.previewState == .stopping)
        #expect(!session.canCapture)
        #expect(!session.canStartLocalPreview)

        fake.failPreview(.captureFailed, generation: stoppingGeneration)
        #expect(session.previewState == .stopped)
        #expect(session.previewStatusText == DesktopCaptureCopy.previewStopped)
        #expect(session.failure == .captureFailed)
        #expect(!session.isLivePreview)
        #expect(session.previewLabel == nil)
        #expect(session.canCapture)
        #expect(session.canStartLocalPreview)

        fake.completePreviewStop(failure: .permissionDenied, generation: stoppingGeneration)
        #expect(session.previewState == .stopped)
        #expect(session.failure == .captureFailed)
        #expect(fake.previewStartCount == 1)
    }

    @Test func delayedStopBlocksRestartUntilProducerCompletes() throws {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 122, title: "Mail")
        pickWindow(session, fake, surface)
        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel(red: 1))
        #expect(session.previewState == .live)
        #expect(fake.previewStartCount == 1)

        session.clear()
        #expect(session.previewState == .stopping)
        #expect(session.previewStatusText == DesktopCaptureCopy.previewStopping)
        #expect(!session.canStartLocalPreview)
        #expect(!session.canCapture)
        #expect(session.still == nil)

        session.startLocalPreview()
        session.captureOnce()
        #expect(fake.previewStartCount == 1)
        #expect(fake.captureCount == 0)
        #expect(session.previewState == .stopping)

        fake.completePreviewStop()
        #expect(session.previewState == .stopped)
        #expect(session.canStartLocalPreview)
        #expect(session.canCapture)

        session.startLocalPreview()
        #expect(fake.previewStartCount == 2)
        #expect(session.previewState == .starting)
    }

    @Test func unavailableStartupFailureMapsToUnavailableWithoutLiveCaption() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 123, title: "Calendar")
        pickWindow(session, fake, surface)
        session.grantView()
        #expect(session.viewGrant != nil)
        session.startLocalPreview()
        fake.failPreview(.unavailable)
        fake.deliverPreviewFrame(makePixel())
        fake.confirmPreviewStart()

        #expect(session.previewState == .unavailable)
        #expect(session.previewStatusText == DesktopCaptureCopy.previewUnavailable)
        #expect(session.failure == .unavailable)
        #expect(session.previewFrame == nil)
        #expect(!session.isLivePreview)
        #expect(session.previewLabel == nil)
        #expect(fake.previewStartCount == 1)
        #expect(session.viewGrant == nil)
        #expect(session.viewGrantGate.current() == nil)
    }

    @Test func unavailableFailureRacingStopMapsToUnavailable() throws {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 124, title: "Safari")
        pickWindow(session, fake, surface)
        session.grantView()
        #expect(session.viewGrant != nil)
        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel())
        let stoppingGeneration = try #require(fake.lastPreviewGeneration)

        session.stopLocalPreview()
        fake.failPreview(.unavailable, generation: stoppingGeneration)

        #expect(session.previewState == .unavailable)
        #expect(session.previewStatusText == DesktopCaptureCopy.previewUnavailable)
        #expect(session.failure == .unavailable)
        #expect(!session.isLivePreview)
        #expect(session.previewLabel == nil)
        #expect(session.previewFrame == nil)
        #expect(session.viewGrant == nil)
        #expect(session.viewGrantGate.current() == nil)
    }

    @Test func debugTestsInjectAFakeCaptureProducer() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            at: testsDir,
            includingPropertiesForKeys: nil
        )
        let constructor = "service: " + "ScreenCaptureKitDesktopCaptureService"
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains(constructor),
                "\(file.lastPathComponent) must inject a fake producer"
            )
        }
    }

    @Test func captureHelperMayUseSCStreamOnlyForLocalPreview() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiDesktopCompanion/ScreenCaptureKitDesktopCaptureService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("SCScreenshotManager.captureImage"))
        #expect(source.contains("DesktopLatestFrameMailbox"))
        #expect(source.contains("startCapture"))
        #expect(source.contains("retiringProducer"))
        #expect(source.contains("error.map(ScreenCaptureKitDesktopCaptureService.mapError)"))
        #expect(source.contains("MainActor.assumeIsolated"))
        #expect(!source.contains("fileURL"))
        #expect(!source.contains("CGRequestScreenCaptureAccess"))
        #expect(!source.contains("com.apple.developer.persistent-content-capture"))
    }
}
