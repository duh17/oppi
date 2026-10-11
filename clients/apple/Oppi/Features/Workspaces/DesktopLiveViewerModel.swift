import Foundation
import Observation

/// Connects the dedicated live-view socket, decodes, and owns live/stale chrome.
///
/// A session generation drops events from a socket this model already stopped.
/// That close is not a drop: treating it as one restarted backoff and tore down
/// the replacement stream after background. Node also refuses a second stream
/// (`already_streaming`, fatal 4110) until the previous WebSocket has closed.
@MainActor
@Observable
final class DesktopLiveViewerModel {
    private(set) var arrival = DesktopLiveArrivalMachine()
    private(set) var hasPicture = false
    private(set) var connectCount = 0

    var presentation: DesktopLivePresentation { arrival.presentation }

    typealias Opening = (
        events: AsyncStream<DesktopLiveViewStreamClient.Event>,
        disconnect: () -> Void
    )

    private let open: () -> Opening?
    private let clock: () -> TimeInterval
    private let decoder = DesktopLiveH264Decoder()
    private var disconnect: (() -> Void)?
    private var consumeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var pendingClose: Task<Void, Never>?
    private var picture: DesktopLiveSampleBufferView?
    private var sessionGeneration = 0
    private var reconnectAttempt = 0
    private var visible = false
    private var fatal = false
    private var lastErrorCode: Int?
    private var lastErrorReason: String?
    private var lastErrorMessage: String?

    init(
        open: @escaping () -> Opening?,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.open = open
        self.clock = clock
    }

    func attachPicture(_ view: DesktopLiveSampleBufferView) {
        picture = view
        applyPictureAccessibility()
    }

    func appear() {
        setVisible(true)
    }

    func disappear() {
        setVisible(false, clearPicture: true)
    }

    func backgrounded() {
        setVisible(false, clearPicture: true)
    }

    func foregrounded() {
        setVisible(true)
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
        setVisible(true, forceStart: true)
    }

    func tickForTesting(now: TimeInterval) {
        mutateArrival { $0.onTick(now: now) }
        applyPictureAccessibility()
    }

    private func setVisible(_ isVisible: Bool, clearPicture: Bool = false, forceStart: Bool = false) {
        if isVisible {
            visible = true
            if fatal { return }
            if !forceStart, startTask != nil || consumeTask != nil { return }
            requestStart()
        } else {
            visible = false
            requestStop(clearPicture: clearPicture)
        }
    }

    private func mutateArrival(_ body: (inout DesktopLiveArrivalMachine) -> Void) {
        var next = arrival
        body(&next)
        arrival = next
    }

    private func requestStart() {
        sessionGeneration += 1
        let generation = sessionGeneration
        let wait = pendingClose ?? retireCurrentSocket()
        pendingClose = nil
        startTask?.cancel()
        startTask = Task { [weak self] in
            await wait?.value
            guard let self, generation == self.sessionGeneration, self.visible, !self.fatal else {
                return
            }
            self.connect(generation: generation)
            self.startTask = nil
        }
    }

    private func requestStop(clearPicture: Bool) {
        sessionGeneration += 1
        startTask?.cancel()
        startTask = nil
        pendingClose = retireCurrentSocket()
        decoder.reset()
        if clearPicture {
            picture?.clearPicture()
            hasPicture = false
        }
    }

    /// Closes the current socket and returns the consume task so the next start
    /// can wait until Node has seen the close (one live stream per process).
    private func retireCurrentSocket() -> Task<Void, Never>? {
        reconnectTask?.cancel()
        reconnectTask = nil
        tickTask?.cancel()
        tickTask = nil
        let consume = consumeTask
        consumeTask = nil
        disconnect?()
        disconnect = nil
        return consume
    }

    private func connect(generation: Int) {
        if !hasPicture {
            mutateArrival { $0.resetConnecting() }
        }
        applyPictureAccessibility()
        guard let opening = open() else {
            mutateArrival { $0.onFatal(message: "Couldn't show the live remote screen.") }
            applyPictureAccessibility()
            return
        }
        connectCount += 1
        disconnect = opening.disconnect
        consumeTask = Task { [weak self] in
            for await event in opening.events {
                await self?.handle(event, generation: generation)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, generation == self.sessionGeneration else { return }
                self.mutateArrival { $0.onTick(now: self.clock()) }
                self.applyPictureAccessibility()
            }
        }
    }

    private func handle(
        _ event: DesktopLiveViewStreamClient.Event,
        generation: Int
    ) async {
        guard generation == sessionGeneration else { return }
        switch event {
        case .hello(let hello):
            reconnectAttempt = 0
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
            reconnectAttempt = 0
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
            scheduleReconnect(generation: generation)
        }
    }

    private func failClosed(code: Int?, reason: String?, serverMessage: String?) {
        fatal = true
        requestStop(clearPicture: false)
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

    private func scheduleReconnect(generation: Int) {
        guard generation == sessionGeneration, visible, !fatal else { return }
        reconnectAttempt += 1
        let delay = DesktopLiveReconnectPolicy.delay(attempt: reconnectAttempt)
        mutateArrival { $0.onDisconnect(now: self.clock(), willReconnect: true) }
        applyPictureAccessibility()
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                  generation == self.sessionGeneration,
                  self.visible,
                  !self.fatal,
                  !Task.isCancelled
            else { return }
            self.requestStart()
        }
    }

    private func applyPictureAccessibility() {
        let title = presentation.windowTitle ?? "Remote Screen"
        picture?.setAccessibilityChrome(label: title, value: statusValue)
    }

    private var statusValue: String {
        if let detail = presentation.detailText, presentation.statusText != "Live" {
            return "\(presentation.statusText), \(detail)"
        }
        return presentation.statusText
    }
}
