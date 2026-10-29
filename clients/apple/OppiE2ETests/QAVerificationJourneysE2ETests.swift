import Foundation
import XCTest

/// Paired-server journeys for the reduced deterministic QA core.
/// Composer-send/stop is not the queue claim. Terminal mirror is not exercised.
/// A leftover version-mismatch banner is a required product failure, not a pass.
@MainActor
final class QAVerificationJourneysE2ETests: E2ETestCase {
    override var e2eStartsInAutoCreatedChat: Bool { true }
    override var e2eRequiresFreshLaunch: Bool { true }

    private let chatInput = QAVerificationExecutor.Target.id("chat.input", role: .textView)
    private let chatSend = QAVerificationExecutor.Target.id("chat.send", role: .button)
    private let queuePill = QAVerificationExecutor.Target.id(
        "extension-strip-aboveEditor-pill-message-queue",
        role: .button
    )

    func testPairedComposerReadyJourney() throws {
        let receipt = QAVerificationReceipt(
            journeyId: "composer-ready",
            subject: "Unique chat.input accepts synthetic text and unique chat.send becomes enabled",
            driver: "strict",
            requestedStepIds: ["wait-input", "type-marker", "wait-send"],
            requiredAssertionIds: ["composer-accepts-text-and-send-enabled"],
            mockedBoundaries: []
        )
        let executor = QAVerificationExecutor(app: app, receipt: receipt)
        defer { writeReceipt(receipt) }

        createAndEnterSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()

        let marker = "QA_COMPOSER_READY"
        try executor.waitHittable(chatInput, timeout: 20, stepId: "wait-input")
        try executor.type(
            chatInput,
            text: marker,
            timeout: 8,
            stepId: "type-marker",
            confirming: .hittable(chatSend)
        )
        try executor.waitHittable(chatSend, timeout: 8, stepId: "wait-send")
        let observed = try executor.readValue(chatInput)
        receipt.recordAssertion(
            name: "composer-accepts-text-and-send-enabled",
            status: observed == marker ? .pass : .fail,
            expected: marker,
            observed: observed
        )
    }

