import Foundation
import Testing
import UserNotifications
@testable import Oppi

@Suite("Pairing approval app events")
struct PairingApprovalAppEventTests {
    @Test func decodesRequestedEventFromBriefShape() throws {
        let event = try AppEventMessage.decode(from: """
        {
          "type": "pairing_approval_requested",
          "emittedAt": 1760000000000,
          "approval": {
            "id": "pa_1",
            "deviceName": "iPad",
            "method": "invite",
            "source": "100.64.0.7",
            "requestedAt": 1760000000000,
            "expiresAt": 1760000120000,
            "keyThumbprint": "thumbprint"
          }
        }
        """)
        guard case .pairingApprovalRequested(let emittedAt, let approval) = event else {
            Issue.record("Expected .pairingApprovalRequested, got \(event)")
            return
        }
        #expect(emittedAt == 1_760_000_000_000)
        #expect(approval.id == "pa_1")
        #expect(approval.deviceName == "iPad")
        #expect(approval.method == "invite")
        #expect(approval.source == "100.64.0.7")
        #expect(approval.requestedAt == 1_760_000_000_000)
        #expect(approval.expiresAt == 1_760_000_120_000)
        #expect(approval.keyThumbprint == "thumbprint")
    }

    @Test func decodesSettledEventFromBriefShape() throws {
        let event = try AppEventMessage.decode(from: """
        {
          "type": "pairing_approval_settled",
          "emittedAt": 1760000000500,
          "approvalId": "pa_1",
          "outcome": "approved"
        }
        """)
        guard case .pairingApprovalSettled(let emittedAt, let approvalId, let outcome) = event else {
            Issue.record("Expected .pairingApprovalSettled, got \(event)")
            return
        }
        #expect(emittedAt == 1_760_000_000_500)
        #expect(approvalId == "pa_1")
        #expect(outcome == .approved)
    }
}

@Suite("Pairing approval signing")
struct PairingApprovalSigningTests {
    @Test func signingInputMatchesWireContract() {
        #expect(
            PairingApprovalSigning.message(approvalId: "pa_1", keyThumbprint: "thumbprint")
                == "oppi:pair-approve:v1.pa_1.thumbprint"
        )
    }

    @Test func signatureIsRaw64ByteBase64URL() throws {
        let key = InMemoryP256DeviceKey()
        let signature = try PairingApprovalSigning.signatureBase64URL(
            key: key,
            approvalId: "pa_1",
            keyThumbprint: "thumbprint"
        )
        let raw = try #require(Data(base64URLEncoded: signature))
        #expect(raw.count == 64)
        #expect(!signature.contains("+"))
        #expect(!signature.contains("/"))
        #expect(!signature.contains("="))
    }
}

@Suite("Pairing enrollment waiting")
@MainActor
struct PairingEnrollmentTests {
    private let enrolled = PairDeviceResponse(
        deviceId: "dev_new",
        accessToken: "at_paired",
        expiresAt: 4_102_444_800_000,
        refreshChallenge: nil
    )

    @Test func pendingThenEnrolledCompletesWithoutSavingEarly() async throws {
        var polls = 0
        var waiting: [Int64] = []
        let response = try await PairingEnrollment.complete(
            start: .approvalRequired(
                PairingApprovalRequired(
                    status: "approval_required",
                    approvalId: "pa_1",
                    pendingToken: "pw_1",
                    expiresAt: 100
                )
            ),
            poll: { approvalId, pendingToken in
                #expect(approvalId == "pa_1")
                #expect(pendingToken == "pw_1")
                polls += 1
                if polls == 1 {
                    return .pending(expiresAt: 200)
                }
                return .enrolled(self.enrolled)
            },
            onWaiting: { waiting.append($0) },
            pollInterval: .zero,
            sleep: { _ in }
        )
        #expect(response.deviceId == "dev_new")
        #expect(response.accessToken == "at_paired")
        #expect(polls == 2)
        #expect(waiting == [100, 200])
    }

