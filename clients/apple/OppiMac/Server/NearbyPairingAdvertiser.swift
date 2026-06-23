import Foundation
import MultipeerConnectivity
import Observation
import OSLog

private let nearbyPairingAdvertiserLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "NearbyPairingAdvertiser"
)

// Multipeer delegate callbacks arrive on private queues. These wrappers let
// Objective-C callback values cross into a MainActor task; pairing state stays
// isolated to NearbyPairingAdvertiser.
private struct NearbyPairingPeerReference: @unchecked Sendable {
    let peerID: MCPeerID
}

private struct NearbyPairingInvitationHandler: @unchecked Sendable {
    let call: (Bool, MCSession?) -> Void
}

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
        let invitationHandler: NearbyPairingInvitationHandler
    }

    private(set) var approvalRequest: ApprovalRequest?
    private(set) var state: State = .inactive

    private let localPeerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    private var advertiserID: ObjectIdentifier?
    private var session: MCSession?
    private var sessionID: ObjectIdentifier?
    private var connectedPeerID: MCPeerID?
    private var pendingInvitation: PendingInvitation?
    private var inviteCleanupTask: Task<Void, Never>?

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
        advertiserID = ObjectIdentifier(advertiser)
        advertiser.startAdvertisingPeer()
        state = .advertising
        nearbyPairingAdvertiserLogger.info("Started nearby pairing advertiser")
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        advertiserID = nil

        inviteCleanupTask?.cancel()
        inviteCleanupTask = nil

        session?.disconnect()
        session?.delegate = nil
        session = nil
        sessionID = nil

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
        pendingInvitation.invitationHandler.call(true, session)
    }

    func rejectPendingInvitation() {
        guard let pendingInvitation else { return }
        approvalRequest = nil
        self.pendingInvitation = nil
        pendingInvitation.invitationHandler.call(false, nil)
        state = .advertising
    }

    private func makeSession() -> MCSession {
        inviteCleanupTask?.cancel()
        inviteCleanupTask = nil

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
        sessionID = ObjectIdentifier(session)
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

    private func handleInvitation(
        from peerID: MCPeerID,
        advertiserID: ObjectIdentifier,
        invitationHandler: NearbyPairingInvitationHandler
    ) {
        guard self.advertiserID == advertiserID else {
            invitationHandler.call(false, nil)
            return
        }

        guard pendingInvitation == nil, approvalRequest == nil, connectedPeerID == nil else {
            invitationHandler.call(false, nil)
            return
        }

        nearbyPairingAdvertiserLogger.info("Received nearby pairing invitation from \(peerID.displayName, privacy: .public)")
        pendingInvitation = PendingInvitation(peerID: peerID, invitationHandler: invitationHandler)
        approvalRequest = ApprovalRequest(peerName: peerID.displayName, id: peerID.displayName)
        state = .awaitingApproval(peerID.displayName)
    }

    private func sendInvite(to peerID: MCPeerID) {
        guard let session else {
            state = .failed("Nearby pairing disconnected before the invite could be sent.")
            connectedPeerID = nil
            return
        }

        state = .sendingInvite(peerID.displayName)
        let currentSessionID = ObjectIdentifier(session)

        Task {
            do {
                let invite = try await PairingInviteService.generate()
                guard self.sessionID == currentSessionID,
                      connectedPeerID == peerID else { return }
                guard let inviteURL = invite.inviteURL else {
                    throw NearbyPairingAdvertiserError.missingInviteURL
                }
                let payload = try NearbyPairingInviteCodec.encode(inviteURL: inviteURL)
                try session.send(payload, toPeers: [peerID], with: .reliable)
                nearbyPairingAdvertiserLogger.info("Sent nearby invite to \(peerID.displayName, privacy: .public)")
                inviteCleanupTask?.cancel()
                inviteCleanupTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.finishInviteDelivery(sessionID: currentSessionID, peerID: peerID)
                }
            } catch {
                nearbyPairingAdvertiserLogger.error("Failed to send nearby invite: \(error.localizedDescription, privacy: .public)")
                session.disconnect()
                session.delegate = nil
                self.session = nil
                sessionID = nil
                connectedPeerID = nil
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func finishInviteDelivery(sessionID: ObjectIdentifier, peerID: MCPeerID) {
        guard self.sessionID == sessionID,
              connectedPeerID == peerID else { return }
        inviteCleanupTask?.cancel()
        inviteCleanupTask = nil
        session?.disconnect()
        session?.delegate = nil
        session = nil
        self.sessionID = nil
        connectedPeerID = nil
        state = .advertising
    }

    private func handleInviteAck(data: Data, from peerID: MCPeerID, sessionID: ObjectIdentifier) {
        guard NearbyPairingInviteCodec.isInviteReceivedAck(data),
              self.sessionID == sessionID,
              connectedPeerID == peerID else { return }
        nearbyPairingAdvertiserLogger.info("Received nearby invite acknowledgement from \(peerID.displayName, privacy: .public)")
        finishInviteDelivery(sessionID: sessionID, peerID: peerID)
    }

    private func handleAdvertisingFailure(advertiserID: ObjectIdentifier) {
        guard self.advertiserID == advertiserID else { return }
        state = .failed("Nearby pairing is unavailable right now. Keep using the QR code or copy the invite link.")
    }

    private func handleSessionStateChange(peerID: MCPeerID, stateValue: MCSessionState.RawValue, sessionID: ObjectIdentifier) {
        guard self.sessionID == sessionID,
              connectedPeerID == peerID,
              let sessionState = MCSessionState(rawValue: stateValue) else { return }

        switch sessionState {
        case .connected:
            nearbyPairingAdvertiserLogger.info("Nearby pairing connected to \(peerID.displayName, privacy: .public)")
            sendInvite(to: peerID)
        case .connecting:
            state = .connecting(peerID.displayName)
        case .notConnected:
            nearbyPairingAdvertiserLogger.info("Nearby pairing disconnected from \(peerID.displayName, privacy: .public)")
            connectedPeerID = nil
            inviteCleanupTask?.cancel()
            inviteCleanupTask = nil
            session?.delegate = nil
            session = nil
            self.sessionID = nil
            if case .connecting = state {
                state = .advertising
            } else if case .sendingInvite = state {
                state = .advertising
            }
        @unknown default:
            break
        }
    }
}

extension NearbyPairingAdvertiser: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let peer = NearbyPairingPeerReference(peerID: peerID)
        let advertiserID = ObjectIdentifier(advertiser)
        let handler = NearbyPairingInvitationHandler(call: invitationHandler)
        Task { @MainActor [weak self, peer, advertiserID, handler] in
            guard let self else {
                handler.call(false, nil)
                return
            }
            self.handleInvitation(
                from: peer.peerID,
                advertiserID: advertiserID,
                invitationHandler: handler
            )
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: any Error
    ) {
        nearbyPairingAdvertiserLogger.error("Nearby advertising failed: \(error.localizedDescription, privacy: .public)")
        let advertiserID = ObjectIdentifier(advertiser)
        Task { @MainActor [weak self, advertiserID] in
            self?.handleAdvertisingFailure(advertiserID: advertiserID)
        }
    }
}

extension NearbyPairingAdvertiser: MCSessionDelegate {
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
            self?.handleInviteAck(data: data, from: peer.peerID, sessionID: sessionID)
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

enum NearbyPairingAdvertiserError: LocalizedError {
    case missingInviteURL

    var errorDescription: String? {
        switch self {
        case .missingInviteURL:
            return "Pairing invite did not include a usable invite link."
        }
    }
}
