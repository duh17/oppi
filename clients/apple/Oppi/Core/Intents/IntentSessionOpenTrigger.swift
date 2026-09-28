import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "IntentSessionOpenTrigger")

/// Handoff from Siri start-session into the live chat after `appStartupComplete`.
///
/// Latest issued receipt wins. Older async completions must not override a newer
/// request. Consume once; do not suppress a newer request because a sheet is up.
@MainActor @Observable
final class IntentSessionOpenTrigger {
    static let shared = IntentSessionOpenTrigger()

    struct Receipt: Equatable, Sendable {
        var requestID: Int
        var serverId: String
        var sessionId: String
        var workspaceId: String?
        var unsentPrompt: String?
        var session: Session?
    }

    private struct PersistedReceipt: Codable, Equatable {
        var requestID: Int
        var serverId: String
        var sessionId: String
        var workspaceId: String?
        var unsentPrompt: String?
    }

    private(set) var requestID: Int = 0

    private let defaults: UserDefaults
    private let issuedRequestIDKey: String
    private let lastAcceptedRequestIDKey: String
    private let pendingKey: String
    private var pending: Receipt?
    private var lastAcceptedRequestID: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let prefix = "\(AppIdentifiers.subsystem).intentSessionOpen"
        issuedRequestIDKey = "\(prefix).issuedRequestID"
        lastAcceptedRequestIDKey = "\(prefix).lastAcceptedRequestID"
        pendingKey = "\(prefix).pending"
        lastAcceptedRequestID = defaults.integer(forKey: lastAcceptedRequestIDKey)
        if let persisted = Self.loadPersisted(from: defaults, key: pendingKey) {
            pending = Receipt(
                requestID: persisted.requestID,
                serverId: persisted.serverId,
                sessionId: persisted.sessionId,
                workspaceId: persisted.workspaceId,
                unsentPrompt: persisted.unsentPrompt,
                session: nil
            )
            requestID = persisted.requestID
            lastAcceptedRequestID = max(lastAcceptedRequestID, persisted.requestID)
            if persisted.requestID > defaults.integer(forKey: issuedRequestIDKey) {
                defaults.set(persisted.requestID, forKey: issuedRequestIDKey)
            }
        }
    }

    func issueRequestID() -> Int {
        let next = defaults.integer(forKey: issuedRequestIDKey) + 1
        defaults.set(next, forKey: issuedRequestIDKey)
        return next
    }

    func enqueue(_ receipt: Receipt) {
        let acceptedID = max(pending?.requestID ?? 0, lastAcceptedRequestID)
        guard receipt.requestID >= acceptedID else {
            logger.debug(
                "Ignoring stale start-session handoff \(receipt.requestID, privacy: .public) after \(acceptedID, privacy: .public)"
            )
            return
        }
        pending = receipt
        requestID = receipt.requestID
        rememberAccepted(receipt.requestID)
        persist(receipt)
        logger.notice(
            "Start-session handoff queued request=\(receipt.requestID, privacy: .public) session=\(receipt.sessionId, privacy: .public)"
        )
    }

    func consume(startupComplete: Bool) -> Receipt? {
        guard startupComplete else { return nil }
        guard let receipt = pending else { return nil }
        pending = nil
        rememberAccepted(receipt.requestID)
        persist(nil)
        logger.notice(
            "Start-session handoff consumed request=\(receipt.requestID, privacy: .public) session=\(receipt.sessionId, privacy: .public)"
        )
        return receipt
    }

    private func rememberAccepted(_ requestID: Int) {
        lastAcceptedRequestID = max(lastAcceptedRequestID, requestID)
        defaults.set(lastAcceptedRequestID, forKey: lastAcceptedRequestIDKey)
    }

    private func persist(_ receipt: Receipt?) {
        guard let receipt else {
            defaults.removeObject(forKey: pendingKey)
            return
        }
        let persisted = PersistedReceipt(
            requestID: receipt.requestID,
            serverId: receipt.serverId,
            sessionId: receipt.sessionId,
            workspaceId: receipt.workspaceId,
            unsentPrompt: receipt.unsentPrompt
        )
        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: pendingKey)
        }
    }

    private static func loadPersisted(from defaults: UserDefaults, key: String) -> PersistedReceipt? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedReceipt.self, from: data)
    }
}
