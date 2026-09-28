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
    }

    private struct LegacyPrompt: Decodable {
        var unsentPrompt: String?
    }

    private(set) var requestID: Int = 0

    private let defaults: UserDefaults
    private let issuedRequestIDKey: String
    private let lastAcceptedRequestIDKey: String
    private let pendingKey: String
    private let promptFileURL: URL
    private var pending: Receipt?
    /// The protected prompt file existed but could not be read at init (device locked).
    /// `consume` retries the read and keeps the file until it succeeds.
    private var pendingPromptUnreadable = false
    private var lastAcceptedRequestID: Int

    init(
        defaults: UserDefaults = .standard,
        promptFileURL: URL = ComposerDraftStore.intentSessionPromptFileURL()
    ) {
        self.defaults = defaults
        self.promptFileURL = promptFileURL
        let prefix = "\(AppIdentifiers.subsystem).intentSessionOpen"
        issuedRequestIDKey = "\(prefix).issuedRequestID"
        lastAcceptedRequestIDKey = "\(prefix).lastAcceptedRequestID"
        pendingKey = "\(prefix).pending"
        lastAcceptedRequestID = defaults.integer(forKey: lastAcceptedRequestIDKey)
        if let data = defaults.data(forKey: pendingKey),
           let persisted = try? JSONDecoder().decode(PersistedReceipt.self, from: data) {
            let legacy = try? JSONDecoder().decode(LegacyPrompt.self, from: data)
            var migrated = legacy != nil
            if let text = legacy?.unsentPrompt {
                if let workspaceId = persisted.workspaceId,
                   let key = ComposerDraftKey(
                       serverID: persisted.serverId,
                       workspaceID: workspaceId,
                       sessionID: persisted.sessionId
                   ) {
                    do {
                        try ComposerDraftStore.saveIntentSessionPrompt(
                            text, requestID: persisted.requestID, for: key, at: promptFileURL
                        )
                    } catch {
                        migrated = false
                        logger.error("Could not protect legacy start-session prompt: \(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    migrated = false
                }
            }
            var prompt = legacy?.unsentPrompt
            if prompt == nil {
                do {
                    prompt = try Self.loadPrompt(for: persisted, at: promptFileURL)
                } catch {
                    pendingPromptUnreadable = true
                    logger.error("Could not read start-session prompt yet: \(error.localizedDescription, privacy: .public)")
                }
            }
            pending = Receipt(
                requestID: persisted.requestID,
                serverId: persisted.serverId,
                sessionId: persisted.sessionId,
                workspaceId: persisted.workspaceId,
                unsentPrompt: prompt,
                session: nil
            )
            requestID = persisted.requestID
            lastAcceptedRequestID = max(lastAcceptedRequestID, persisted.requestID)
            if persisted.requestID > defaults.integer(forKey: issuedRequestIDKey) {
                defaults.set(persisted.requestID, forKey: issuedRequestIDKey)
            }
            // Do not discard the only durable prompt copy if the protected write failed.
            if migrated, let data = try? JSONEncoder().encode(persisted) {
                defaults.set(data, forKey: pendingKey)
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
        if let prompt = receipt.unsentPrompt {
            guard let key = Self.draftKey(for: receipt) else { return }
            do {
                try ComposerDraftStore.saveIntentSessionPrompt(
                    prompt, requestID: receipt.requestID, for: key, at: promptFileURL
                )
            } catch {
                logger.error("Could not protect start-session prompt: \(error.localizedDescription, privacy: .public)")
                return
            }
        } else {
            ComposerDraftStore.clearIntentSessionPrompt(at: promptFileURL)
        }
        pending = receipt
        pendingPromptUnreadable = false
        requestID = receipt.requestID
        rememberAccepted(receipt.requestID)
        persist(receipt)
        logger.notice(
            "Start-session handoff queued request=\(receipt.requestID, privacy: .public) session=\(receipt.sessionId, privacy: .public)"
        )
    }

    func consume(startupComplete: Bool) -> Receipt? {
        guard startupComplete else { return nil }
        guard var receipt = pending else { return nil }
        if pendingPromptUnreadable {
            // Retry now that the app is in the foreground. Never delete the only
            // copy of the prompt, and keep the handoff pending until it reads.
            guard let key = Self.draftKey(for: receipt) else { return nil }
            do {
                receipt.unsentPrompt = try ComposerDraftStore.intentSessionPrompt(
                    requestID: receipt.requestID, for: key, at: promptFileURL
                )
            } catch {
                logger.error("Start-session prompt still unreadable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            pendingPromptUnreadable = false
        }
        pending = nil
        rememberAccepted(receipt.requestID)
        persist(nil)
        ComposerDraftStore.clearIntentSessionPrompt(at: promptFileURL)
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
            workspaceId: receipt.workspaceId
        )
        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: pendingKey)
        }
    }

    private static func draftKey(for receipt: Receipt) -> ComposerDraftKey? {
        guard let workspaceId = receipt.workspaceId else { return nil }
        return ComposerDraftKey(
            serverID: receipt.serverId, workspaceID: workspaceId, sessionID: receipt.sessionId
        )
    }

    private static func loadPrompt(for receipt: PersistedReceipt, at url: URL) throws -> String? {
        guard let workspaceId = receipt.workspaceId,
              let key = ComposerDraftKey(
                  serverID: receipt.serverId, workspaceID: workspaceId, sessionID: receipt.sessionId
              ) else { return nil }
        return try ComposerDraftStore.intentSessionPrompt(requestID: receipt.requestID, for: key, at: url)
    }

}
