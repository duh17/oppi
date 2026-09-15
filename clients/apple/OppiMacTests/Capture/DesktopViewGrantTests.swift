import Foundation
import Testing
@testable import Oppi

@Suite("Desktop view grant")
struct DesktopViewGrantGateTests {
    @Test func grantIsUnboundUntilFirstClaimAndJSONOmitsDeviceId() throws {
        let gate = DesktopViewGrantGate(clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        #expect(gate.current() == nil)

        let granted = gate.grantView()
        #expect(granted.capability == DesktopViewGrant.capabilityView)
        #expect(granted.deviceId == nil)
        #expect(granted.expiresAt == Date(timeIntervalSince1970: 1_700_000_000 + DesktopViewGrant.ttl))
        #expect(DesktopViewGrantJSON.body(for: granted) == nil)
        #expect(gate.grantView().grantId == granted.grantId)

        let bound = try gate.claim(deviceId: "phone-1", deviceName: "Chen iPhone").get()
        #expect(bound.grantId == granted.grantId)
        #expect(bound.deviceId == "phone-1")
        #expect(bound.deviceName == "Chen iPhone")
        let body = try #require(DesktopViewGrantJSON.body(for: bound))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(payload["deviceId"] == "phone-1")
        #expect(payload["capability"] == "view")
        #expect(payload["caption"] == DesktopCaptureCopy.viewSessionCaption)
        #expect(payload["grantId"] == granted.grantId.uuidString)
        #expect(payload["deviceName"] == nil)

        #expect(try gate.claim(deviceId: "phone-1", deviceName: nil).get().deviceId == "phone-1")
        #expect(gate.claim(deviceId: "phone-2", deviceName: "Other") == .failure(.notBound))
        #expect(gate.current()?.deviceId == "phone-1")
    }

    @Test func injectedClockExpiresGrantWithoutAutoRestart() {
        let box = DateBox(Date(timeIntervalSince1970: 1_700_000_000))
        let gate = DesktopViewGrantGate(clock: { box.now })
        let granted = gate.grantView()
        #expect(gate.current()?.grantId == granted.grantId)

        box.now = granted.expiresAt.addingTimeInterval(-1)
        #expect(gate.current()?.grantId == granted.grantId)

        box.now = granted.expiresAt
        #expect(gate.current() == nil)
        #expect(gate.claim(deviceId: "phone-1", deviceName: nil) == .failure(.unavailable))

        let next = gate.grantView()
        #expect(next.grantId != granted.grantId)
        #expect(next.deviceId == nil)
    }

    @Test func remainingPhraseUsesWholeMinutes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(DesktopViewGrantHTTP.remainingPhrase(expiresAt: now, now: now) == "expired")
        #expect(
            DesktopViewGrantHTTP.remainingPhrase(
                expiresAt: now.addingTimeInterval(1),
                now: now
            ) == "1 min remaining"
        )
        #expect(
            DesktopViewGrantHTTP.remainingPhrase(
                expiresAt: now.addingTimeInterval(60),
                now: now
            ) == "1 min remaining"
        )
        #expect(
            DesktopViewGrantHTTP.remainingPhrase(
                expiresAt: now.addingTimeInterval(61),
                now: now
            ) == "2 min remaining"
        )
    }

    @Test func headerDeviceNameOmitsNonLatin1() {
        #expect(DesktopViewGrantHTTP.headerDeviceName("Chen iPhone") == "Chen iPhone")
        #expect(DesktopViewGrantHTTP.headerDeviceName("Chen \u{1F4F1}") == nil)
    }
}