    func testQueueRemoveSteeringItem() throws {
        let receipt = QAVerificationReceipt(
            journeyId: "queue-remove-steering",
            subject: "One synthetic steering item is removed; UI plus one correlated get_queue command_result",
            driver: "strict",
            requestedStepIds: [
                "wait-queue-pill",
                "tap-queue-pill",
                "wait-remove",
                "tap-remove",
                "wait-remove-gone",
            ],
            requiredAssertionIds: [
                "authoritative-get-queue",
                "item-absent-queue",
                "queue-version-advanced",
                "ui-item-gone",
                "queue-update-error-banner",
            ],
            mockedBoundaries: []
        )
        receipt.semanticsGaps.append(
            "Busy-turn seed may race the live model; a leftover version-mismatch banner is a product FAIL."
        )
        let executor = QAVerificationExecutor(app: app, receipt: receipt)
        defer { writeReceipt(receipt) }

        createAndEnterSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let workspaceId = try e2eWorkspaceId()
        let marker = "QA_QUEUE_REMOVE_\(sessionId.prefix(8))"
        let before: AuthoritativeQueue
        let beforeItem: QueueItemSnapshot
        do {
            try seedBusySteeringQueue(
                workspaceId: workspaceId,
                sessionId: sessionId,
                marker: marker
            )
            before = try authoritativeQueue(workspaceId: workspaceId, sessionId: sessionId)
            beforeItem = try uniqueSteeringItem(before, message: marker)
            guard before.followUp.isEmpty else {
                throw QAVerificationFailure.postcondition("Follow-up was not empty before the UI removal")
            }
        } catch let error as QAVerificationFailure {
            receipt.recordFailure(error)
            throw error
        }

        // The remove control's id ends in the queue item's id.
        let remove = QAVerificationExecutor.Target.id("chat.messageQueue.remove.\(beforeItem.id)", role: .button)

        try executor.waitHittable(queuePill, timeout: 20, stepId: "wait-queue-pill")
        try executor.tap(
            queuePill,
            timeout: 8,
            stepId: "tap-queue-pill",
            confirming: .exists(remove)
        )
        try executor.waitHittable(remove, timeout: 8, stepId: "wait-remove")
        try executor.tap(
            remove,
            timeout: 8,
            stepId: "tap-remove",
            confirming: .gone(remove)
        )
        try executor.waitGone(remove, timeout: 8, stepId: "wait-remove-gone")

        let after: AuthoritativeQueue
        do {
            after = try authoritativeQueue(workspaceId: workspaceId, sessionId: sessionId)
            receipt.recordAssertion(
                name: "authoritative-get-queue",
                status: .pass,
                expected: "exactly one successful get_queue command_result for a fresh requestId",
                observed: "requestId=\(after.requestId)"
            )
        } catch {
            receipt.recordAssertion(
                name: "authoritative-get-queue",
                required: true,
                status: .unknown,
                expected: "exactly one successful get_queue command_result for a fresh requestId",
                observed: "\(error)"
            )
            throw error
        }

        let remaining = (after.steering + after.followUp).filter { $0.id == beforeItem.id }
        receipt.recordAssertion(
            name: "item-absent-queue",
            status: remaining.isEmpty ? .pass : .fail,
            expected: "id \(beforeItem.id) absent from steering and follow-up",
            observed: "steering=\(after.steering.map(\.id)) followUp=\(after.followUp.map(\.id))"
        )
        receipt.recordAssertion(
            name: "queue-version-advanced",
            status: after.version > before.version ? .pass : .fail,
            expected: "version > \(before.version)",
            observed: "\(after.version)"
        )
        receipt.recordAssertion(
            name: "ui-item-gone",
            status: .pass,
            expected: "the item's remove control is gone",
            observed: "\(remove) gone"
        )
        let errorQuery = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@",
                "Queue changed before your edit was saved. Review the latest queue and try again."
            )
        )
        var errorBanners = 0
        let errorCount = min(errorQuery.count, 8)
        for index in 0..<errorCount where errorQuery.element(boundBy: index).exists {
            errorBanners += 1
        }
        receipt.recordAssertion(
            name: "queue-update-error-banner",
            required: true,
            status: errorBanners == 0 ? .pass : .fail,
            expected: "no exact queue-update error banner",
            observed: "matchingBanners=\(errorBanners)"
        )
    }

    private func seedBusySteeringQueue(
        workspaceId: String,
        sessionId: String,
        marker: String
    ) throws {
        _ = try sessionCommand(
            workspaceId: workspaceId,
            sessionId: sessionId,
            body: [
                "type": "prompt",
                "message": "Write a detailed 500 word essay about the history of computing. Do not stop early.",
            ],
            command: "prompt"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["chat.stop"].waitForExistence(timeout: 60),
            "Busy turn did not start; chat.stop never appeared"
        )
        _ = try sessionCommand(
            workspaceId: workspaceId,
            sessionId: sessionId,
            body: [
                "type": "steer",
                "message": marker,
            ],
            command: "steer"
        )
        if !app.descendants(matching: .any)["chat.stop"].exists {
            throw QAVerificationFailure.unknown("Busy turn ended before the queue removal; fixture could not hold streaming")
        }
    }

    private func uniqueSteeringItem(_ queue: AuthoritativeQueue, message: String) throws -> QueueItemSnapshot {
        let matches = queue.steering.filter { $0.message == message }
        guard matches.count == 1 else {
            throw QAVerificationFailure.postcondition(
                "Expected exactly one steering item \(message), found \(matches.count)"
            )
        }
        return matches[0]
    }

    private func authoritativeQueue(workspaceId: String, sessionId: String) throws -> AuthoritativeQueue {
        let requestId = UUID().uuidString
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/command",
            body: ["type": "get_queue", "requestId": requestId]
        )
        guard let messages = response["messages"] as? [[String: Any]] else {
            throw QAVerificationFailure.unknown("get_queue HTTP body is missing a messages array")
        }
        let matches = messages.filter { message in
            (message["type"] as? String) == "command_result"
                && (message["command"] as? String) == "get_queue"
                && (message["requestId"] as? String) == requestId
                && (message["success"] as? Bool) == true
        }
        guard matches.count == 1 else {
            throw QAVerificationFailure.unknown(
                "get_queue required exactly one successful command_result for \(requestId); found \(matches.count)"
            )
        }
        guard let data = matches[0]["data"] as? [String: Any] else {
            throw QAVerificationFailure.unknown("get_queue command_result is missing data object")
        }
        guard data["version"] != nil, let version = intValue(data["version"]), version >= 0 else {
            throw QAVerificationFailure.unknown("get_queue data.version is not a finite nonnegative integer")
        }
        return AuthoritativeQueue(
            requestId: requestId,
            version: version,
            steering: try queueItems(data["steering"], field: "steering"),
            followUp: try queueItems(data["followUp"], field: "followUp")
        )
    }

    @discardableResult
    private func sessionCommand(
        workspaceId: String,
        sessionId: String,
        body: [String: Any],
        command: String
    ) throws -> [String: Any] {
        var payload = body
        let requestId = UUID().uuidString
        payload["requestId"] = requestId
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/command",
            body: payload
        )
        guard let messages = response["messages"] as? [[String: Any]] else {
            throw QAVerificationFailure.unknown("\(command) HTTP body is missing a messages array")
        }
        let matches = messages.filter { message in
            (message["type"] as? String) == "command_result"
                && (message["command"] as? String) == command
                && (message["requestId"] as? String) == requestId
                && (message["success"] as? Bool) == true
        }
        guard matches.count == 1 else {
            throw QAVerificationFailure.unknown(
                "\(command) required exactly one successful command_result for \(requestId); found \(matches.count)"
            )
        }
        return matches[0]
    }

    private func queueItems(_ raw: Any?, field: String) throws -> [QueueItemSnapshot] {
        guard let rows = raw as? [[String: Any]] else {
            throw QAVerificationFailure.unknown("get_queue data.\(field) is not an array")
        }
        return try rows.enumerated().map { index, row in
            guard let id = row["id"] as? String, !id.isEmpty else {
                throw QAVerificationFailure.unknown("get_queue \(field)[\(index)].id is missing")
            }
            guard let message = row["message"] as? String else {
                throw QAVerificationFailure.unknown("get_queue \(field)[\(index)].message is missing")
            }
            guard row["createdAt"] != nil, let createdAt = intValue(row["createdAt"]) else {
                throw QAVerificationFailure.unknown("get_queue \(field)[\(index)].createdAt is missing")
            }
            let attachments: [Any]?
            if let value = row["attachments"] {
                guard let list = value as? [Any] else {
                    throw QAVerificationFailure.unknown("get_queue \(field)[\(index)].attachments is not an array")
                }
                attachments = list
            } else {
                attachments = nil
            }
            return QueueItemSnapshot(
                id: id,
                message: message,
                createdAt: createdAt,
                attachmentsPresent: attachments != nil,
                attachmentCount: attachments?.count
            )
        }
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private func writeReceipt(_ receipt: QAVerificationReceipt) {
        do {
            let file = receipt.makeFile()
            _ = try receipt.write()
            if file.status != .pass {
                XCTFail("\(receipt.journeyId) \(file.status.rawValue): \(file.failingStep?.reason ?? "failed")")
            }
        } catch {
            receipt.collectorHealth = "failed"
            XCTFail("Could not write QA receipt: \(error)")
        }
    }
}

private struct AuthoritativeQueue {
    var requestId: String
    var version: Int
    var steering: [QueueItemSnapshot]
    var followUp: [QueueItemSnapshot]
}

private struct QueueItemSnapshot: Equatable {
    var id: String
    var message: String
    var createdAt: Int
    var attachmentsPresent: Bool
    var attachmentCount: Int?
}
