import Foundation
import MultipeerConnectivity
import Observation
import OSLog

private let nearbyPairingAdvertiserLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "NearbyPairingAdvertiser"
)

@MainActor
@Observable
final class NearbyPairingAdvertiser: NSObject {
    struct ApprovalRequest: Identifiable, Equatable {
        let peerName: String
        let id: String
    }

    enum State: Equatable {
        case inactive
        case advertising
        case awaitingApproval(String)
        case connecting(String)
        case sendingInvite(String)
        case failed(String)

        var statusText: String {
            switch self {
            case .inactive:
                return "Nearby pairing is off."
            case .advertising:
                return "Nearby pairing is ready while this screen stays open."
            case .awaitingApproval(let peerName):
                return "Approve pairing for \(peerName) on this Mac."
            case .connecting(let peerName):
                return "Connecting securely to \(peerName)…"
            case .sendingInvite(let peerName):
                return "Sending a fresh invite to \(peerName)…"
            case .failed(let message):
                return message
            }
        }
    }

    private struct PendingInvitation {
        let peerID: MCPeerID
        let invitationHandler: (Bool, MCSession?) -> Void
    }

    private(set) var approvalRequest: ApprovalRequest?
    private(set) var state: State = .inactive

    private let localPeerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    private var session: MCSession?
    private var connectedPeerID: MCPeerID?
    private var pendingInvitation: PendingInvitation?

    override init() {
        localPeerID = MCPeerID(displayName: Host.current().localizedName ?? "Oppi Mac")
        super.init()
    }

    func start() {
        guard advertiser == nil else { return }

        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: discoveryInfo(),
            serviceType: NearbyPairingConstants.serviceType
        )
        advertiser.delegate = self
        self.advertiser = advertiser
        advertiser.startAdvertisingPeer()
        state = .advertising
        nearbyPairingAdvertiserLogger.info("Started nearby pairing advertiser")
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil

        session?.disconnect()
        session?.delegate = nil
        session = nil

        approvalRequest = nil
        pendingInvitation = nil
        connectedPeerID = nil
        state = .inactive
    }

    func approvePendingInvitation() {
        guard let pendingInvitation else { return }
        let session = makeSession()

        approvalRequest = nil
        self.pendingInvitation = nil
        connectedPeerID = pendingInvitation.peerID
        state = .connecting(pendingInvitation.peerID.displayName)
        pendingInvitation.invitationHandler(true, session)
    }

    func rejectPendingInvitation() {
        guard let pendingInvitation else { return }
        approvalRequest = nil
        self.pendingInvitation = nil
        pendingInvitation.invitationHandler(false, nil)
        state = .advertising
    }

    private func makeSession() -> MCSession {
        if let session {
            session.disconnect()
            session.delegate = nil
        }

        let session = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
        self.session = session
        return session
    }

    private func discoveryInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let hostLabel = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !hostLabel.isEmpty {
            info[NearbyPairingConstants.DiscoveryKey.hostLabel] = String(hostLabel.prefix(63))
        }
        if let version = Bundle.main.nearbyPairingVersionString?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            info[NearbyPairingConstants.DiscoveryKey.version] = String(version.prefix(24))
        }
        return info
    }

    private func handleInvitation(from peerID: MCPeerID, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        guard pendingInvitation == nil, approvalRequest == nil, connectedPeerID == nil else {
            invitationHandler(false, nil)
            return
        }

        pendingInvitation = PendingInvitation(peerID: peerID, invitationHandler: invitationHandler)
        approvalRequest = ApprovalRequest(peerName: peerID.displayName, id: peerID.displayName)
        state = .awaitingApproval(peerID.displayName)
    }

    private func sendInvite(to peerID: MCPeerID) {
        guard let session, session.connectedPeers.contains(peerID) else {
            state = .failed("Nearby pairing disconnected before the invite could be sent.")
            connectedPeerID = nil
            return
        }

        state = .sendingInvite(peerID.displayName)

        Task {
            do {
                let invite = try await PairingInviteService.generate()
                guard let inviteURL = invite.inviteURL else {
                    throw NearbyPairingAdvertiserError.missingInviteURL
                }
                let payload = try NearbyPairingInviteCodec.encode(inviteURL: inviteURL)
                try session.send(payload, toPeers: [peerID], with: .reliable)
                nearbyPairingAdvertiserLogger.info("Sent nearby invite to \(peerID.displayName, privacy: .public)")
                session.disconnect()
                connectedPeerID = nil
                state = .advertising
            } catch {
                nearbyPairingAdvertiserLogger.error("Failed to send nearby invite: \(error.localizedDescription, privacy: .public)")
                session.disconnect()
                connectedPeerID = nil
                state = .failed(error.localizedDescription)
            }
        }
    }
}

extension NearbyPairingAdvertiser: @preconcurrency MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        handleInvitation(from: peerID, invitationHandler: invitationHandler)
    }

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: any Error
    ) {
        nearbyPairingAdvertiserLogger.error("Nearby advertising failed: \(error.localizedDescription, privacy: .public)")
        state = .failed("Nearby pairing is unavailable right now. Keep using the QR code or copy the invite link.")
    }
}

extension NearbyPairingAdvertiser: @preconcurrency MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard connectedPeerID == peerID else { return }

        switch state {
        case .connected:
            sendInvite(to: peerID)
        case .connecting:
            self.state = .connecting(peerID.displayName)
        case .notConnected:
            connectedPeerID = nil
            if case .sendingInvite = self.state {
                self.state = .failed("Nearby pairing disconnected before the invite could be sent.")
            } else if case .connecting = self.state {
                self.state = .advertising
            }
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}

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

enum NearbyPairingAdvertiserError: LocalizedError {
    case missingInviteURL

    var errorDescription: String? {
        switch self {
        case .missingInviteURL:
            return "Pairing invite did not include a usable invite link."
        }
    }
}