@Suite("DesktopCaptureSession view grant")
@MainActor
struct DesktopCaptureSessionViewGrantTests {
    @Test func grantDefaultsOffAndIsIndependentOfStillConsent() {
        let (session, fake) = makeHarness()
        #expect(session.viewGrant == nil)
        #expect(session.viewGrantStatusText == DesktopCaptureCopy.viewGrantNone)
        #expect(!session.canGrantView)
        session.grantView()
        #expect(session.viewGrant == nil)
        #expect(fake.captureCount == 0)

        let surface = makeSurface(windowID: 301, title: "Notes")
        pickWindow(session, fake, surface)
        #expect(session.canGrantView)
        fake.availability = .unavailable
        session.refreshAvailability()
        #expect(!session.canGrantView)
        session.grantView()
        #expect(session.viewGrant == nil)
        fake.availability = .ready
        session.refreshAvailability()
        #expect(session.canGrantView)
        session.grantView()
        #expect(session.viewGrant != nil)
        #expect(session.viewGrant?.deviceId == nil)
        #expect(session.viewGrantStatusText == DesktopCaptureCopy.viewGrantPending)
        #expect(!session.isLocalShareEnabled)
        #expect(!session.isRemoteViewEnabled)
        #expect(session.shareGate.current() == nil)
        #expect(session.shareGate.fetchCurrent() == .failure(.sharingDisabled))
        #expect(fake.captureCount == 0)

        session.captureOnce()
        fake.completePending(.success(makeStill(surface: surface)))
        session.enableLocalShare()
        session.enableRemoteView()
        #expect(session.viewGrant != nil)
        session.revokeLocalShare()
        session.revokeRemoteView()
        #expect(session.viewGrant != nil)
        #expect(session.canRevokeViewGrant)
    }

    @Test func unavailableGrantViewRefusesAndRevokesExisting() {
        let (session, fake) = makeHarness()
        pickWindow(session, fake, makeSurface(windowID: 306, title: "Notes"))
        session.grantView()
        #expect(session.viewGrant != nil)
        fake.availability = .unavailable
        session.grantView()
        #expect(session.viewGrant == nil)
        #expect(session.viewGrantGate.current() == nil)
        #expect(!session.canGrantView)
    }

    @Test func boundStatusUsesDeviceNameAndDoesNotSaySharedLive() throws {
        let (session, fake) = makeHarness()
        pickWindow(session, fake, makeSurface(windowID: 302, title: "Mail"))
        session.grantView()
        let grant = try #require(session.viewGrant)
        #expect(try session.viewGrantGate.claim(deviceId: "phone-1", deviceName: "Chen iPhone").get().deviceId == "phone-1")
        let text = session.viewGrantStatusText(now: grant.createdAt)
        #expect(text.contains("Chen iPhone"))
        #expect(text.contains("Not live delivery"))
        #expect(!text.localizedCaseInsensitiveContains("shared live"))
        #expect(!text.localizedCaseInsensitiveContains("live viewing"))
    }

    @Test func previewDoesNotCreateViewGrant() {
        let (session, fake) = makeHarness()
        pickWindow(session, fake, makeSurface(windowID: 303, title: "Preview"))
        session.startLocalPreview()
        fake.confirmPreviewStart()
        fake.deliverPreviewFrame(makePixel())
        #expect(session.isLivePreview)
        #expect(session.viewGrant == nil)

        session.grantView()
        let grantID = session.viewGrant?.grantId
        session.stopLocalPreview()
        fake.completePreviewStop()
        #expect(session.viewGrant?.grantId == grantID)
        #expect(!session.isLivePreview)
        #expect(fake.captureCount == 0)
    }

    @Test func clearReselectUnavailableAndTerminateRevokeViewGrantWithoutAutoRestart() {
        let (session, fake) = makeHarness()
        let first = makeSurface(windowID: 304, title: "Keep")
        pickWindow(session, fake, first)
        session.grantView()
        #expect(session.viewGrant != nil)

        session.clear()
        #expect(session.viewGrant == nil)
        #expect(session.viewGrantGate.current() == nil)

        pickWindow(session, fake, first)
        session.grantView()
        pickWindow(session, fake, makeSurface(windowID: 305, title: "Other"))
        #expect(session.viewGrant == nil)

        session.grantView()
        fake.simulateSurfaceUnavailable(makeSurface(windowID: 305, title: "Other"))
        #expect(session.viewGrant == nil)
        #expect(session.selection == nil)
        session.grantView()
        #expect(session.viewGrant == nil)

        pickWindow(session, fake, first)
        session.grantView()
        session.startLocalPreview()
        session.prepareForTermination()
        fake.completePreviewStop()
        #expect(session.viewGrant == nil)
        #expect(session.previewState == .stopped)
        #expect(session.viewGrantGate.current() == nil)
    }
}

private final class DateBox: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
