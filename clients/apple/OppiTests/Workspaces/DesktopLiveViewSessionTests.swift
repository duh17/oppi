import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Desktop live view session")
struct DesktopLiveViewSessionTests {
    @Test func availabilityNeedsExperimentAndCapability() {
        #expect(DesktopLiveViewPlayground.isAvailable(experimentEnabled: true, serverOffers: true))
        #expect(!DesktopLiveViewPlayground.isAvailable(experimentEnabled: true, serverOffers: false))
        #expect(!DesktopLiveViewPlayground.isAvailable(experimentEnabled: false, serverOffers: true))
    }

    @Test func serverInfoDecodesDesktopLiveViewCapability() throws {
        func capabilities(_ extra: String) throws -> ServerInfo.Capabilities? {
            let json = """
            {"name":"t","version":"0.50.0","uptime":1,"os":"darwin","arch":"arm64","hostname":"t",
             "nodeVersion":"v24","piVersion":"0.85.0","configVersion":1,"identity":null,
             "capabilities":{"sessionStream":{"version":1}\(extra)},
             "stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}}
            """
            return try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8)).capabilities
        }
        #expect(try capabilities(#","desktopLiveView":{"version":1}"#)?.desktopLiveView?.version == 1)
        #expect(try capabilities("")?.desktopLiveView == nil)
    }

    @Test func liveStatusFollowsFrameArrivalNotTheSocket() {
        var machine = DesktopLiveArrivalMachine()
        machine.onHello(title: "Notes", now: 10)
        #expect(machine.presentation == .connecting)

        machine.onFrame(now: 10.2)
        #expect(machine.presentation == .live(title: "Notes"))

        machine.onTick(now: 11.5)
        #expect(machine.presentation == .live(title: "Notes"))

        machine.onTick(now: 12.3)
        guard case .paused(let title, let age) = machine.presentation else {
            Issue.record("expected paused, got \(machine.presentation)")
            return
        }
        #expect(title == "Notes")
        #expect(age > 2)

        machine.onDisconnect(now: 12.4, willReconnect: true)
        guard case .reconnecting(let reconnectTitle, let reconnectAge) = machine.presentation else {
            Issue.record("expected reconnecting, got \(machine.presentation)")
            return
        }
        #expect(reconnectTitle == "Notes")
        #expect(reconnectAge != nil)

        machine.onFrame(now: 13)
        #expect(machine.presentation == .live(title: "Notes"))
    }

    @Test func grantAndFatalClosesDoNotReconnect() {
        #expect(DesktopLiveReconnectPolicy.isFatal(code: 4104, reason: nil))
        #expect(DesktopLiveReconnectPolicy.isFatal(code: 4000, reason: "grant_revoked"))
        #expect(DesktopLiveReconnectPolicy.isFatal(code: 4106, reason: "surface_gone"))
        #expect(DesktopLiveReconnectPolicy.isFatal(code: 4109, reason: nil))
        #expect(!DesktopLiveReconnectPolicy.isFatal(code: 4001, reason: "already_streaming"))
        #expect(!DesktopLiveReconnectPolicy.isFatal(code: 4002, reason: "companion_unavailable"))
        #expect(!DesktopLiveReconnectPolicy.isFatal(code: 4111, reason: nil))
        #expect(!DesktopLiveReconnectPolicy.isFatal(code: 1006, reason: ""))
        #expect(!DesktopLiveReconnectPolicy.isFatal(code: 1001, reason: nil))
        #expect(DesktopLiveReconnectPolicy.isGrant(4103, reason: "grant_not_bound"))
        #expect(DesktopLiveReconnectPolicy.message(code: 4103, reason: nil, serverMessage: nil)
            == DesktopLiveReconnectPolicy.grantMessage)
        #expect(DesktopLiveReconnectPolicy.delay(attempt: 1) == 0.5)
        #expect(DesktopLiveReconnectPolicy.delay(attempt: 5) == 8)
        #expect(DesktopLiveReconnectPolicy.delay(attempt: 99) == 8)

        var machine = DesktopLiveArrivalMachine()
        machine.onFrame(now: 1)
        machine.onWaitingForGrant()
        guard case .waitingForGrant(let message) = machine.presentation else {
            Issue.record("expected waiting for grant")
            return
        }
        #expect(message == DesktopLiveReconnectPolicy.grantMessage)
        machine.onFatal(message: "That Mac window is no longer available.")
        guard case .failed(let failed) = machine.presentation else {
            Issue.record("expected failed")
            return
        }
        #expect(failed.contains("window"))
    }

    @Test @MainActor func backgroundCloseDoesNotTearDownTheForegroundStream() async {
        let fake = LiveViewStreamFake()
        let model = DesktopLiveViewerModel(open: { fake.open() }, clock: { 100 })
        model.appear()
        await waitUntil { fake.connectCount == 1 }
        fake.sendHello()
        #expect(model.presentation.statusText == "Connecting")
        #expect(model.connectCount == 1)

        model.backgrounded()
        model.foregrounded()
        await waitUntil { fake.connectCount == 2 }
        fake.sendHello()
        try? await Task.sleep(for: .milliseconds(700))
        #expect(fake.connectCount == 2)
        #expect(model.connectCount == 2)
        guard case .connecting = model.presentation else {
            Issue.record("stale close restarted backoff: \(model.presentation)")
            return
        }
    }

    @Test @MainActor func alreadyStreamingOnReconnectRecoversOnTheNextAttempt() async {
        let fake = LiveViewStreamFake()
        let model = DesktopLiveViewerModel(open: { fake.open() }, clock: { 100 })
        model.appear()
        await waitUntil { fake.connectCount == 1 }
        fake.sendHello()
        fake.failNextWithAlreadyStreaming = 1
        model.backgrounded()
        model.foregrounded()
        await waitUntil { fake.connectCount == 2 }
        await waitUntil { model.presentation.statusText == "Reconnecting" }
        await waitUntil(timeoutMs: 2000) { fake.connectCount == 3 }
        fake.sendHello()
        #expect(model.connectCount == 3)
        guard case .connecting = model.presentation else {
            Issue.record("already-streaming stayed fatal: \(model.presentation)")
            return
        }
    }

    @Test @MainActor func http404UpgradeStopsWithoutRetry() async {
        let fake = LiveViewStreamFake()
        let model = DesktopLiveViewerModel(open: { fake.open() }, clock: { 100 })
        model.appear()
        await waitUntil { fake.connectCount == 1 }
        fake.sendError(DesktopViewErrorMessage(code: 0, message: "", fatal: true))
        await waitUntil { model.presentation.statusText == "Can't show Remote Screen" }
        try? await Task.sleep(for: .milliseconds(700))
        #expect(fake.connectCount == 1)
        guard case .failed(let message) = model.presentation else {
            Issue.record("expected generic failure, got \(model.presentation)")
            return
        }
        #expect(message == "Couldn't show the live remote screen.")
    }

    @Test @MainActor func transientCloseWhileVisibleReconnects() async {
        let fake = LiveViewStreamFake()
        let model = DesktopLiveViewerModel(open: { fake.open() }, clock: { 100 })
        model.appear()
        await waitUntil { fake.connectCount == 1 }
        fake.sendHello()
        fake.sendClosed(code: 1006, reason: "")
        await waitUntil { model.presentation.statusText == "Reconnecting" }
        await waitUntil(timeoutMs: 2000) { fake.connectCount == 2 }
        fake.sendHello()
        #expect(model.connectCount == 2)
    }

    @Test @MainActor func experimentsToggleCountsAndGatesTheRow() {
        let key = AppPreferences.Experiments.desktopLiveViewKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(false, forKey: key)
        let off = SettingsExperimentsPage.enabledCount(sessionThreadsEnabled: false)
        UserDefaults.standard.set(true, forKey: key)
        let on = SettingsExperimentsPage.enabledCount(sessionThreadsEnabled: false)
        #expect(on == off + 1)
        #expect(WorkspaceUtilityNavTarget.desktopStill.isReleaseEnabled)
        let phone = WorkspaceSidebarPrimaryUtilities.items(
            for: .phone,
            sshTerminalEnabled: false,
            hasSSHProfile: false,
            desktopLiveViewAvailable: true
        )
        #expect(phone.last?.target == .desktopStill)
        #expect(phone.filter { $0.target.isReleaseEnabled }.last?.target == .desktopStill)
    }
}

