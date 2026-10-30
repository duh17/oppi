#if DEBUG
import UIKit

/// What the E2E tests read of the active connection: one static text per fact,
/// its identifier `e2e.*` and its accessibility label the value, refreshed
/// every 100 ms while the view is in a window. Only an E2E launch shows it
/// (`PI_E2E_INVITE_URL`, or `OPPI_E2E_DIAGNOSTICS=1`).
///
/// The view is 1 pt square at 2% opacity and takes no touches: invisible, but
/// not hidden, so the labels stay in the accessibility tree (UIKit drops an
/// element from it at alpha 0, and a view below 0.01 from hit testing; the
/// alpha is a Float, so 0.01 itself rounds under that threshold).
@MainActor
final class E2EDiagnosticsView: UIView {
    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["PI_E2E_INVITE_URL"] != nil || environment["OPPI_E2E_DIAGNOSTICS"] == "1"
    }

    private let coordinator: ConnectionCoordinator
    private let stack = UIStackView()
    private var labels: [String: UILabel] = [:]
    private var timer: Timer?

    init(coordinator: ConnectionCoordinator) {
        self.coordinator = coordinator
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        alpha = 0.02
        isUserInteractionEnabled = false
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        refresh()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Every fact the tests read, in the order they appear.
    private func facts(of connection: ServerConnection) -> [(id: String, value: String)] {
        [
            ("e2e.ws.status", wsStatus(connection)),
            ("e2e.ws.connectionID", String(connection.wsClient?.diagnosticConnectionID ?? 0)),
            ("e2e.transport.path", connection.transportPath.rawValue),
            ("e2e.stream.requiredCapabilities", connection.requiredSplitStreamCapabilitiesStatusForDiagnostics),
            ("e2e.stream.sessionEndpoint", connection.focusedSessionStreamEndpointKind),
            ("e2e.ws.focusedSession", connection.focusedSessionId ?? "none"),
            ("e2e.ws.desiredSubscriptions", desiredSubscriptions(connection)),
            ("e2e.ws.ackedSubscriptions", ackedSubscriptions(connection)),
            ("e2e.extension.dialog", connection.activeExtensionDialog?.id ?? "none"),
            ("e2e.extension.dialogs", connection.pendingExtensionDialogRequests.map(\.id).joined(separator: ",")),
            ("e2e.root.modals", rootModalsSummary()),
            ("e2e.audio.liveTransportSession", connection.audioPlayer.activeLiveTransportSessionID ?? "none"),
            ("e2e.lifecycle", E2ELifecycleDiagnostics.shared.accessibilityValue),
        ]
    }

    /// The window root's dialog slot: what it holds and what UIKit presented.
    private func rootModalsSummary() -> String {
        (window?.rootViewController as? AppRootViewController)?.modalDiagnostics ?? "missing"
    }

    private func refresh() {
        for (id, value) in facts(of: coordinator.activeConnection) {
            let label = labels[id] ?? makeLabel(id)
            if label.text != value {
                label.text = value
                label.accessibilityLabel = value
            }
        }
    }

    private func makeLabel(_ id: String) -> UILabel {
        let label = UILabel()
        label.font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
        label.numberOfLines = 1
        label.accessibilityIdentifier = id
        stack.addArrangedSubview(label)
        labels[id] = label
        return label
    }

    private func wsStatus(_ connection: ServerConnection) -> String {
        switch connection.wsClient?.status {
        case .connected: "connected"
        case .connecting: "connecting"
        case .disconnected: "disconnected"
        case .reconnecting(let attempt): "reconnecting:\(attempt)"
        case nil: "none"
        }
    }

    private func desiredSubscriptions(_ connection: ServerConnection) -> String {
        guard let focusedSessionId = connection.focusedSessionId else { return "none" }
        return "\(focusedSessionId):full"
    }

    private func ackedSubscriptions(_ connection: ServerConnection) -> String {
        guard let focusedSessionId = connection.focusedSessionId else { return "none" }
        if connection.sessionStreamCoordinator.hasFullSubscription(sessionId: focusedSessionId) {
            return "\(focusedSessionId):full"
        }
        let state: String = switch connection.sessionStreamCoordinator.state {
        case .idle: "idle"
        case .connectingTransport: "connecting"
        case .queueSync: "queueSync"
        case .streaming: "streaming"
        case .resubscribing: "resubscribing"
        }
        return "\(focusedSessionId):\(state)"
    }
}
#endif