    @Test func deniedFailsClosed() async {
        await #expect(throws: PairingEnrollment.Failure.denied) {
            try await PairingEnrollment.complete(
                start: .approvalRequired(
                    PairingApprovalRequired(
                        status: "approval_required",
                        approvalId: "pa_1",
                        pendingToken: "pw_1",
                        expiresAt: 100
                    )
                ),
                poll: { _, _ in
                    throw APIError.server(status: 403, message: "pairing_denied")
                },
                pollInterval: .zero,
                sleep: { _ in }
            )
        }
    }

    @Test func expiredFailsClosed() async {
        await #expect(throws: PairingEnrollment.Failure.expired) {
            try await PairingEnrollment.complete(
                start: .approvalRequired(
                    PairingApprovalRequired(
                        status: "approval_required",
                        approvalId: "pa_1",
                        pendingToken: "pw_1",
                        expiresAt: 100
                    )
                ),
                poll: { _, _ in
                    throw APIError.server(status: 410, message: "pairing_expired")
                },
                pollInterval: .zero,
                sleep: { _ in }
            )
        }
    }

    @Test func unknownApprovalFailsClosed() async {
        await #expect(throws: PairingEnrollment.Failure.unknownApproval) {
            try await PairingEnrollment.complete(
                start: .approvalRequired(
                    PairingApprovalRequired(
                        status: "approval_required",
                        approvalId: "pa_1",
                        pendingToken: "pw_1",
                        expiresAt: 100
                    )
                ),
                poll: { _, _ in
                    throw APIError.server(status: 404, message: "unknown_approval")
                },
                pollInterval: .zero,
                sleep: { _ in }
            )
        }
    }

    @Test func networkFailureFailsClosed() async {
        await #expect(throws: PairingEnrollment.Failure.disconnected) {
            try await PairingEnrollment.complete(
                start: .approvalRequired(
                    PairingApprovalRequired(
                        status: "approval_required",
                        approvalId: "pa_1",
                        pendingToken: "pw_1",
                        expiresAt: 100
                    )
                ),
                poll: { _, _ in
                    throw URLError(.networkConnectionLost)
                },
                pollInterval: .zero,
                sleep: { _ in }
            )
        }
    }

    @Test func cancelFailsClosed() async {
        await #expect(throws: PairingEnrollment.Failure.cancelled) {
            try await PairingEnrollment.complete(
                start: .approvalRequired(
                    PairingApprovalRequired(
                        status: "approval_required",
                        approvalId: "pa_1",
                        pendingToken: "pw_1",
                        expiresAt: 100
                    )
                ),
                poll: { _, _ in
                    Issue.record("poll should not run after cancel")
                    return .pending(expiresAt: 100)
                },
                pollInterval: .milliseconds(10),
                sleep: { _ in throw CancellationError() }
            )
        }
    }
}