@MainActor
private final class LiveViewStreamFake {
    private(set) var connectCount = 0
    var failNextWithAlreadyStreaming = 0
    private var continuation: AsyncStream<DesktopLiveViewStreamClient.Event>.Continuation?

    func open() -> DesktopLiveViewerModel.Opening {
        connectCount += 1
        let stream = AsyncStream<DesktopLiveViewStreamClient.Event> { continuation in
            self.continuation = continuation
            if self.failNextWithAlreadyStreaming > 0 {
                self.failNextWithAlreadyStreaming -= 1
                continuation.yield(.error(DesktopViewErrorMessage(
                    code: DesktopViewStream.ErrorCode.alreadyStreaming,
                    message: "Desktop view stream is already active",
                    fatal: false
                )))
                continuation.yield(.closed(code: 4000, reason: "already_streaming"))
                continuation.finish()
                self.continuation = nil
            }
        }
        return (
            events: stream,
            disconnect: { [weak self] in
                let pending = self?.continuation
                self?.continuation = nil
                Task { @MainActor in
                    pending?.yield(.closed(code: 1001, reason: "goingAway"))
                    pending?.finish()
                }
            }
        )
    }

    func sendHello() {
        continuation?.yield(.hello(
            DesktopViewHello(
                version: 1,
                features: [DesktopViewStream.featureAvcc],
                grantId: "g",
                deviceId: "d",
                surface: DesktopViewSurface(windowId: 1, title: "Notes"),
                expiresAt: nil
            )
        ))
    }

    func sendError(_ error: DesktopViewErrorMessage) {
        continuation?.yield(.error(error))
    }

    func sendClosed(code: Int, reason: String) {
        continuation?.yield(.closed(code: code, reason: reason))
        continuation?.finish()
    }
}

@MainActor
private func waitUntil(
    timeoutMs: Int = 1000,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
