import Foundation
import MultipeerConnectivity
import Observation
import OSLog
import UIKit

private let nearbyPairingBrowserLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "NearbyPairingBrowser"
)

// Multipeer delegate callbacks arrive on private queues. This wrapper lets
// Objective-C peer values cross into a MainActor task; browser state stays
// isolated to NearbyPairingBrowser.
private struct NearbyPairingPeerReference: @unchecked Sendable {
    let peerID: MCPeerID
}

@MainActor
@Observable
final class NearbyPairingBrowser: NSObject {
    struct Candidate: Identifiable, Equatable {
        let peerID: MCPeerID
        let metadata: NearbyPairingDiscoveryMetadata

        var id: String {
            peerID.displayName
        }

        var displayName: String {
            metadata.displayName ?? peerID.displayName
        }

        var detailText: String? {
            metadata.version.map { "Oppi \($0)" }
        }
    }

    enum State: Equatable {
        case idle
        case discovering
        case waitingForApproval(String)
        case receivingInvite(String)
        case failed(String)

        var statusText: String? {
            switch self {
            case .idle:
                return nil
            case .discovering:
                return "Looking for nearby Macs…"
            case .waitingForApproval(let name):
                return "Waiting for \(name) to approve pairing…"
            case .receivingInvite(let name):
                return "Receiving invite from \(name)…"
            case .failed(let message):
                return message
            }
        }
    }

    var onInviteURL: ((URL) -> Void)?

    private(set) var candidates: [Candidate] = []
    private(set) var state: State = .idle

    private let localPeerID: MCPeerID
    private var browser: MCNearbyServiceBrowser?
    private var browserID: ObjectIdentifier?
    private var session: MCSession?
    private var sessionID: ObjectIdentifier?
    private var selectedPeerID: MCPeerID?

    override init() {
        localPeerID = MCPeerID(displayName: UIDevice.current.name)
        super.init()
    }

    func start() {
        guard browser == nil else { return }

        let session = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
        self.session = session

        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: NearbyPairingConstants.serviceType)
        browser.delegate = self
        self.browser = browser
        browserID = ObjectIdentifier(browser)
        sessionID = ObjectIdentifier(session)
        state = .discovering
        browser.startBrowsingForPeers()
        nearbyPairingBrowserLogger.info("Started nearby pairing browse")
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        browserID = nil

        session?.disconnect()
        session?.delegate = nil
        session = nil
        sessionID = nil

        candidates = []
        selectedPeerID = nil
        state = .idle
    }

    func invite(_ candidate: Candidate) {
        guard let browser, let session else { return }
        selectedPeerID = candidate.peerID
        state = .waitingForApproval(candidate.displayName)
        browser.invitePeer(candidate.peerID, to: session, withContext: nil, timeout: 15)
    }

    func retry() {
        stop()
        start()
    }

    private func upsertCandidate(peerID: MCPeerID, discoveryInfo: [String: String]?, browserID: ObjectIdentifier) {
        guard self.browserID == browserID else { return }

        let metadata = NearbyPairingDiscoveryMetadata(discoveryInfo: discoveryInfo)
        let candidate = Candidate(peerID: peerID, metadata: metadata)

        candidates.removeAll { $0.peerID == peerID }
        candidates.append(candidate)
        candidates.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func removeCandidate(peerID: MCPeerID, browserID: ObjectIdentifier) {
        guard self.browserID == browserID else { return }

        candidates.removeAll { $0.peerID == peerID }
        if selectedPeerID == peerID {
            selectedPeerID = nil
            if case .receivingInvite = state {
                state = .failed("Nearby pairing ended before an invite arrived. Try again or use the QR code.")
            }
        }
    }

    private func displayName(for peerID: MCPeerID) -> String {
        candidates.first(where: { $0.peerID == peerID })?.displayName ?? peerID.displayName
    }

    private func handleSessionStateChange(peerID: MCPeerID, stateValue: MCSessionState.RawValue, sessionID: ObjectIdentifier) {
        guard self.sessionID == sessionID,
              selectedPeerID == peerID,
              let sessionState = MCSessionState(rawValue: stateValue) else { return }

        switch sessionState {
        case .connecting:
            state = .waitingForApproval(displayName(for: peerID))
        case .connected:
            state = .receivingInvite(displayName(for: peerID))
        case .notConnected:
            if case .receivingInvite = state {
                state = .failed("Nearby pairing ended before an invite arrived. Try again or use the QR code.")
            }
        @unknown default:
            break
        }
    }

    private func handleBrowsingFailure(browserID: ObjectIdentifier) {
        guard self.browserID == browserID else { return }
        state = .failed("Nearby pairing is unavailable right now. Use the QR code or paste an invite link.")
    }

    private func handleInviteData(_ data: Data, from peerID: MCPeerID, sessionID: ObjectIdentifier) {
        guard self.sessionID == sessionID else { return }

        guard let url = NearbyPairingInviteCodec.decodeInviteURL(from: data) else {
            state = .failed("Received an invalid nearby invite. Try again or use the QR code.")
            session?.disconnect()
            session?.delegate = nil
            session = nil
            self.sessionID = nil
            return
        }

        nearbyPairingBrowserLogger.info("Received nearby invite from \(peerID.displayName, privacy: .public)")
        selectedPeerID = nil
        session?.disconnect()
        session?.delegate = nil
        session = nil
        self.sessionID = nil
        onInviteURL?(url)
    }
}

extension NearbyPairingBrowser: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let peer = NearbyPairingPeerReference(peerID: peerID)
        let browserID = ObjectIdentifier(browser)
        Task { @MainActor [weak self, peer, info, browserID] in
            self?.upsertCandidate(peerID: peer.peerID, discoveryInfo: info, browserID: browserID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let peer = NearbyPairingPeerReference(peerID: peerID)
        let browserID = ObjectIdentifier(browser)
        Task { @MainActor [weak self, peer, browserID] in
            self?.removeCandidate(peerID: peer.peerID, browserID: browserID)
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: any Error
    ) {
        nearbyPairingBrowserLogger.error("Nearby browse failed: \(error.localizedDescription, privacy: .public)")
        let browserID = ObjectIdentifier(browser)
        Task { @MainActor [weak self, browserID] in
            self?.handleBrowsingFailure(browserID: browserID)
        }
    }
}

extension NearbyPairingBrowser: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peer = NearbyPairingPeerReference(peerID: peerID)
        let stateValue = state.rawValue
        let sessionID = ObjectIdentifier(session)
        Task { @MainActor [weak self, peer, stateValue, sessionID] in
            self?.handleSessionStateChange(peerID: peer.peerID, stateValue: stateValue, sessionID: sessionID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let peer = NearbyPairingPeerReference(peerID: peerID)
        let sessionID = ObjectIdentifier(session)
        Task { @MainActor [weak self, peer, data, sessionID] in
            self?.handleInviteData(data, from: peer.peerID, sessionID: sessionID)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }
}