@Suite("Pairing approval API")
struct PairingApprovalAPIClientTests {
    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let environment = OppiClientEnvironment(
            baseURL: URL(string: "http://localhost:7749")!,
            bearerToken: "sk_test"
        )
        return APIClient(environment: environment, configuration: config)
    }

    private func cleanup() {
        TestURLProtocol.handler = nil
    }

    private func mockResponse(status: Int, json: String) throws -> (Data, HTTPURLResponse) {
        let data = try #require(json.data(using: .utf8))
        let response = try #require(HTTPURLResponse(
            url: URL(string: "http://localhost:7749")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }

    private func requestBodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    @Test func startPairDeviceDecodesApprovalRequired() async throws {
        let client = makeClient()
        defer { cleanup() }
        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/pair")
            return try self.mockResponse(status: 202, json: """
            {
              "status": "approval_required",
              "approvalId": "pa_1",
              "pendingToken": "pw_1",
              "expiresAt": 1760000120000
            }
            """)
        }
        let start = try await client.startPairDevice(
            pairingToken: "pt_1",
            deviceName: "iPhone",
            devicePublicKey: InMemoryP256DeviceKey().publicKey
        )
        guard case .approvalRequired(let required) = start else {
            Issue.record("Expected approval required")
            return
        }
        #expect(required.approvalId == "pa_1")
        #expect(required.pendingToken == "pw_1")
        #expect(required.expiresAt == 1_760_000_120_000)
    }

    @Test func pollDecodesPendingDeniedExpiredAndUnknown() async throws {
        let client = makeClient()
        defer { cleanup() }

        TestURLProtocol.handler = { _ in
            try self.mockResponse(status: 202, json: #"{"status":"pending","expiresAt":9}"#)
        }
        let pending = try await client.pollPairingApprovalStatus(approvalId: "pa_1", pendingToken: "pw_1")
        guard case .pending(let expiresAt) = pending else {
            Issue.record("Expected pending")
            return
        }
        #expect(expiresAt == 9)

        TestURLProtocol.handler = { _ in
            try self.mockResponse(status: 403, json: #"{"error":"pairing_denied"}"#)
        }
        await #expect(throws: APIError.self) {
            _ = try await client.pollPairingApprovalStatus(approvalId: "pa_1", pendingToken: "pw_1")
        }

        TestURLProtocol.handler = { _ in
            try self.mockResponse(status: 410, json: #"{"error":"pairing_expired"}"#)
        }
        do {
            _ = try await client.pollPairingApprovalStatus(approvalId: "pa_1", pendingToken: "pw_1")
            Issue.record("expired should throw")
        } catch let APIError.server(status, message) {
            #expect(status == 410)
            #expect(message == "pairing_expired")
        }

        TestURLProtocol.handler = { _ in
            try self.mockResponse(status: 404, json: #"{"error":"unknown_approval"}"#)
        }
        do {
            _ = try await client.pollPairingApprovalStatus(approvalId: "pa_1", pendingToken: "pw_1")
            Issue.record("unknown should throw")
        } catch let APIError.server(status, message) {
            #expect(status == 404)
            #expect(message == "unknown_approval")
        }
    }

    @Test func approvePostsBase64URLSignatureBody() async throws {
        let client = makeClient()
        defer { cleanup() }
        let signature = String(repeating: "A", count: 86)
        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/auth/pairing-approvals/pa_1/approve")
            let body = try JSONSerialization.jsonObject(with: self.requestBodyData(request)) as? [String: String]
            #expect(body == ["signature": signature])
            return try self.mockResponse(status: 200, json: #"{"ok":true}"#)
        }
        try await client.approvePairingApproval(id: "pa_1", signature: signature)
    }

    @Test func listPairingApprovalsDecodesRows() async throws {
        let client = makeClient()
        defer { cleanup() }
        TestURLProtocol.handler = { request in
            #expect(request.url?.path == "/auth/pairing-approvals")
            return try self.mockResponse(status: 200, json: """
            {
              "approvals": [
                {
                  "id": "pa_1",
                  "deviceName": "iPad",
                  "method": "invite",
                  "source": "100.64.0.7",
                  "requestedAt": 1,
                  "expiresAt": 2,
                  "keyThumbprint": "thumb"
                }
              ]
            }
            """)
        }
        let approvals = try await client.listPairingApprovals()
        #expect(approvals.map(\.id) == ["pa_1"])
        #expect(approvals[0].keyThumbprint == "thumb")
    }
}

@Suite("Pairing notification routing")
struct PairingNotificationRoutingTests {
    @Test func approveAndDenyActionsCarryServerAndApprovalIds() {
        let approve = AttentionNotificationService.pairingNotificationPayload(
            categoryIdentifier: SessionNotificationCategory.pairingApproval,
            actionIdentifier: AttentionNotificationService.pairingApproveActionId,
            userInfo: ["serverId": "sha256:s", "approvalId": "pa_1", "event": "pairing_approval"]
        )
        #expect(approve?.serverId == "sha256:s")
        #expect(approve?.approvalId == "pa_1")
        #expect(approve?.action == .approve)

        let deny = AttentionNotificationService.pairingNotificationPayload(
            categoryIdentifier: SessionNotificationCategory.pairingApproval,
            actionIdentifier: AttentionNotificationService.pairingDenyActionId,
            userInfo: ["serverId": "sha256:s", "approvalId": "pa_1"]
        )
        #expect(deny?.action == .deny)

        let open = AttentionNotificationService.pairingNotificationPayload(
            categoryIdentifier: SessionNotificationCategory.pairingApproval,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["serverId": "sha256:s", "approvalId": "pa_1"]
        )
        #expect(open?.action == .open)
    }
}

@Suite("Pairing approval controller")
@MainActor
struct PairingApprovalControllerTests {
    private func sample(_ id: String, requestedAt: Int64 = 1) -> PendingPairingApproval {
        PendingPairingApproval(
            id: id,
            deviceName: "iPad",
            method: "invite",
            source: "100.64.0.7",
            requestedAt: requestedAt,
            expiresAt: 9_999_999_999_999,
            keyThumbprint: "thumb"
        )
    }

    @Test func denyStaysQueuedUntilPostSucceedsAndIsRetried() async {
        let controller = PairingApprovalController()
        controller.queueDeny(serverId: "sha256:s", approvalId: "pa_1")
        #expect(controller.hasQueuedDeny(serverId: "sha256:s", approvalId: "pa_1"))

        var attempts = 0
        await controller.performQueuedDenies(postDeny: { _, _ in
            attempts += 1
            throw URLError(.networkConnectionLost)
        })
        #expect(attempts == 1)
        #expect(controller.hasQueuedDeny(serverId: "sha256:s", approvalId: "pa_1"))

        await controller.performQueuedDenies(postDeny: { serverId, approvalId in
            attempts += 1
            #expect(serverId == "sha256:s")
            #expect(approvalId == "pa_1")
        })
        #expect(attempts == 2)
        #expect(!controller.hasQueuedDeny(serverId: "sha256:s", approvalId: "pa_1"))
    }

    @Test func deny404ClearsTheQueue() async {
        let controller = PairingApprovalController()
        controller.queueDeny(serverId: "sha256:s", approvalId: "pa_1")
        await controller.performQueuedDenies(postDeny: { _, _ in
            throw APIError.server(status: 404, message: "unknown_approval")
        })
        #expect(!controller.hasQueuedDeny(serverId: "sha256:s", approvalId: "pa_1"))
    }

    @Test func stalePreferredNotificationPresentsNothing() {
        let controller = PairingApprovalController()
        controller.prefer(serverId: "sha256:s", approvalId: "pa_gone")
        controller.apply(pending: [(
            serverId: "sha256:s",
            serverName: "Mac",
            approval: sample("pa_other", requestedAt: 2)
        )])
        #expect(controller.presented == nil)
    }

    @Test func denyRemovesPromptAndBlocksApprove() {
        let controller = PairingApprovalController()
        controller.apply(pending: [(
            serverId: "sha256:s",
            serverName: "Mac",
            approval: sample("pa_1")
        )])
        #expect(controller.presented?.approval.id == "pa_1")

        controller.queueDeny(serverId: "sha256:s", approvalId: "pa_1")
        #expect(controller.presented == nil)
        #expect(controller.hasQueuedDeny(serverId: "sha256:s", approvalId: "pa_1"))

        controller.apply(pending: [(
            serverId: "sha256:s",
            serverName: "Mac",
            approval: sample("pa_1")
        )])
        #expect(controller.presented == nil)
    }
}
