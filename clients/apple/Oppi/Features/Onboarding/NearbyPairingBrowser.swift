import Foundation
import MultipeerConnectivity
import Observation
import OSLog
import UIKit

private let nearbyPairingBrowserLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "NearbyPairingBrowser"
)

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
    private var session: MCSession?
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
        state = .discovering
        browser.startBrowsingForPeers()
        nearbyPairingBrowserLogger.info("Started nearby pairing browse")
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil

        session?.disconnect()
        session?.delegate = nil
        session = nil

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

    private func upsertCandidate(peerID: MCPeerID, discoveryInfo: [String: String]?) {
        let metadata = NearbyPairingDiscoveryMetadata(discoveryInfo: discoveryInfo)
        let candidate = Candidate(peerID: peerID, metadata: metadata)

        candidates.removeAll { $0.peerID == peerID }
        candidates.append(candidate)
        candidates.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func removeCandidate(peerID: MCPeerID) {
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
}

extension NearbyPairingBrowser: @preconcurrency MCNearbyServiceBrowserDelegate {
    func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        upsertCandidate(peerID: peerID, discoveryInfo: info)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        removeCandidate(peerID: peerID)
    }

    func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: any Error
    ) {
        nearbyPairingBrowserLogger.error("Nearby browse failed: \(error.localizedDescription, privacy: .public)")
        state = .failed("Nearby pairing is unavailable right now. Use the QR code or paste an invite link.")
    }
}

extension NearbyPairingBrowser: @preconcurrency MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard selectedPeerID == peerID else { return }

        switch state {
        case .connecting:
            self.state = .waitingForApproval(displayName(for: peerID))
        case .connected:
            self.state = .receivingInvite(displayName(for: peerID))
        case .notConnected:
            if case .receivingInvite = self.state {
                self.state = .failed("Nearby pairing ended before an invite arrived. Try again or use the QR code.")
            }
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let url = NearbyPairingInviteCodec.decodeInviteURL(from: data) else {
            state = .failed("Received an invalid nearby invite. Try again or use the QR code.")
            session.disconnect()
            return
        }

        nearbyPairingBrowserLogger.info("Received nearby invite from \(peerID.displayName, privacy: .public)")
        selectedPeerID = nil
        session.disconnect()
        onInviteURL?(url)
    }

    func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {}

    func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }
}
