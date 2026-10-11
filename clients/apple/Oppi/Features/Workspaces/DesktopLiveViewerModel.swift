import Foundation
import Observation

/// Owns the live-view session: connect, decode, live/stale chrome, reconnect policy.
@MainActor
@Observable
final class DesktopLiveViewerModel {
    private(set) var arrival = DesktopLiveArrivalMachine()
    private(set) var hasPicture = false

    var presentation: DesktopLivePresentation { arrival.presentation }

    private let makeClient: () -> DesktopLiveViewStreamClient?
    private let clock: () -> TimeInterval
    private let decoder = DesktopLiveH264Decoder()
    private var client: DesktopLiveViewStreamClient?
    private var consumeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var picture: DesktopLiveSampleBufferView?
    private var reconnectAttempt = 0
    private var visible = false
    private var fatal = false
    private var lastErrorCode: Int?
    private var lastErrorReason: String?
    private var lastErrorMessage: String?

    init(
        makeClient: @escaping () -> DesktopLiveViewStreamClient?,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.makeClient = makeClient
        self.clock = clock
    }

    func attachPicture(_ view: DesktopLiveSampleBufferView) {
        picture = view
        applyPictureAccessibility()
    }

    func appear() {
        visible = true
        if fatal { return }
        start()
    }

    func disappear() {
        visible = false
        stop(clearPicture: true)
    }

    func backgrounded() {
        visible = false
        stop(clearPicture: true)
    }

    func foregrounded() {
        visible = true
        guard !fatal else { return }
        start()
    }

    func retry() {
        fatal = false
        lastErrorCode = nil
        lastErrorReason = nil
        lastErrorMessage = nil
        reconnectAttempt = 0
        hasPicture = false
        decoder.reset()
        picture?.clearPicture()
        mutateArrival { $0.resetConnecting() }
        start()
    }

    func tickForTesting(now: TimeInterval) {
        mutateArrival { $0.onTick(now: now) }
        applyPictureAccessibility()
    }

    private func mutateArrival(_ body: (inout DesktopLiveArrivalMachine) -> Void) {
        var next = arrival
        body(&next)
        arrival = next
    }

    private func start() {
        stop(clearPicture: false)
        if !hasPicture {
            mutateArrival { $0.resetConnecting() }
        }
        applyPictureAccessibility()
        guard let client = makeClient() else {
            mutateArrival { $0.onFatal(message: "Couldn't show the live remote screen.") }
            applyPictureAccessibility()
            return
        }
        self.client = client
        let events = client.connect()
        consumeTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.mutateArrival { $0.onTick(now: self?.clock() ?? 0) }
                self?.applyPictureAccessibility()
            }
        }
    }

    private func stop(clearPicture: Bool) {
        reconnectTask?.cancel()
        reconnectTask = nil
        tickTask?.cancel()
        tickTask = nil
        consumeTask?.cancel()
        consumeTask = nil
        client?.disconnect()
        client = nil
        decoder.reset()
        if clearPicture {
            picture?.clearPicture()
            hasPicture = false
        }
    }

    private func handle(_ event: DesktopLiveViewStreamClient.Event) async {
        switch event {
        case .hello(let hello):
            mutateArrival { $0.onHello(title: hello.surface.title, now: self.clock()) }
            applyPictureAccessibility()
        case .media(let header, let payload):
            guard let sample = decoder.sampleBuffer(payload: payload, header: header) else {
                return
            }
            if picture?.enqueue(sample) == false {
                decoder.noteBrokenChain()
                return
            }
            hasPicture = true
            mutateArrival { $0.onFrame(now: self.clock()) }
            applyPictureAccessibility()
        case .error(let error):
            lastErrorCode = error.code
            lastErrorMessage = error.message
            let fatalClose = error.fatal == true || DesktopLiveReconnectPolicy.isFatal(
                code: error.code,
                reason: nil
            )
            if fatalClose {
                failClosed(code: error.code, reason: nil, serverMessage: error.message)
            }
        case .closed(let code, let reason):
            lastErrorReason = reason
            let applicationCode = lastErrorCode.flatMap {
                DesktopViewStream.isFatalErrorCode($0) ? $0 : nil
            } ?? (DesktopViewStream.isFatalErrorCode(code) ? code : lastErrorCode)
            if DesktopLiveReconnectPolicy.isFatal(code: applicationCode, reason: reason) {
                failClosed(
                    code: applicationCode,
                    reason: reason,
                    serverMessage: lastErrorMessage
                )
                return
            }
            scheduleReconnect()
        }
    }

    private func failClosed(code: Int?, reason: String?, serverMessage: String?) {
        fatal = true
        stop(clearPicture: false)
        let message = DesktopLiveReconnectPolicy.message(
            code: code,
            reason: reason,
            serverMessage: serverMessage
        )
        if DesktopLiveReconnectPolicy.isGrant(code, reason: reason) {
            mutateArrival { $0.onWaitingForGrant(message: message) }
        } else {
            mutateArrival { $0.onFatal(message: message) }
        }
        applyPictureAccessibility()
    }

    private func scheduleReconnect() {
        guard visible, !fatal else { return }
        reconnectAttempt += 1
        let delay = DesktopLiveReconnectPolicy.delay(attempt: reconnectAttempt)
        mutateArrival { $0.onDisconnect(now: self.clock(), willReconnect: true) }
        applyPictureAccessibility()
        client?.disconnect()
        client = nil
        consumeTask?.cancel()
        consumeTask = nil
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.visible, !self.fatal, !Task.isCancelled else { return }
            self.start()
        }
    }

    private func applyPictureAccessibility() {
        let title = presentation.windowTitle ?? "Remote Screen"
        let value: String
        if let detail = presentation.detailText, presentation.statusText != "Live" {
            value = "\(presentation.statusText), \(detail)"
        } else {
            value = presentation.statusText
        }
        picture?.setAccessibilityChrome(label: title, value: value)
    }
}
